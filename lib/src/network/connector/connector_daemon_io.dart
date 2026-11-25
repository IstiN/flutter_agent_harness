// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// `dart:io` loopback daemon server and client for the single-per-machine
/// Machine Connector (`docs/fa_network_connector.md` §3 / §10).
///
/// Exported only from `lib/io.dart` — never from the pure core barrel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../cli/network_presence.dart';
import '../../cli/network_store.dart';
import '../../session/attach/pid_probe_io.dart';
import '../../session/session_catalog.dart';
import '../network_account.dart';
import '../network_account_client.dart';
import '../network_roster.dart';
import 'connector_daemon_protocol.dart';
import 'device_transport_io.dart';
import 'upstream_client.dart' show ConnectorTransport;
import 'envelope.dart';
import 'machine_connector.dart';
import 'multi_session_connector_host.dart';

/// Default state file path for the shared Machine Connector daemon:
/// `<home>/.fah/network/connector.json`.
File connectorDaemonStateFile(String homeDirectory) =>
    File('$homeDirectory/.fah/network/connector.json');

/// Reads and validates [connectorDaemonStateFile]; returns null if absent or
/// corrupt.
Future<ConnectorDaemonState?> readConnectorDaemonState(File file) async {
  try {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    return ConnectorDaemonState.tryFromJson(decoded);
  } on Object {
    return null;
  }
}

/// Atomically writes [state] to [file] with mode 0600 (carries local bearer).
Future<void> writeConnectorDaemonState(
  File file,
  ConnectorDaemonState state,
) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.$pid.tmp');
  try {
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', [
        '600',
        tmp.path,
      ]).catchError((_) => ProcessResult(0, 1, '', ''));
    }
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }
  } finally {
    if (await tmp.exists()) await tmp.delete();
  }
}

/// Probes whether a connector daemon described by [state] is alive and serving
/// `/healthz` on loopback for the expected [deviceId].
Future<bool> probeConnectorDaemon(
  ConnectorDaemonState state, {
  String? expectedDeviceId,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (expectedDeviceId != null && state.deviceId != expectedDeviceId) {
    return false;
  }
  if (probePidAlive(state.pid) == false) return false;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(state.healthzUri).timeout(timeout);
    req.headers.set('authorization', 'Bearer ${state.token}');
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode != 200) return false;
    final decoded = jsonDecode(body);
    return decoded is Map && decoded['deviceId'] == state.deviceId;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Loopback WebSocket server wrapping one [MultiSessionConnectorHost] so N
/// local CLI processes and desktop app instances share ONE upstream WS.
/// Acquires an exclusive OS-level file lock on `<stateFile>.lock` so two
/// concurrent `fa connector run` starts can never both dial upstream for the
/// same `deviceId` (eliminating cold-start eviction races). Returns the open
/// locked handle on success, or null when another daemon holds the lock.
Future<RandomAccessFile?> tryAcquireConnectorDaemonLock(File stateFile) async {
  final lockFile = File('${stateFile.path}.lock');
  await lockFile.parent.create(recursive: true);
  final raf = await lockFile.open(mode: FileMode.write);
  try {
    await raf.lock(FileLock.exclusive);
    return raf;
  } on FileSystemException {
    await raf.close().catchError((Object _) {});
    return null;
  }
}

/// Requests a graceful shutdown of a running daemon via `POST /shutdown`
/// (works on Windows where `Process.killPid` is a hard terminate). Returns
/// true when the daemon acknowledged the shutdown request.
Future<bool> requestConnectorDaemonShutdown(
  ConnectorDaemonState state, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final uri = Uri.parse('http://127.0.0.1:${state.port}/shutdown');
    final req = await client.postUrl(uri).timeout(timeout);
    req.headers.set('authorization', 'Bearer ${state.token}');
    final res = await req.close().timeout(timeout);
    await res.drain<void>().timeout(timeout);
    return res.statusCode == HttpStatus.ok;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

final class ConnectorDaemonServer {
  ConnectorDaemonServer({
    required this.host,
    required this.stateFile,
    this.port = 0,
    this.onShutdownRequested,
    String? token,
  }) : token = token ?? _generateLocalToken();

  final MultiSessionConnectorHost host;
  final File stateFile;
  final int port;
  final void Function()? onShutdownRequested;
  final String token;
  HttpServer? _server;
  int? _boundPort;
  final _clients = <WebSocket, _LocalClientConnection>{};
  final _pendingDeliveries = <String, Completer<void>>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  var _nextDeliverySeq = 0;

  /// Bound loopback port after [start].
  int get boundPort => _boundPort ?? port;

  /// Current persisted state descriptor (valid after [start]).
  ConnectorDaemonState get state => ConnectorDaemonState(
    pid: pid,
    port: boundPort,
    token: token,
    deviceId: host.device.deviceId,
    baseUrl: host.baseUrl,
  );

  /// Starts the loopback server, writes [stateFile], and boots [host].
  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _boundPort = server.port;
    await writeConnectorDaemonState(stateFile, state);
    _subscriptions
      ..add(host.rosterFrames.listen(_broadcastRoster))
      ..add(host.presenceFrames.listen(_broadcastPresence));
    unawaited(_serveRequests(server));
    await host.start();
  }

  /// Shuts down the loopback server, removes [stateFile], and stops [host].
  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    for (final completer in _pendingDeliveries.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('connector daemon stopped'));
      }
    }
    _pendingDeliveries.clear();
    final sockets = _clients.keys.toList(growable: false);
    _clients.clear();
    for (final ws in sockets) {
      await ws.close().catchError((Object _) {});
    }
    await _server?.close(force: true);
    _server = null;
    await host.dispose();
    await _removeOwnStateFile();
  }

  Future<void> _removeOwnStateFile() async {
    try {
      final current = await readConnectorDaemonState(stateFile);
      if (current != null && current.pid == pid && current.token == token) {
        await stateFile.delete();
      }
    } on Object {
      // Best-effort cleanup.
    }
  }

  Future<void> _serveRequests(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final auth = request.headers.value('authorization');
    if (auth != 'Bearer $token') {
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..write('unauthorized');
      await request.response.close();
      return;
    }
    if (request.uri.path == '/healthz') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'ok': true,
            'pid': pid,
            'deviceId': host.device.deviceId,
            'phase': host.phase.name,
            'sessions': host.activeSessionIds.length,
          }),
        );
      await request.response.close();
      return;
    }
    if (request.uri.path == '/shutdown' && request.method == 'POST') {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('stopping');
      await request.response.close();
      onShutdownRequested?.call();
      return;
    }
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      _attachClient(ws);
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _attachClient(WebSocket ws) {
    final conn = _LocalClientConnection(ws);
    _clients[ws] = conn;
    // Replay cached roster frames immediately so newly attached clients
    // (such as `fa network devices --roster`) get current state right away.
    for (final frame in host.recentRosterFrames) {
      _sendTo(ws, {
        'type': ConnectorDaemonWire.rosterEvent,
        'envelope': frame.toJson(),
      });
    }
    ws.listen(
      (raw) {
        if (raw is String) unawaited(_handleClientMessage(conn, raw));
      },
      onDone: () => unawaited(_detachClient(conn)),
      onError: (Object _) => unawaited(_detachClient(conn)),
    );
  }

  Future<void> _detachClient(_LocalClientConnection conn) async {
    if (_clients.remove(conn.socket) == null) return;
    final sessions = conn.sessionIds.toList(growable: false);
    conn.sessionIds.clear();
    for (final id in sessions) {
      await host.unregisterSession(id);
    }
  }

  Future<void> _handleClientMessage(
    _LocalClientConnection conn,
    String raw,
  ) async {
    final msg = ConnectorDaemonWire.tryDecode(raw);
    if (msg == null) return;
    final reqId = msg['reqId'] as String?;
    try {
      await _dispatchClientMessage(conn, msg, reqId);
    } on Object catch (error) {
      _replyError(conn.socket, reqId, '$error');
    }
  }

  Future<void> _dispatchClientMessage(
    _LocalClientConnection conn,
    Map<String, Object?> msg,
    String? reqId,
  ) async {
    switch (msg['type']) {
      case ConnectorDaemonWire.registerSession:
        await _handleRegisterSession(conn, msg);
        _replyOk(conn.socket, reqId);
      case ConnectorDaemonWire.unregisterSession:
        await _handleUnregisterSession(conn, msg, reqId);
      case ConnectorDaemonWire.setBusy:
        final sessionId = msg['sessionId'] as String?;
        if (sessionId != null) host.setBusy(sessionId, msg['busy'] == true);
        _replyOk(conn.socket, reqId);
      case ConnectorDaemonWire.sendDmReply:
        await _handleSendDmReply(conn, msg, reqId);
      case ConnectorDaemonWire.dmDeliverAck:
        _handleDmDeliverAck(msg);
      case ConnectorDaemonWire.getRoster:
        _replyOk(conn.socket, reqId, {
          'frames': [for (final f in host.recentRosterFrames) f.toJson()],
        });
    }
  }

  Future<void> _handleUnregisterSession(
    _LocalClientConnection conn,
    Map<String, Object?> msg,
    String? reqId,
  ) async {
    final sessionId = msg['sessionId'] as String?;
    if (sessionId != null) {
      conn.sessionIds.remove(sessionId);
      await host.unregisterSession(sessionId);
    }
    _replyOk(conn.socket, reqId);
  }

  Future<void> _handleSendDmReply(
    _LocalClientConnection conn,
    Map<String, Object?> msg,
    String? reqId,
  ) async {
    final msgId = await host.sendNetworkDmReply(
      address: msg['address'] as String? ?? '',
      text: msg['text'] as String? ?? '',
      callerSessionId: msg['sessionId'] as String?,
    );
    _replyOk(conn.socket, reqId, {'msgId': msgId});
  }

  void _handleDmDeliverAck(Map<String, Object?> msg) {
    final deliveryId = msg['deliveryId'] as String?;
    final completer = _pendingDeliveries.remove(deliveryId);
    if (completer == null || completer.isCompleted) return;
    if (msg['ok'] == true) {
      completer.complete();
      return;
    }
    completer.completeError(
      StateError(msg['error'] as String? ?? 'client DM sink failed'),
    );
  }

  Future<void> _handleRegisterSession(
    _LocalClientConnection conn,
    Map<String, Object?> msg,
  ) async {
    final sessionId = msg['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      throw ArgumentError('sessionId is required');
    }
    conn.sessionIds.add(sessionId);
    await host.registerSession(
      CliNetworkSession(
        sessionId: sessionId,
        mailboxPrefix: msg['mailboxPrefix'] as String?,
        displayName: msg['displayName'] as String?,
        cwd: msg['cwd'] as String?,
        dmSink: (dm) => _deliverDmToClient(conn, sessionId, dm),
        onNotice: (message) => _sendTo(conn.socket, {
          'type': ConnectorDaemonWire.noticeEvent,
          'sessionId': sessionId,
          'message': message,
        }),
      ),
    );
  }

  Future<void> _deliverDmToClient(
    _LocalClientConnection conn,
    String sessionId,
    CliNetworkDm dm,
  ) async {
    final deliveryId = 'd-${++_nextDeliverySeq}';
    final completer = Completer<void>();
    _pendingDeliveries[deliveryId] = completer;
    _sendTo(
      conn.socket,
      ConnectorDaemonWire.encodeDmDeliver(
        deliveryId: deliveryId,
        sessionId: sessionId,
        envelope: dm.mail.envelope,
        text: dm.mail.text,
        senderLabel: dm.senderLabel,
        replyAddress: dm.replyAddress,
        senderPubkey: dm.mail.senderPubkey,
        threaded: dm.mail.threaded,
      ),
    );
    try {
      await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      _pendingDeliveries.remove(deliveryId);
    }
  }

  void _broadcastRoster(NetworkEnvelope frame) {
    final payload = {
      'type': ConnectorDaemonWire.rosterEvent,
      'envelope': frame.toJson(),
    };
    for (final ws in _clients.keys.toList(growable: false)) {
      _sendTo(ws, payload);
    }
  }

  void _broadcastPresence(NetworkEnvelope frame) {
    final payload = {
      'type': ConnectorDaemonWire.presenceEvent,
      'envelope': frame.toJson(),
    };
    for (final ws in _clients.keys.toList(growable: false)) {
      _sendTo(ws, payload);
    }
  }

  void _replyOk(WebSocket ws, String? reqId, [Map<String, Object?>? extra]) {
    if (reqId == null) return;
    _sendTo(ws, {
      'type': ConnectorDaemonWire.rpcResult,
      'reqId': reqId,
      'ok': true,
      ...?extra,
    });
  }

  void _replyError(WebSocket ws, String? reqId, String error) {
    if (reqId == null) return;
    _sendTo(ws, {
      'type': ConnectorDaemonWire.rpcResult,
      'reqId': reqId,
      'ok': false,
      'error': error,
    });
  }

  void _sendTo(WebSocket ws, Map<String, Object?> payload) {
    try {
      ws.add(ConnectorDaemonWire.encode(payload));
    } on Object {
      // Disconnected client; onDone handles cleanup.
    }
  }

  static String _generateLocalToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(24, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

final class _LocalClientConnection {
  _LocalClientConnection(this.socket);
  final WebSocket socket;
  final sessionIds = <String>{};
}

/// The ONE place a CLI process picks its network-presence source — the
/// single-upstream-per-machine rule (contract §3/§10).
///
/// [ensureDaemonRunning] probes the daemon state file for [deviceId] and
/// may spawn a detached `fa connector run`, returning its state — null
/// when no daemon is (or can be made) alive. With a state, the process
/// gets the loopback [SharedConnectorPresenceClient] and NEVER dials the
/// upstream itself (N sessions → one socket; an eviction ping-pong is
/// impossible); without one, [directController] is the no-daemon fallback.
///
/// Every CLI construction site goes through here — the `fa` boot (which
/// mailbox-woken sessions take as well) and the `fa network` roster reads
/// ([readRosterFromSharedConnector]); `test/bin_network_presence_wiring_test.dart`
/// pins that `bin/` builds no direct controller anywhere else.
Future<CliNetworkPresence> resolveCliNetworkPresence({
  required File stateFile,
  required String deviceId,
  required Future<ConnectorDaemonState?> Function() ensureDaemonRunning,
  required CliNetworkPresence Function() directController,
}) async {
  final state = await ensureDaemonRunning();
  if (state == null) return directController();
  return SharedConnectorPresenceClient(
    stateFile: stateFile,
    deviceId: deviceId,
    ensureDaemonRunning: ensureDaemonRunning,
  );
}

/// One-shot device-roster read behind `fa network` (the CLI runner and the
/// hub plugin's runner share it): the cached roster of a daemon that is
/// ALIVE for [deviceId] (state file + probe — never spawns one; zero
/// upstream dials from this process), else a direct controller — built by
/// [directController], connected, read and disposed by
/// [readNetworkDeviceRoster]. A daemon whose upstream link is still down
/// has no cached roster: that reads direct too, as before the daemon
/// existed.
Future<List<NetworkDeviceRow>> readRosterFromSharedConnector({
  required File stateFile,
  required String deviceId,
  required NetworkPresenceController Function() directController,
}) async {
  final state = await readConnectorDaemonState(stateFile);
  if (state != null &&
      await probeConnectorDaemon(state, expectedDeviceId: deviceId)) {
    final client = SharedConnectorPresenceClient(
      stateFile: stateFile,
      deviceId: deviceId,
    );
    try {
      final frames = await client.fetchRosterFrames();
      if (frames.isNotEmpty) return parseNetworkDeviceRoster(frames);
    } on Object {
      // Fall through to the direct read: no cached roster (yet).
    } finally {
      await client.stop();
    }
  }
  return readNetworkDeviceRoster(directController());
}

/// The direct (no-daemon) upstream controller of a CLI process over the real
/// device transport — the ONLY production construction site of a
/// [NetworkPresenceController] (the daemon itself owns the one other
/// upstream: [MultiSessionConnectorHost] over the same transport). Built
/// solely as the fallback of [resolveCliNetworkPresence] /
/// [readRosterFromSharedConnector], never directly: a second direct dial
/// per device is the eviction-storm regression.
/// [transport] is the production seam: tests inject a fake upstream.
NetworkPresenceController directCliNetworkPresence({
  required NetworkDeviceCredentials device,
  required String baseUrl,
  required DeviceEnrollmentClient devices,
  required NetworkCredentialStore store,
  SessionCatalogStore? catalogStore,
  ConnectorTransport transport = const IoConnectorTransport(),
}) => NetworkPresenceController(
  catalogStore: catalogStore,
  device: device,
  baseUrl: baseUrl,
  ticketProvider: () =>
      devices.wsTicket(baseUrl: baseUrl, deviceToken: device.deviceToken),
  transport: transport,
  rosterClient: devices,
  dmKeyStore: store,
);

/// The device-roster read behind every `fa network` command surface — the
/// CLI runner and the hub plugin's runner share this one function: the
/// enrolled device off [store] (not enrolled → [NetworkAuthException]),
/// then [readRosterFromSharedConnector] against the daemon [stateFile].
Future<List<NetworkDeviceRow>> readCliNetworkRoster({
  required NetworkCredentialStore store,
  required DeviceEnrollmentClient devices,
  required String baseUrl,
  required File stateFile,
}) async {
  final device = await store.readDevice();
  if (device == null) {
    throw const NetworkAuthException('not enrolled; run enroll first');
  }
  return readRosterFromSharedConnector(
    stateFile: stateFile,
    deviceId: device.deviceId,
    directController: () => directCliNetworkPresence(
      device: device,
      baseUrl: baseUrl,
      devices: devices,
      store: store,
    ),
  );
}

/// Client-side [CliNetworkPresence] implementation that attaches to the shared
/// per-machine [ConnectorDaemonServer] over loopback instead of opening its
/// own competing upstream WebSocket to `fa_network`.
final class SharedConnectorPresenceClient
    implements CliNetworkPresence, CliNetworkDmReplySender {
  SharedConnectorPresenceClient({
    required this.stateFile,
    required this.deviceId,
    this.ensureDaemonRunning,
    this.reconnectDelay = const Duration(seconds: 2),
    this.onLog,
  });

  final File stateFile;
  final Duration reconnectDelay;
  final String deviceId;

  /// Optional callback that spawns a detached `fa connector run` daemon if
  /// none is currently alive and returns its [ConnectorDaemonState].
  final Future<ConnectorDaemonState?> Function()? ensureDaemonRunning;
  final void Function(String line)? onLog;

  WebSocket? _socket;
  StreamSubscription<Object?>? _socketSub;
  CliNetworkSession? _session;
  bool _busy = false;
  bool _stopped = false;
  var _nextReqId = 0;
  final _pendingRpcs = <String, Completer<Map<String, Object?>>>{};
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  Timer? _reconnectTimer;

  /// Roster frames forwarded by the shared daemon.
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

  @override
  Future<void> startSession(CliNetworkSession session) async {
    _stopped = false;
    final previous = _session;
    _session = session;
    _busy = false;
    await _ensureConnected();
    if (previous != null && previous.sessionId != session.sessionId) {
      await _rpc(ConnectorDaemonWire.unregisterSession, {
        'sessionId': previous.sessionId,
      }).catchError((Object _) => <String, Object?>{});
    }
    await _registerCurrentSession();
  }

  @override
  void setBusy(bool busy) {
    _busy = busy;
    final session = _session;
    if (session == null || _socket == null) return;
    unawaited(
      _rpc(ConnectorDaemonWire.setBusy, {
        'sessionId': session.sessionId,
        'busy': busy,
      }).catchError((Object _) => <String, Object?>{}),
    );
  }

  @override
  Future<String> sendNetworkDmReply({
    required String address,
    required String text,
  }) async {
    await _ensureConnected();
    final result = await _rpc(ConnectorDaemonWire.sendDmReply, {
      'address': address,
      'text': text,
      if (_session != null) 'sessionId': _session!.sessionId,
    });
    final msgId = result['msgId'];
    if (msgId is! String || msgId.isEmpty) {
      throw StateError('shared connector did not return a msgId');
    }
    return msgId;
  }

  /// Requests the latest cached roster frames from the shared daemon without
  /// opening a new upstream WebSocket.
  Future<List<NetworkEnvelope>> fetchRosterFrames() async {
    await _ensureConnected();
    final result = await _rpc(ConnectorDaemonWire.getRoster, const {});
    final rawFrames = result['frames'];
    if (rawFrames is! List) return const [];
    return [for (final item in rawFrames) ?_tryParseEnvelope(item)];
  }

  static NetworkEnvelope? _tryParseEnvelope(Object? raw) {
    if (raw is! Map) return null;
    try {
      return NetworkEnvelope.fromJson({
        for (final MapEntry(:key, :value) in raw.entries) '$key': value,
      });
    } on Object {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final session = _session;
    if (session != null && _socket != null) {
      await _rpc(ConnectorDaemonWire.unregisterSession, {
        'sessionId': session.sessionId,
      }).catchError((Object _) => <String, Object?>{});
    }
    await _closeSocket();
  }

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    var state = await readConnectorDaemonState(stateFile);
    if (state == null ||
        !await probeConnectorDaemon(state, expectedDeviceId: deviceId)) {
      state = await ensureDaemonRunning?.call();
    }
    if (state == null) {
      throw StateError('shared connector daemon is unavailable');
    }
    final ws = await WebSocket.connect(
      state.wsUri.toString(),
      headers: {'authorization': 'Bearer ${state.token}'},
    );
    _socket = ws;
    _socketSub = ws.listen(
      (raw) {
        if (raw is String) unawaited(_handleDaemonMessage(raw));
      },
      onDone: _handleDisconnect,
      onError: (Object _) => _handleDisconnect(),
    );
  }

  Future<void> _registerCurrentSession() async {
    final session = _session;
    if (session == null || _socket == null) return;
    await _rpc(ConnectorDaemonWire.registerSession, {
      'sessionId': session.sessionId,
      if (session.mailboxPrefix != null) 'mailboxPrefix': session.mailboxPrefix,
      if (session.displayName != null) 'displayName': session.displayName,
      if (session.cwd != null) 'cwd': session.cwd,
    });
    if (_busy) {
      await _rpc(ConnectorDaemonWire.setBusy, {
        'sessionId': session.sessionId,
        'busy': true,
      });
    }
  }

  Future<Map<String, Object?>> _rpc(
    String type,
    Map<String, Object?> body,
  ) async {
    final ws = _socket;
    if (ws == null) throw StateError('not connected to shared connector');
    final reqId = 'r-${++_nextReqId}';
    final completer = Completer<Map<String, Object?>>();
    _pendingRpcs[reqId] = completer;
    ws.add(ConnectorDaemonWire.encode({'type': type, 'reqId': reqId, ...body}));
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      _pendingRpcs.remove(reqId);
    }
  }

  Future<void> _handleDaemonMessage(String raw) async {
    final msg = ConnectorDaemonWire.tryDecode(raw);
    if (msg == null) return;
    switch (msg['type']) {
      case ConnectorDaemonWire.rpcResult:
        _resolveRpcResult(msg);
      case ConnectorDaemonWire.dmDeliver:
        await _handleDmDeliver(msg);
      case ConnectorDaemonWire.rosterEvent:
        _emitRosterEnvelope(msg['envelope']);
      case ConnectorDaemonWire.noticeEvent:
        final text = msg['message'] as String?;
        if (text != null) _session?.onNotice?.call(text);
    }
  }

  void _resolveRpcResult(Map<String, Object?> msg) {
    final completer = _pendingRpcs.remove(msg['reqId'] as String?);
    if (completer == null || completer.isCompleted) return;
    if (msg['ok'] == true) {
      completer.complete(msg);
      return;
    }
    completer.completeError(
      StateError('${msg['error'] ?? 'shared connector RPC failed'}'),
    );
  }

  void _emitRosterEnvelope(Object? rawEnv) {
    if (rawEnv is! Map || _rosterFrames.isClosed) return;
    try {
      _rosterFrames.add(
        NetworkEnvelope.fromJson({
          for (final MapEntry(:key, :value) in rawEnv.entries) '$key': value,
        }),
      );
    } on Object {
      // Ignore malformed frame.
    }
  }

  Future<void> _handleDmDeliver(Map<String, Object?> msg) async {
    final deliveryId = msg['deliveryId'] as String? ?? '';
    final sink = _session?.dmSink;
    if (sink == null) {
      _sendAck(deliveryId, ok: false, error: 'no local DM sink');
      return;
    }
    try {
      final rawEnv = msg['envelope'] as Map;
      final envelope = NetworkEnvelope.fromJson({
        for (final MapEntry(:key, :value) in rawEnv.entries) '$key': value,
      });
      final dm = CliNetworkDm(
        mail: InboundMail(
          envelope: envelope,
          text: msg['text'] as String? ?? '',
          sessionId: msg['sessionId'] as String?,
          senderPubkey: msg['senderPubkey'] as String?,
          threaded: msg['threaded'] == true,
        ),
        senderLabel: msg['senderLabel'] as String? ?? '',
        replyAddress: msg['replyAddress'] as String? ?? '',
      );
      await sink(dm);
      _sendAck(deliveryId, ok: true);
    } on Object catch (error) {
      _sendAck(deliveryId, ok: false, error: '$error');
    }
  }

  void _sendAck(String deliveryId, {required bool ok, String? error}) {
    final ws = _socket;
    if (ws == null) return;
    try {
      ws.add(
        ConnectorDaemonWire.encode({
          'type': ConnectorDaemonWire.dmDeliverAck,
          'deliveryId': deliveryId,
          'ok': ok,
          'error': ?error,
        }),
      );
    } on Object {
      // Ignore write failure on closing socket.
    }
  }

  void _handleDisconnect() {
    _socket = null;
    _failPendingRpcs('shared connector disconnected');
    if (!_stopped) _scheduleReconnect(reconnectDelay);
  }

  void _failPendingRpcs(String reason) {
    for (final completer in _pendingRpcs.values) {
      if (!completer.isCompleted) completer.completeError(StateError(reason));
    }
    _pendingRpcs.clear();
  }

  void _scheduleReconnect(Duration delay) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_reconnect()));
  }

  Future<void> _reconnect() async {
    if (_stopped || _socket != null) return;
    try {
      await _ensureConnected();
      await _registerCurrentSession();
    } on Object {
      if (!_stopped) _scheduleReconnect(reconnectDelay);
    }
  }

  Future<void> _closeSocket() async {
    await _socketSub?.cancel();
    _socketSub = null;
    final ws = _socket;
    _socket = null;
    if (ws != null) await ws.close().catchError((Object _) {});
  }
}
