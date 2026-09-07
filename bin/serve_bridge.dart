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
    this.providers = const [],
    this.copyKeys = false,
    this.keys,
    this.llmRelay,
    String? hostname,
  }) : _messaging = messaging,
       _root = root,
       _token = token,
       _port = port,
       _hostname = hostname ?? Platform.localHostname,
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

  /// Saved custom providers pushed (metadata) on every pairing that asks
  /// for it (issue #34 item 3). Empty = no providers-sync capability.
  final List<CustomProviderEntry> providers;

  /// Copy-on-pair mode: keys transfer once in the sync push and the
  /// staged bridge copy is wiped on the client's ack. Opt-in via
  /// `/browser connect --copy-keys`; default is keyless proxy.
  final bool copyKeys;

  /// Key lookups for the relay and the copy-mode staging. Null (tests,
  /// web hosts): every key lookup misses.
  final SecureKeyCache? keys;

  /// The relay transport (`llmReq` streaming). Null: llmReq answers with
  /// a clean llmRes error.
  final LlmRelayStream? llmRelay;

  final String _hostname;

  /// Provenance host stamped on synced entries (`synced-from-cli@<host>`).
  String get hostname => _hostname;

  /// The welcome capabilities: mail + browser, plus `providers-sync`
  /// when there are saved providers to push (additive — old clients
  /// ignore the extra entry).
  List<String> get capabilities => [
    'mail',
    'browser',
    if (providers.isNotEmpty) providersSyncCapability,
  ];

  /// The `llmReq` handler: frame glue over [llmRelay] with key
  /// resolution against [providers] + [keys]. Null when no transport is
  /// wired — llmReq then answers with a clean llmRes error.
  BridgeLlmRelay? get llmRelayHandler => llmRelay == null
      ? null
      : BridgeLlmRelay(relay: llmRelay!, resolveKey: _relayResolveKey);

  /// Resolves the key for a relay request: the matching saved entry's
  /// slot (env first, then the secure store — the CLI's own lookup
  /// order). An unknown provider falls back to the host-scoped slot.
  String? _relayResolveKey(String baseUrl, String? providerName) {
    final entry = providerName != null
        ? providers.where((e) => e.name == providerName).firstOrNull
        : providers.where((e) => e.baseUrl == baseUrl).firstOrNull;
    if (entry != null) return resolveProviderKey(entry);
    return _readStoredKey(CustomProviderRegistry.keyNameFor(baseUrl));
  }

  /// Resolves one saved entry's key: its explicit [CustomProviderEntry
  /// .keyName] when set, else the host(+entry)-scoped slot name.
  String? resolveProviderKey(CustomProviderEntry entry) {
    return _readStoredKey(
      entry.keyName ??
          CustomProviderRegistry.keyNameFor(
            entry.baseUrl,
            providerName: entry.name,
          ),
    );
  }

  String? _readStoredKey(String keyName) {
    final env = Platform.environment[keyName];
    if (env != null && env.isNotEmpty) return env;
    return keys?.read(keyName);
  }

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

  /// Envelope id of the pushed providersSync frame (ack correlation).
  String? _syncFrameId;

  /// Copy-on-pair staging: the keys sent in the sync push, held ONLY
  /// until the client acks. Null everywhere else.
  Map<String, String>? _stagedKeys;

  /// Test/observability seam: the staged copy-on-pair keys (non-null
  /// between the sync push and the client's ack, then wiped).
  Map<String, String>? get stagedCopyKeys => _stagedKeys;

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
      case BridgeOps.acked:
        _onSyncAck(frame);
      case BridgeOps.llmReq:
        await _onLlmReq(frame);
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
        'capabilities': _server.capabilities,
      },
    );
    // Providers sync (issue #34 item 3): pushed right after welcome, but
    // ONLY to hellos advertising the capability — an older extension
    // never sees the frame, so the additive op degrades to silence
    // instead of badOp noise.
    final caps = frame.fields['caps'];
    if (caps is List && caps.contains(providersSyncCapability)) {
      await _pushProvidersSync();
    }

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

  /// Builds and pushes the providers-sync frame. Proxy mode (default)
  /// sends metadata only; copy mode adds the resolved keys in the
  /// dedicated `keys` field and stages them here until the client acks.
  Future<void> _pushProvidersSync() async {
    if (_server.providers.isEmpty) return;
    final copyKeys = <String, String>{};
    if (_server.copyKeys) {
      for (final entry in _server.providers) {
        final key = _server.resolveProviderKey(entry);
        if (key != null && key.isNotEmpty) copyKeys[entry.name] = key;
      }
    }
    final payload = buildProvidersSync(
      _server.providers,
      mode: _server.copyKeys ? ProvidersSyncMode.copy : ProvidersSyncMode.proxy,
      hostname: _server.hostname,
      keys: copyKeys,
    );
    final id = nextFrameId();
    _syncFrameId = id;
    await _send(
      BridgeFrame(
        id: id,
        op: BridgeOps.providersSync,
        fields: {'sync': payload.toJson()},
      ),
    );
    // Copy-on-pair staging: held ONLY until the ack wipes it (or the
    // connection dies — close() clears it too).
    if (copyKeys.isNotEmpty) _stagedKeys = copyKeys;
  }

  /// The client acked the sync push: wipe the staged key copy from
  /// memory (copy-on-pair contract — the bridge never keeps a copy).
  void _onSyncAck(BridgeFrame frame) {
    if (frame.id == _syncFrameId) {
      _stagedKeys = null;
      _syncFrameId = null;
    }
  }

  /// Routes an `llmReq` through the server's relay (key injected
  /// server-side; key bytes never ride a frame or a log line).
  Future<void> _onLlmReq(BridgeFrame frame) async {
    final relay = _server.llmRelayHandler;
    if (relay == null) {
      await _send(
        BridgeFrame(
          id: frame.id,
          op: BridgeOps.llmRes,
          fields: {'error': 'llm relay not available on this bridge'},
        ),
      );
      return;
    }
    await relay.handle(frame, _send);
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
    _stagedKeys = null;
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
