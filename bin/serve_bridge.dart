/// `fa serve --bridge` — the loopback WebSocket browser bridge (issue #23,
/// phases 1+2): extension pairing with one-time tokens, mail relay in both
/// directions over the file messaging fabric, ping/pong keepalive, and the
/// `browserReq`/`browserRes` correlation seam phase 3 plugs its browser
/// tools into.
///
/// IO lives here (bin/) per the repo rule: `lib/` stays pure Dart and only
/// carries the frame protocol; the loopback bind is a hard invariant — a
/// non-loopback address fails fast (AC15).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Pairing-token persistence: `<projectRoot>/.fah/bridge/token`, mode 0600
/// (best-effort chmod — dart:io exposes no portable mode API; Windows and
/// failed chmods keep default ACLs, mirroring the hub identity key).
final class BridgeTokenFile {
  BridgeTokenFile(this.projectRoot);

  /// The project root `.fah/` lives under.
  final String projectRoot;

  /// Absolute token file path.
  String get path => '$projectRoot/.fah/bridge/token';

  /// The stored token; mints (and persists, mode 0600) when absent.
  Future<String> ensure() async {
    final file = File(path);
    if (await file.exists()) {
      final stored = (await file.readAsString()).trim();
      if (stored.isNotEmpty) return stored;
    }
    return rotate();
  }

  /// Overwrites with a fresh token — every earlier token stops working (E17).
  Future<String> rotate() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final token = pairingToken();
    await file.writeAsString('$token\n');
    await _chmod600(file.path);
    return token;
  }
}

Future<void> _chmod600(String path) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', ['0600', path]);
  } on Object {
    // Best-effort; see the class doc.
  }
}

/// The loopback bridge server. One [BridgeConnection] per paired extension;
/// mail flows through the [MessagingRepository] fabric shared with the CLI.
final class BridgeServer {
  /// Creates a server. [address] MUST be loopback — anything else throws
  /// [ArgumentError] right here, never a late listen failure (AC15).
  BridgeServer({
    required MessagingRepository messaging,
    required String root,
    required String token,
    this.version = '0',
    int port = bridgeDefaultPort,
    InternetAddress? address,
    this.onClient,
    this.onClientsChanged,
    this.dispatch,
    this.pollInterval = bridgePollInterval,
    this.heartbeatInterval = bridgeHeartbeatInterval,
    this.dispatchTimeout = bridgeDispatchTimeout,
  }) : _messaging = messaging,
       _root = root,
       _token = token,
       _port = port,
       _address = address ?? InternetAddress.loopbackIPv4 {
    if (!_address.isLoopback) {
      throw ArgumentError.value(
        _address.address,
        'address',
        'the browser bridge binds 127.0.0.1 only (AC15)',
      );
    }
  }

  final MessagingRepository _messaging;

  /// Project root (the `.fah/bridge/token` anchor).
  final String _root;

  String _token;

  final int _port;
  final InternetAddress _address;

  /// Server label sent in `welcome` (`fa/<version>`).
  final String version;

  /// Called with every connection right after the WebSocket upgrade.
  final void Function(BridgeConnection)? onClient;

  /// Fires whenever [clients] changes — a connection joins or leaves.
  /// The availability seam (phase 3) listens for the paired-client
  /// truth value flipping so it can show/hide the browser tool family.
  void Function()? onClientsChanged;

  /// The browser-op handler phase 3 injects; invoked per `browserReq` on
  /// each connection. Null: requests resolve with `no_target` errors.
  final Future<Map<String, dynamic>> Function(
    String op,
    Map<String, dynamic> args,
  )?
  dispatch;

  /// Fabric poll cadence for connected extensions.
  final Duration pollInterval;

  /// Mailbox heartbeat cadence (`messaging.touch`).
  final Duration heartbeatInterval;

  /// How long [BridgeConnection.dispatch] waits for `browserRes`.
  final Duration dispatchTimeout;

  HttpServer? _http;
  final Set<BridgeConnection> _clients = {};
  final Completer<void> _closed = Completer();

  /// The pairing token every hello must carry.
  String get token => _token;

  /// The messaging fabric the bridge relays over.
  MessagingRepository get messaging => _messaging;

  /// The project root.
  String get root => _root;

  /// The actual bound port (resolves ephemeral `0` binds after [start]).
  int get port => _http?.port ?? _port;

  /// The endpoint extensions pair against.
  String get url => 'ws://127.0.0.1:$port$bridgeWsPath';

  /// True between [start] and [stop].
  bool get running => _http != null;

  /// Connected extensions (unmodifiable snapshot).
  List<BridgeConnection> get clients => List.unmodifiable(_clients);

  /// Completes when the server socket is closed.
  Future<void> get done => _closed.future;

  /// Binds and starts accepting. Binds [port] (`0` picks an ephemeral one —
  /// read [port] afterwards).
  Future<void> start() async {
    final http = await HttpServer.bind(_address, _port);
    _http = http;
    // The request stream completes when the server stops listening; that
    // is the "server closed" signal (`done`), so `runBridgeServer` can
    // block on it and tests can await a clean shutdown.
    unawaited(
      http
          .forEach((request) => _handleRequest(request))
          .catchError((Object _) {})
          .then((_) {
            for (final client in _clients.toList()) {
              client.dispose();
            }
            if (!_closed.isCompleted) _closed.complete();
          }),
    );
  }

  /// Closes the listening socket and every connection.
  Future<void> stop() async {
    final http = _http;
    if (http == null) return;
    _http = null;
    await http.close(force: true);
  }

  /// Mints a FRESH pairing token; the old one stops working (E17).
  /// Connected extensions stay connected — only new handshakes need it.
  String mintToken() {
    _token = pairingToken();
    return _token;
  }

  void _remove(BridgeConnection connection) {
    _clients.remove(connection);
    onClientsChanged?.call();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Page JS can never reach the bridge: only extension contexts (which
    // send a chrome-extension:// origin) or origin-less clients (the tests,
    // curl -i) may upgrade (AC15).
    final origin = request.headers.value('origin');
    if (origin != null && !origin.startsWith('chrome-extension://')) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (request.uri.path != bridgeWsPath ||
        request.method != 'GET' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final connection = BridgeConnection(
        server: this,
        socket: socket,
        opHandler: dispatch,
        pollInterval: pollInterval,
        heartbeatInterval: heartbeatInterval,
        dispatchTimeout: dispatchTimeout,
      );
      _clients.add(connection);
      onClient?.call(connection);
      onClientsChanged?.call();
      connection.listen();
    } on Object catch (error) {
      // Upgrade raced a disconnect; nothing to serve.
      stdout.writeln('bridge: upgrade failed: $error');
    }
  }
}

/// One paired extension: its fabric mailbox, its pending `browserReq`s, and
/// the poll/heartbeat timers that keep mail and liveness flowing. All
/// per-connection state lives here.
final class BridgeConnection {
  BridgeConnection({
    required BridgeServer server,
    required WebSocket socket,
    this.opHandler,
    Duration? pollInterval,
    Duration? heartbeatInterval,
    Duration? dispatchTimeout,
  }) : _server = server,
       _socket = socket,
       _pollInterval = pollInterval ?? server.pollInterval,
       _heartbeatInterval = heartbeatInterval ?? server.heartbeatInterval,
       _dispatchTimeout = dispatchTimeout ?? server.dispatchTimeout;

  final BridgeServer _server;
  final WebSocket _socket;
  final Duration _pollInterval;
  final Duration _heartbeatInterval;
  final Duration _dispatchTimeout;

  /// The browser-op handler seam for phase 3: the browser-tools layer sets
  /// this per connection to route agent-initiated ops through [dispatch].
  /// Null today — [dispatch] works regardless.
  final Future<Map<String, dynamic>> Function(
    String op,
    Map<String, dynamic> args,
  )?
  opHandler;

  /// Fabric mailbox derived from the hello (`browser-ext/<agentId>`), null
  /// until paired.
  String? mailboxId;

  /// The extension's stable instance id (its hello agentId, or a random
  /// 8-hex suffix it may persist).
  String? agentId;

  /// Cosmetics from the hello, shown by `/browser status`.
  String? name;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final MailDeduper _deduper = MailDeduper();
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<dynamic>? _subscription;
  var _paired = false;
  var _disposed = false;

  /// Starts reading frames. Called once by the server after the upgrade.
  void listen() {
    _subscription = _socket.listen(
      _onData,
      onDone: dispose,
      onError: (Object _) => dispose(),
      cancelOnError: true,
    );
  }

  Future<void> _onData(dynamic data) async {
    final BridgeFrame frame;
    try {
      frame = BridgeFrame.decode(data as String);
    } on BridgeProtocolException catch (error) {
      // proto mismatch answers + closes; a malformed frame just gets an
      // error frame (WebSocket framing makes the next read clean).
      await _sendError(
        error.code,
        error.message,
        inReplyTo: error.inReplyTo,
        close: error.code == BridgeErrorCode.proto,
      );
      return;
    }
    if (!_paired) return _onFirstFrame(frame);
    switch (frame.op) {
      case BridgeOps.hello:
        await _sendError(
          BridgeErrorCode.badOp,
          'already paired',
          inReplyTo: frame.id,
        );
      case BridgeOps.mail:
        await _onMail(frame);
      case BridgeOps.ping:
        await _reply(frame, BridgeOps.pong);
      case BridgeOps.browserRes:
        _onBrowserRes(frame);
      default:
        await _sendError(
          BridgeErrorCode.badOp,
          'unknown op: ${frame.op}',
          inReplyTo: frame.id,
        );
    }
  }

  /// The handshake: first frame must be hello{proto:1, token}. Anything
  /// else — or a wrong/absent token — rejects and closes.
  Future<void> _onFirstFrame(BridgeFrame frame) async {
    if (frame.op != BridgeOps.hello) {
      await _sendError(
        BridgeErrorCode.badFrame,
        'expected hello',
        inReplyTo: frame.id,
        close: true,
      );
      return;
    }
    if (frame.fields['proto'] != bridgeProtocolVersion) {
      await _sendError(
        BridgeErrorCode.proto,
        'hello proto must be $bridgeProtocolVersion',
        inReplyTo: frame.id,
        close: true,
      );
      return;
    }
    if (!constantTimeEquals(frame.str('token') ?? '', _server.token)) {
      await _sendError(
        BridgeErrorCode.badToken,
        'pairing token rejected',
        inReplyTo: frame.id,
      );
      await close(bridgeBadTokenCloseCode);
      return;
    }
    agentId = frame.str('agentId') ?? randomMailboxSuffix();
    mailboxId = deriveMailboxId(agentId!);
    name = frame.str('name');
    await _server.messaging.register(mailboxId!);
    _paired = true;
    await _reply(
      frame,
      BridgeOps.welcome,
      fields: {
        'mailbox': mailboxId,
        'server': 'fa/${_server.version}',
        'capabilities': ['mail', 'browser'],
      },
    );
    // The offline queue drains immediately on welcome, then the poll keeps
    // the extension current (1s cadence) and the heartbeat keeps the
    // mailbox live in directory listings (5s cadence).
    await _drainFabric();
    _pollTimer = Timer.periodic(
      _pollInterval,
      (_) => unawaited(_drainFabric()),
    );
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_server.messaging.touch(mailboxId!)),
    );
  }

  Future<void> _onMail(BridgeFrame frame) async {
    final to = frame.str('to');
    final text = frame.str('text');
    if (to == null || to.isEmpty || text == null) {
      await _sendError(
        BridgeErrorCode.badArgs,
        'mail needs non-empty to and text',
        inReplyTo: frame.id,
      );
      return;
    }
    final message = AgentMessage(
      id: newMessageId(),
      fromId: mailboxId!,
      toId: to,
      text: text,
      sentAt: DateTime.now().toUtc().toIso8601String(),
      kind: frame.str('kind') == AgentMessageKind.user.name
          ? AgentMessageKind.user
          : AgentMessageKind.agent,
    );
    try {
      await _server.messaging.send(message);
    } on Object catch (error) {
      await _sendError(
        BridgeErrorCode.noTarget,
        'delivery failed: $error',
        inReplyTo: frame.id,
      );
      return;
    }
    // At-least-once: the client queues until this ack.
    await _reply(frame, BridgeOps.acked);
  }

  /// Drains this extension's fabric mailbox and forwards everything not
  /// already seen (bounded LRU dedupe on the fabric message id).
  Future<void> _drainFabric() async {
    final mailbox = mailboxId;
    if (_disposed || mailbox == null) return;
    List<AgentMessage> messages;
    try {
      messages = await _server.messaging.drain(mailbox);
    } on Object {
      return; // fabric hiccup — the next poll retries
    }
    for (final message in messages) {
      if (_deduper.isDuplicate(message.id)) continue;
      await _send(
        BridgeFrame(
          id: nextFrameId(),
          op: BridgeOps.mail,
          fields: {
            'from': message.fromId,
            'text': message.text,
            'ts': message.sentAt,
            'msgId': message.id,
            if (message.kind != AgentMessageKind.agent)
              'kind': message.kind.name,
          },
        ),
      );
    }
  }

  /// Routes a browser op to the extension and resolves with the correlated
  /// `browserRes` payload: `{ok: true, result}` or
  /// `{ok: false, error, code?}`. Times out after 30s; disconnects resolve
  /// every pending dispatch with a clean error.
  Future<Map<String, dynamic>> dispatch(
    String op,
    Map<String, dynamic> args,
  ) async {
    if (!_paired || _disposed) {
      return {
        'ok': false,
        'error': 'no browser extension connected',
        'code': BridgeErrorCode.noTarget.wire,
      };
    }
    final correlation = nextFrameId();
    final completer = Completer<Map<String, dynamic>>();
    _pending[correlation] = completer;
    await _send(
      BridgeFrame(
        id: correlation,
        op: BridgeOps.browserReq,
        fields: {bridgeBrowserOpField: op, 'args': args},
      ),
    );
    try {
      return await completer.future.timeout(
        _dispatchTimeout,
        onTimeout: () {
          _pending.remove(correlation);
          return {
            'ok': false,
            'error':
                'browser op timed out after ${_dispatchTimeout.inSeconds}s',
            'code': BridgeErrorCode.timeout.wire,
          };
        },
      );
    } finally {
      _pending.remove(correlation);
    }
  }

  void _onBrowserRes(BridgeFrame frame) {
    // Flat frame, amended contract: the ENVELOPE id is the correlation id
    // (the extension echoes the browserReq envelope id verbatim).
    final completer = _pending.remove(frame.id);
    if (completer == null || completer.isCompleted) return;
    if (frame.fields['ok'] == true) {
      completer.complete({'ok': true, 'result': frame.fields['result']});
      return;
    }
    completer.complete({
      'ok': false,
      'error': frame.str('error') ?? 'browser op failed',
      'code': ?frame.str('code'),
    });
  }

  /// Tears the connection down: timers cancelled, pending dispatches
  /// resolved with clean errors, socket closed, server set updated.
  void dispose() => unawaited(close());

  Future<void> close([int? code]) async {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    unawaited(_subscription?.cancel());
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete({
          'ok': false,
          'error': 'browser extension disconnected',
          'code': BridgeErrorCode.noTarget.wire,
        });
      }
    }
    _pending.clear();
    _server._remove(this);
    try {
      await _socket.close(code);
    } on Object {
      // Already dead — nothing to close.
    }
  }

  Future<void> _reply(
    BridgeFrame request,
    String op, {
    Map<String, dynamic> fields = const {},
  }) => _send(BridgeFrame(id: request.id, op: op, fields: fields));

  Future<void> _sendError(
    BridgeErrorCode code,
    String message, {
    String? inReplyTo,
    bool close = false,
  }) async {
    await _send(
      BridgeFrame(
        id: inReplyTo ?? nextFrameId(),
        op: BridgeOps.error,
        fields: {'code': code.wire, 'error': message},
      ),
    );
    if (close) await this.close();
  }

  Future<void> _send(BridgeFrame frame) async {
    if (_disposed) return;
    try {
      _socket.add(frame.encode());
    } on Object {
      dispose();
    }
  }
}

/// Constant-time string comparison for the pairing token: always scans the
/// full input, so handshake latency does not leak the token byte by byte.
bool constantTimeEquals(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  var diff = left.length ^ right.length;
  for (var i = 0; i < left.length && i < right.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff == 0;
}

/// `fa serve --bridge` entry point: resolves the token (explicit flag, else
/// the project token file, mint-if-absent), starts the bridge over the
/// given fabric, prints the pairing hint, and blocks forever.
Future<void> runBridgeServer({
  required MessagingRepository messaging,
  required String root,
  int port = bridgeDefaultPort,
  String? token,
  String version = '0',
  void Function(BridgeConnection)? onClient,
  Future<Map<String, dynamic>> Function(String op, Map<String, dynamic> args)?
  dispatch,
}) async {
  final resolvedToken = token ?? await BridgeTokenFile(root).ensure();
  final server = BridgeServer(
    messaging: messaging,
    root: root,
    port: port,
    token: resolvedToken,
    version: version,
    onClient: onClient,
    dispatch: dispatch,
  );
  await server.start();
  stdout.writeln('bridge listening on ${server.url}');
  stdout.writeln('run /browser connect in fa to pair');
  await server.done;
}
