/// `fa wire-serve` server core (issue #1103): drives one agent session over
/// the Agent Wire Protocol v1 (#1101) — PURE Dart, zero transport code.
///
/// A transport (NDJSON-stdio or loopback WebSocket, both in `bin/`) hands
/// [WireServeServer.attach] a decoded-frame stream and a frame sink per
/// client. The server owns everything the transport must not know:
///
/// - **Handshake**: the first frame of an attach must be `hello`;
///   `AgentWireProtocol.acceptHello` answers `welcome` at the negotiated
///   version. Anything else is a loud `handshake_failed` error frame and
///   the attach ends. Frames are encoded at the negotiated version from
///   then on.
/// - **Single attach** (UT-1): one client at a time. A second attach is
///   rejected with a loud `already_attached` error frame before its
///   handshake is read; after the client detaches (stream done), the next
///   attach is clean.
/// - **Dispatch**: `prompt`/`steer`/`abort` drive the run closures;
///   misuse is loud (`busy`, `not_running`), never silent. Unknown
///   commands and unknown `session_control` ops are rejected loudly and
///   the connection stays alive (the E3 discipline). Malformed frames
///   answer `bad_frame` per frame.
/// - **Host-interaction requests** (approval/ask/secret): the engine's
///   callbacks re-enter here and go out as request frames; the matching
///   `_response` command resolves the waiter by echoing the request id.
///   **E1**: a pending request survives a detach — the next attach is
///   re-delivered every still-pending request frame (same ids, so answers
///   are idempotent), and a late/duplicate answer for an unknown id is a
///   loud `unknown_request_id`.
/// - **Shutdown** ([shutdown]): every pending request resolves to its
///   safe refusal (approval → deny, ask → cancelled, secret → declined)
///   so tool calls never wedge the teardown; the client detaches.
///
/// Frames carry no secrets here: the wire-serve token never enters this
/// library (it lives in the transport's handshake, `bin/`), and response
/// payloads are passed through to the engine without being logged. If
/// [onLog] is set it receives one-line diagnostics only.
library;

// Named ctor params map onto private fields (public API, private storage) —
// the same escape `bin/serve_bridge.dart` uses.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../agent/agent_loop.dart' show AgentEvent;
import '../approval/approval.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';
import 'wire_protocol.dart';

/// One attached client's frame sink.
typedef WireFrameSink = void Function(Map<String, dynamic> frame);

/// A pending host-interaction request waiting for its `_response` command.
final class _PendingRequest {
  _PendingRequest({required this.kind, required this.encode});

  /// `approval_request` | `ask_request` | `secret_request`.
  final String kind;

  /// Re-encodes the request frame — per attach, at the attach's negotiated
  /// protocol version (E1 re-delivery is byte-correct for every version).
  final Map<String, dynamic> Function(AgentWireProtocol protocol) encode;

  final completer = Completer<Object?>();
}

/// The protocol server for one agent session. Constructed by the host boot
/// (`AgentCli.runWireServe`), fed engine events via [handleAgentEvent], and
/// driven by transports through [attach].
final class WireServeServer {
  /// Creates a server. The closures are the engine seams: [runPrompt]
  /// runs one user turn (redaction, settle, persistence are the CLI's
  /// business), [steer]/[abort]/[isBusy] mirror the live agent.
  WireServeServer({
    required Future<void> Function(String text) runPrompt,
    required void Function(String text) steer,
    required void Function() abort,
    required bool Function() isBusy,
    AgentWireProtocol? protocol,
    void Function(String line)? onLog,
  }) : _runPrompt = runPrompt,
       _steer = steer,
       _abort = abort,
       _isBusy = isBusy,
       _protocol = protocol ?? AgentWireProtocol(),
       _onLog = onLog;

  AgentWireProtocol _protocol;
  final Future<void> Function(String text) _runPrompt;
  final void Function(String text) _steer;
  final void Function() _abort;
  final bool Function() _isBusy;
  final void Function(String line)? _onLog;

  WireFrameSink? _client;
  bool _attaching = false;
  bool _shutDown = false;
  var _requestCounter = 0;
  final _pending = <String, _PendingRequest>{};

  /// Serialize run turns: a prompt accepted while the previous turn is
  /// settling (stream ended, post-run compaction still in flight) queues
  /// behind it instead of racing the settle path.
  Future<void> _promptChain = Future<void>.value();

  StreamSubscription<Map<String, dynamic>>? _frames;
  Completer<void>? _attachDone;

  /// Whether a client is attached (handshake complete).
  bool get attached => _client != null;

  /// Every pending request id, oldest first (diagnostics/tests).
  List<String> get pendingRequestIds => List.unmodifiable(_pending.keys);

  // ---------------------------------------------------------------------------
  // Attach lifecycle
  // ---------------------------------------------------------------------------

  /// Serves one client until it detaches (its frame stream ends or errors)
  /// or the server shuts down. A second simultaneous attach is rejected
  /// with `already_attached` before its handshake is read.
  Future<void> attach(Stream<Map<String, dynamic>> frames, WireFrameSink send) {
    if (_shutDown) {
      send(_error('shutting_down', 'wire-serve is shutting down'));
      return Future<void>.value();
    }
    if (_client != null || _attaching) {
      send(
        _error(
          'already_attached',
          'another client is attached to this session; '
              'retry after it disconnects',
        ),
      );
      return Future<void>.value();
    }
    _attaching = true;
    final done = Completer<void>();
    _attachDone = done;
    _frames = frames.listen(
      (frame) => _onClientFrame(frame, send),
      onDone: () => _detach(),
      onError: (Object error) => _detach(error),
      cancelOnError: true,
    );
    return done.future;
  }

  void _onClientFrame(Map<String, dynamic> frame, WireFrameSink send) {
    if (_client == null) {
      // Handshake phase: the first frame must be a hello.
      try {
        final (:protocol, :welcome) = AgentWireProtocol.acceptHello(frame);
        _protocol = protocol;
        _sendSafely(welcome, send);
        _client = send;
        _attaching = false;
        _log('client attached v=${protocol.version}');
        // E1: re-deliver every still-pending request to the fresh attach.
        for (final pending in _pending.values) {
          _sendSafely(pending.encode(_protocol), send);
        }
      } on WireProtocolException catch (error) {
        _sendSafely(_error('handshake_failed', '$error'), send);
        _detach();
      }
      return;
    }
    try {
      _dispatch(_protocol.decodeCommand(frame));
    } on WireProtocolException catch (error) {
      _send(_error('bad_frame', '$error'));
    }
  }

  void _detach([Object? error]) {
    _client = null;
    _attaching = false;
    unawaited(_frames?.cancel());
    _frames = null;
    final done = _attachDone;
    _attachDone = null;
    if (done != null && !done.isCompleted) done.complete();
    // A clean hangup and a transport fault must stay distinguishable in
    // the diagnostics (review #1113 r4): with decode failures answered
    // as bad_frame in the transport, whatever reaches the error handler
    // is a genuine stream fault.
    _log(
      error == null
          ? 'client detached (pending=${_pending.length})'
          : 'client detached: $error (pending=${_pending.length})',
    );
  }

  // ---------------------------------------------------------------------------
  // Engine-facing callbacks (wired by the host boot)
  // ---------------------------------------------------------------------------

  /// The approval-gate surface: emits an `approval_request` frame and
  /// resolves when the client's `approval_response` echoes the id.
  Future<ApprovalDecision> approvalPrompt(ApprovalRequest request) async {
    final id = _nextId('ap');
    final decision = await _awaitResponse(
      id,
      'approval_request',
      (protocol) => protocol.encodeApprovalRequest(id: id, request: request),
    );
    return decision as ApprovalDecision? ?? ApprovalDecision.deny;
  }

  /// The `ask` tool's surface: emits `ask_request`, resolves with the
  /// client's answers; `null` = the client cancelled.
  Future<List<AskAnswer>?> answerAsk(List<AskQuestion> questions) async {
    final id = _nextId('ask');
    final answers = await _awaitResponse(
      id,
      'ask_request',
      (protocol) => protocol.encodeAskRequest(id: id, questions: questions),
    );
    return answers as List<AskAnswer>?;
  }

  /// The `request_secret` tool's surface: emits `secret_request`, resolves
  /// with the granted result; `null` = the client declined.
  Future<RequestSecretResult?> answerSecret(String name, String reason) async {
    final id = _nextId('sec');
    final result = await _awaitResponse(
      id,
      'secret_request',
      (protocol) =>
          protocol.encodeSecretRequest(id: id, name: name, reason: reason),
    );
    return result as RequestSecretResult?;
  }

  Future<Object?> _awaitResponse(
    String id,
    String kind,
    Map<String, dynamic> Function(AgentWireProtocol protocol) encode,
  ) {
    // A request arriving after shutdown() can never be answered - no
    // client is coming back. Resolve to the safe refusal (deny /
    // cancelled / declined, per the callers' null mapping) immediately
    // instead of registering a pending that only the settle-window
    // timeout would reap (review #1113 r3).
    if (_shutDown) return Future<Object?>.value(null);
    final pending = _PendingRequest(kind: kind, encode: encode);
    _pending[id] = pending;
    // First delivery: to the attached client, if any. Detached callers
    // (should not happen — requests only start inside a run a client
    // prompted) still resolve on shutdown.
    final client = _client;
    if (client != null) _sendSafely(pending.encode(_protocol), client);
    return pending.completer.future.then((value) {
      _pending.remove(id);
      return value;
    });
  }

  // ---------------------------------------------------------------------------
  // Engine event forwarding
  // ---------------------------------------------------------------------------

  /// Forwards one engine event to the attached client as a wire frame.
  /// Without a client events are dropped — the session file is the replay
  /// surface, not the wire.
  void handleAgentEvent(AgentEvent event) {
    final client = _client;
    if (client == null) return;
    _sendSafely(_protocol.encodeEvent(event), client);
  }

  // ---------------------------------------------------------------------------
  // Command dispatch
  // ---------------------------------------------------------------------------

  void _dispatch(WireCommand command) {
    switch (command) {
      case WirePromptCommand(:final text):
        if (_isBusy()) {
          _send(_error('busy', 'a run is already active; steer or abort it'));
          return;
        }
        // ponytail: one-deep queue via a chained future — a real run queue
        // is a follow-up if clients ever need it.
        _promptChain = _promptChain
            .then((_) => _runPrompt(text))
            .then(
              (_) {},
              onError: (Object error) {
                _send(_error('run_failed', '$error'));
              },
            );
        unawaited(_promptChain);
      case WireSteerCommand(:final text):
        if (!_isBusy()) {
          _send(_error('not_running', 'steer requires an active run'));
          return;
        }
        _steer(text);
      case WireAbortCommand():
        if (!_isBusy()) {
          _send(_error('not_running', 'no active run to abort'));
          return;
        }
        _abort();
      case WireApprovalResponseCommand(:final id, :final decision):
        _resolve(id, 'approval_request', decision);
      case WireAskResponseCommand(:final id, :final answers):
        _resolve(id, 'ask_request', answers);
      case WireSecretResponseCommand(:final id, :final result):
        _resolve(id, 'secret_request', result);
      case WireSessionControlCommand(:final op):
        // ponytail: v1 ships no session_control ops; the frame shape is
        // pinned for forward compat and the op registry grows additively.
        _send(
          _error(
            'unsupported_session_control_op',
            'no session_control ops are supported in protocol v1 '
                '(got "$op")',
          ),
        );
      case WireUnknownCommand(:final kind):
        _send(_error('unknown_command', 'no such command kind: "$kind"'));
    }
  }

  void _resolve(String id, String kind, Object? value) {
    final pending = _pending[id];
    if (pending == null || pending.kind != kind) {
      _send(
        _error(
          'unknown_request_id',
          'no pending $kind with id "$id" '
              '(already answered, or never issued)',
        ),
      );
      return;
    }
    _pending.remove(id);
    pending.completer.complete(value);
  }

  // ---------------------------------------------------------------------------
  // Shutdown
  // ---------------------------------------------------------------------------

  /// Resolves every pending request to its safe refusal, detaches the
  /// client, and refuses further attaches. Idempotent.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    for (final entry in _pending.entries) {
      // Safe refusals: approval → deny, ask → cancelled, secret → declined.
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.complete(null);
      }
    }
    _pending.clear();
    _detach();
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  String _nextId(String prefix) => '${prefix}_${++_requestCounter}';

  void _send(Map<String, dynamic> frame) {
    final client = _client;
    if (client == null) return;
    _sendSafely(frame, client);
  }

  void _sendSafely(Map<String, dynamic> frame, WireFrameSink send) {
    try {
      send(frame);
    } on Object catch (error) {
      // A dead sink (closed socket) must not kill the engine listener.
      _log('frame send failed: $error');
      _detach();
    }
  }

  Map<String, dynamic> _error(String code, String message) => {
    'v': _protocol.version,
    'kind': 'error',
    'code': code,
    'message': message,
  };

  /// A transport-level decode failure (a malformed NDJSON line): the
  /// documented rule is a loud `bad_frame` error frame — the SAME code
  /// the core answers schema-invalid frames with — and the connection
  /// STAYS ALIVE; one bad line never kills the stream (review #1113 r2,
  /// BLOCKING #1). Valid pre-handshake too: the version is fixed at
  /// construction.
  void protocolError(String code, String message, WireFrameSink send) {
    _sendSafely({
      'v': _protocol.version,
      'kind': 'error',
      'code': code,
      'message': message,
    }, send);
  }

  void _log(String line) => _onLog?.call('wire-serve: $line');
}
