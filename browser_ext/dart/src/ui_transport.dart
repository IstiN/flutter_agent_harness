/// UI-side transport abstraction (issue #30, "UI ↔ SW split", edges
/// E12/E30/E31). The Flutter UI is a pure face: rendering, composer,
/// settings. Everything that touches keys, providers, or the agent loop
/// lives behind one of two transports the chat code cannot tell apart:
///
/// - `WorkerRelayTransport` — extension mode. Everything flows over a
///   `chrome.runtime` Port ([UiPortChannel]); the UI process holds no keys
///   and makes no provider fetches. A dropped port (SW update/crash, E30)
///   triggers a backoff reconnect: reopen → hello → attach(remembered
///   session) → `Reconnected` → flush prompts composed while offline.
/// - `LocalStreamTransport` — plain web build. Prompts go straight to a
///   local stream function (the app's own agent path); events are re-emitted
///   as if they had arrived over a port, so downstream code is identical.
///
/// `detectTransport` makes the choice: a port factory that returns a channel
/// means the extension is present (the flutter_app JS shim probes
/// `chrome.runtime?.id` for the same decision); null, throwing, or a forced
/// override falls back to the local path.
///
/// Pure Dart, zero IO (compiled by dart2js into the panel page context).
/// Failures are quiet by contract — nothing here throws into the UI loop;
/// the wire's `error` message is the only failure surface.
library;

import 'dart:async';

import 'ui_protocol.dart';

/// The injectable `chrome.runtime.Port` boundary. UI-side and SW-side fakes
/// implement this in tests; the production binding lives in the dart2js
/// entry (agent_main), not here.
abstract class UiPortChannel {
  /// Sends one protocol envelope (a [UiProtocolMessage.encode] map).
  void send(Map<String, dynamic> json);

  /// Decoded inbound envelopes. The stream completing (done) is the port
  /// drop signal — a dead MV3 worker fires the port's onDisconnect, which
  /// the binding maps onto stream completion.
  Stream<Map<String, dynamic>> get onMessage;

  /// Closes the port locally. Idempotent.
  void close();

  /// True after [close] or a peer-side drop.
  bool get isClosed;
}

/// Connection phases surfaced as [StateChanged] events.
///
/// The phase names mirror what the UI renders: composer disabled while
/// connecting/reconnecting, "reconnecting…" badge with the next attempt
/// delay, streaming indicator while a turn is live.
sealed class FaTransportState {
  const FaTransportState();
}

/// No usable link (initial state, or hello refused for a version mismatch).
final class TransportDisconnected extends FaTransportState {
  const TransportDisconnected();
}

/// Channel open, hello/attach cycle in flight.
final class TransportConnecting extends FaTransportState {
  const TransportConnecting();
}

final class TransportReconnecting extends FaTransportState {
  const TransportReconnecting({required this.nextAttemptIn});

  final Duration nextAttemptIn;

  // Value equality: UIs and tests compare rendered states, and two
  // "retrying in 15s" phases mean the same thing on screen.
  @override
  bool operator ==(Object other) =>
      other is TransportReconnecting && other.nextAttemptIn == nextAttemptIn;

  @override
  int get hashCode => nextAttemptIn.hashCode;
}

/// Session adopted; prompts reach the worker immediately.
final class TransportAttached extends FaTransportState {
  const TransportAttached();
}

/// A turn is producing output (dispatched prompt or inbound stream events).
final class TransportStreaming extends FaTransportState {
  const TransportStreaming();
}

/// Everything a transport tells the UI about.
sealed class UiTransportEvent {
  const UiTransportEvent();
}

/// A decoded protocol message from the peer, verbatim — the partial message
/// on screen must be exactly what the loop produced, so nothing is rebuilt.
final class ProtocolMessageReceived extends UiTransportEvent {
  const ProtocolMessageReceived(this.message);

  final UiProtocolMessage message;
}

/// The state machine moved; payload equals the new [FaTransport.state].
final class StateChanged extends UiTransportEvent {
  const StateChanged(this.state);

  final FaTransportState state;
}

/// The link was lost (port drop / reopen failure). Prompts composed from
/// here on queue until the next attach.
final class Dropped extends UiTransportEvent {
  const Dropped();
}

/// A reconnect cycle fully succeeded (hello + attach on a reopened channel).
final class Reconnected extends UiTransportEvent {
  const Reconnected(this.sessionId);

  final String sessionId;
}

/// The direct local agent path for the plain web build: one agent-event-map
/// stream per prompt (the same partial-first shapes the SW relays inside
/// `stream` envelopes).
typedef LocalStreamFactory =
    Stream<Map<String, dynamic>> Function(String promptId, String text);

/// Shared contract for both transports: event plumbing, state emission,
/// prompt dedup (double-send is impossible — same id twice is dropped
/// silently), and the offline queue that flushes on attach (E30).
abstract class FaTransport {
  FaTransport({bool Function(String promptId)? promptDedup})
    : _dedup = promptDedup;

  final StreamController<UiTransportEvent> _events =
      StreamController<UiTransportEvent>.broadcast();

  /// Default dedup: an internal set. The UI context lives and dies with the
  /// page, so ids never repeat within a page's lifetime and the set cannot
  /// grow unbounded in practice.
  final _sentPrompts = <String>{};
  final bool Function(String)? _dedup;

  /// Prompts composed while not attached (E30): kept in memory, flushed in
  /// order on the next attach.
  final _pending = <({String id, String text})>[];

  FaTransportState _state = const TransportDisconnected();
  String? _sessionId;

  /// Latest [StateChanged] payload.
  FaTransportState get state => _state;

  /// The session this transport remembers. Persisting is the caller's job
  /// (`setSessionId` only remembers); [AttachedMsg] adopts the worker's
  /// authoritative id the same way.
  String? get sessionId => _sessionId;

  Stream<UiTransportEvent> get events => _events.stream;

  /// Opens the transport. For the worker relay this resolves once the first
  /// hello/attach cycle lands; a dropped channel afterwards keeps the link
  /// alive through the reconnect loop (state `reconnecting`) without ever
  /// failing this future — the UI shows "reconnecting", never a dead
  /// composer. Only an unrecoverable hello (version mismatch) fails it.
  Future<void> connect();

  /// Starts a turn. While the transport is not attached the text queues and
  /// flushes after reconnect, in order, exactly once per attach cycle (the
  /// worker's own prompt dedup makes a resend after a mid-flush drop safe).
  void sendPrompt(String id, String text) {
    if (!(_dedup ?? _sentPrompts.add)(id)) return; // double-tap: dropped
    if (isReady) {
      _setState(const TransportStreaming()); // optimistic: turn considered live
      dispatchPrompt(id, text);
    } else {
      _pending.add((id: id, text: text));
    }
  }

  /// Mid-turn steering. Meaningless without a live link — steering a turn
  /// that a drop already killed would be worse than losing the text, so it
  /// is silently ignored while not attached.
  void steer(String text) {
    if (isReady) dispatch(SteerMsg(text: text));
  }

  /// Cancels the running turn; ignored while not attached (same reasoning
  /// as [steer]).
  void cancel() {
    if (isReady) dispatch(const CancelMsg());
  }

  /// Remembers [id] as the session to attach to. Persisted by the caller.
  void setSessionId(String? id) {
    _sessionId = id;
  }

  /// True while prompts/steers can reach the peer right now (attached or
  /// streaming).
  bool get isReady;

  /// Delivers a deduped, ready prompt over this transport's link.
  void dispatchPrompt(String id, String text);

  /// Delivers a control message (steer/cancel) over this transport's link.
  void dispatch(UiProtocolMessage message);

  // -- shared plumbing ------------------------------------------------------

  void _setState(FaTransportState next) {
    if (identical(next, _state)) return;
    _state = next;
    _events.add(StateChanged(next));
  }

  /// Inbound protocol message: surfaces verbatim first, then runs the
  /// generic state flips both transports share.
  void _receive(UiProtocolMessage message) {
    _events.add(ProtocolMessageReceived(message));
    switch (message) {
      case StreamMsg():
        if (_state is TransportAttached) {
          _setState(const TransportStreaming());
        }
      // A turn ends with its final message or an error; anything else that
      // arrives mid-stream is not a turn boundary.
      case MessageDoneMsg() || ErrorMsg():
        if (_state is TransportStreaming) {
          _setState(const TransportAttached());
        }
      default:
        break; // hello_ack/attached/approvals/sessions — concrete-transport business
    }
  }

  /// Maps one raw agent event map (delta/tool_result/message_done/error …)
  /// onto its protocol envelope, so locally produced events are
  /// indistinguishable from relayed ones downstream. `message_done` and
  /// `error` are turn boundaries and get their own kinds; everything else
  /// rides in a `stream` envelope, map passed through by reference.
  UiProtocolMessage _envelopeOf(Map<String, dynamic> agentEvent) {
    switch (agentEvent['type']) {
      case 'message_done':
        return UiProtocolMessage.decode({
          'kind': 'message_done',
          'message': agentEvent,
        });
      case 'error':
        return UiProtocolMessage.decode({
          'kind': 'error',
          'code': agentEvent['code'] ?? 'error',
          'message': agentEvent['error'] ?? '',
        });
      default:
        return UiProtocolMessage.decode({
          'kind': 'stream',
          'event': agentEvent,
        });
    }
  }
}

/// Extension-mode transport: everything via the [UiPortChannel]; the UI
/// process holds no keys and makes no provider fetches.
///
/// Reconnect state machine (E30): a dropped channel (port drop, SW update)
/// moves to `reconnecting` and reopens the factory on the backoff schedule
/// [100ms, 500ms, 2s, 5s, 15s], then every 15s forever — a restarting SW is
/// expected to come back within one backoff step, and panel reopen storms
/// must not hammer the worker. Once reopen + hello + attach succeed:
/// `Reconnected`, then the offline queue flushes in order. Composed-but-
/// unsent text survives the drop in memory.
final class WorkerRelayTransport extends FaTransport {
  WorkerRelayTransport({
    required this.portFactory,
    UiPortChannel? channel,
    Future<void> Function(Duration delay)? delay,
    super.promptDedup,
  }) : _delay = delay ?? ((d) => Future<void>.delayed(d)),
       _probed = channel;

  static const _backoffSchedule = [
    Duration(milliseconds: 100),
    Duration(milliseconds: 500),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  final UiPortChannel Function() portFactory;
  final Future<void> Function(Duration) _delay;

  /// The channel detectTransport already probed with — consumed once by the
  /// first [_open], so detection does not burn a throwaway port.
  UiPortChannel? _probed;
  UiPortChannel? _channel;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// One connect cycle at a time: stale channel events and double connects
  /// are ignored (same pattern as the DAP client's generation counter).
  var _generation = 0;
  var _attempt = 0;
  var _stopped = false;
  var _everDropped = false;
  var _lostGeneration = -1;
  Completer<void>? _handshake;

  @override
  bool get isReady =>
      _state is TransportAttached || _state is TransportStreaming;

  @override
  Future<void> connect() {
    final pending = _handshake;
    if (pending != null) return pending.future; // one cycle at a time
    _stopped = false;
    _attempt = 0;
    _everDropped = false;
    final done = _handshake = Completer<void>();
    _setState(const TransportConnecting());
    _open();
    return done.future;
  }

  @override
  void dispatchPrompt(String id, String text) {
    _trySend(PromptMsg(id: id, text: text));
  }

  @override
  void dispatch(UiProtocolMessage message) {
    _trySend(message);
  }

  // -- connection cycle -----------------------------------------------------

  void _open() {
    final gen = ++_generation;
    final probed = _probed;
    _probed = null;
    UiPortChannel channel;
    try {
      channel = probed ?? portFactory();
    } on Object {
      _lost(gen); // a factory that throws is a channel we never got
      return;
    }
    _channel = channel;
    _subscription = channel.onMessage.listen(
      (json) {
        if (gen == _generation) _onJson(json);
      },
      onDone: () {
        if (gen == _generation) _lost(gen); // port drop == stream done
      },
    );
    _trySend(const HelloMsg(protoVersion: uiProtocolVersion, capabilities: []));
  }

  void _onJson(Map<String, dynamic> json) {
    final message = UiProtocolMessage.decode(json);
    _receive(message);
    switch (message) {
      case HelloAckMsg(:final protoVersion):
        try {
          negotiateVersion(uiProtocolVersion, protoVersion);
        } on UiProtocolVersionError catch (error) {
          // No common version — retrying can never help (the DAP client's
          // rejected-hello rule): surface the failure and stop the loop.
          _stopped = true;
          _handshake?.completeError(error);
          _handshake = null;
          _teardown();
          _setState(const TransportDisconnected());
          return;
        }
        _trySend(AttachMsg(sessionId: _sessionId, lastEventId: null));
      case AttachedMsg(:final sessionId, :final replay):
        _sessionId = sessionId; // the worker's id is authoritative now
        _setState(const TransportAttached());
        final reconnecting = _handshake;
        _handshake = null;
        reconnecting?.complete();
        if (_everDropped) {
          _everDropped = false;
          _events.add(Reconnected(sessionId));
        }
        // Replayed partials surface exactly like live stream events, so a
        // turn that kept running while the SW restarted draws itself back.
        for (final event in replay) {
          _receive(_envelopeOf(event));
        }
        _flushPending();
      default:
        break;
    }
  }

  void _lost(int gen) {
    if (_stopped || gen != _generation || _lostGeneration == gen) return;
    _lostGeneration = gen;
    _teardown();
    _events.add(const Dropped());
    _everDropped = true;
    _attempt++;
    final wait = _backoffFor(_attempt);
    _setState(TransportReconnecting(nextAttemptIn: wait));
    // The handshake stays pending across retries: connect() resolves when
    // the session is actually adopted again, however many drops that takes.
    unawaited(
      _delay(wait).then((_) {
        if (!_stopped && gen == _generation) _open();
      }),
    );
  }

  void _teardown() {
    final channel = _channel;
    _channel = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    channel?.close(); // fatal paths close politely; dead ports ignore it
  }

  /// Backoff for attempt N (1-based): the schedule, then 15s forever.
  static Duration _backoffFor(int attempt) =>
      _backoffSchedule[(attempt.clamp(1, _backoffSchedule.length)) - 1];

  bool _trySend(UiProtocolMessage message) {
    final channel = _channel;
    if (channel == null || channel.isClosed) return false;
    try {
      channel.send(message.encode());
      return true;
    } on Object {
      _lost(_generation); // send on a dying port == port drop
      return false;
    }
  }

  void _flushPending() {
    while (_pending.isNotEmpty) {
      final (:id, :text) = _pending.first;
      // A failed send leaves the prompt queued: the next attach re-flushes
      // it, and the worker's prompt dedup makes that resend run-once.
      if (!_trySend(PromptMsg(id: id, text: text))) return;
      _pending.removeAt(0);
    }
  }
}

/// Plain-web-mode transport (AC7/E31): prompts go straight to the app's
/// local agent path and its agent-event maps are re-emitted as if they had
/// arrived over a port — downstream code cannot tell the difference. No
/// channel exists, so there is nothing to drop and nothing to reconnect.
final class LocalStreamTransport extends FaTransport {
  LocalStreamTransport({required this.onPrompt, super.promptDedup});

  final LocalStreamFactory onPrompt;
  var _connected = false;

  @override
  bool get isReady => _connected;

  @override
  Future<void> connect() async {
    if (_connected) return;
    _setState(const TransportConnecting());
    _connected = true;
    _setState(const TransportAttached());
  }

  @override
  void dispatchPrompt(String id, String text) {
    Stream<Map<String, dynamic>> events;
    try {
      events = onPrompt(id, text);
    } on Object catch (error) {
      _receive(_localError(error)); // the agent path failed synchronously
      return;
    }
    // Fire-and-forget by design: the transport lives as long as the page,
    // and each prompt's stream ends with the turn.
    events.listen(
      (event) => _receive(_envelopeOf(event)),
      onError: (Object error) => _receive(_localError(error)),
      onDone: () {
        // A turn aborted without message_done still ends the streaming
        // phase, or the composer would stay locked forever.
        if (_state is TransportStreaming) {
          _setState(const TransportAttached());
        }
      },
    );
  }

  /// Plain-web steering is owned by the app's local session object (the
  /// factory signature carries no steer channel), so control messages have
  /// nowhere to land here — the local path behaves exactly as the app does
  /// today without a transport (E31).
  @override
  void dispatch(UiProtocolMessage message) {}

  UiProtocolMessage _localError(Object error) =>
      ErrorMsg(code: 'local', message: '$error');
}

/// Picks the transport for the current context (AC7; edges E12/E31).
///
/// The flutter_app's JS shim decides by probing `chrome.runtime?.id`; on the
/// Dart side the same decision is [portFactory]: non-null AND returning a
/// channel means "extension present". A null factory (chrome.* absent, E12),
/// a factory that throws, or one returning null falls back to the local
/// path — the app stays fully functional either way. [forceOverride] pins
/// the choice for tests (E31): `true` forces the worker relay, `false`
/// forces local, null probes.
FaTransport detectTransport({
  UiPortChannel? Function()? portFactory,
  bool? forceOverride,
  LocalStreamFactory? local,
}) {
  if (forceOverride == null) {
    final factory = portFactory;
    UiPortChannel? probed;
    if (factory != null) {
      try {
        probed = factory();
      } on Object {
        probed = null; // malformed extension environment → plain web
      }
    }
    if (probed == null) return _localOrThrow(local);
    // The probed channel goes into the transport so detection does not
    // burn a throwaway port; reconnects re-probe through the original
    // factory (never this dead channel again).
    return WorkerRelayTransport(
      portFactory: _probeSafe(factory!),
      channel: probed,
    );
  }
  if (forceOverride) {
    final factory = portFactory;
    if (factory == null) {
      throw ArgumentError.value(
        null,
        'portFactory',
        'required to force the worker relay',
      );
    }
    return WorkerRelayTransport(portFactory: _probeSafe(factory));
  }
  return _localOrThrow(local);
}

/// Adapts the nullable-returning probe factory to the transport's
/// non-null contract: a null return (extension vanished mid-life) becomes
/// a throw, which the reconnect loop already treats as a lost channel.
UiPortChannel Function() _probeSafe(UiPortChannel? Function() factory) => () {
  final channel = factory();
  if (channel == null) {
    throw StateError('port factory returned null');
  }
  return channel;
};

FaTransport _localOrThrow(LocalStreamFactory? local) {
  if (local == null) {
    throw ArgumentError(
      'no port factory and no local stream function: nothing to run on',
    );
  }
  return LocalStreamTransport(onPrompt: local);
}
