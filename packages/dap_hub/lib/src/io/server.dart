// The dart:io HTTP/WebSocket server binding for the DAP/1 hub.
//
// Port of the Go main.go (buildMux/run) + relay.go handleWS: one
// WebSocket endpoint (`GET /ws`, bearer-authenticated before the
// upgrade), the admin REST API, and `/healthz`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../hub.dart';
import 'raw_ws.dart';

/// The default interval between protocol-level WebSocket pings; a missed
/// pong lets dart:io terminate the half-open connection (Go: 30 s ping
/// loop in writePump).
const defaultPingInterval = Duration(seconds: 30);

/// The RFC 6455 accept-key GUID.
const _wsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// Serves one [DapHub] over HTTP/WebSocket (the whole DAP/1 endpoint
/// surface). Binds loopback by default — the hub is a machine-local
/// rendezvous; expose it only behind a tunnel/TLS terminator.
final class DapHubServer {
  DapHubServer._(this._hub, this._http, this._pingInterval) {
    _subscription = _http.listen(_handleRequest);
  }

  final DapHub _hub;
  final HttpServer _http;
  final Duration _pingInterval;
  late final StreamSubscription<HttpRequest> _subscription;

  /// The bound port (useful with port 0).
  int get port => _http.port;

  /// The WebSocket endpoint URL clients dial.
  String get url => 'ws://${_http.address.host}:${_http.port}/ws';

  /// Starts a server for [hub]. Await [DapHub.load] first when
  /// persistence is configured (or pass a hub you loaded yourself).
  static Future<DapHubServer> start(
    DapHub hub, {
    String host = '127.0.0.1',
    int port = 8080,
    Duration pingInterval = defaultPingInterval,
  }) async {
    final http = await HttpServer.bind(host, port);
    return DapHubServer._(hub, http, pingInterval);
  }

  /// Stops the server (active client connections are force-closed).
  Future<void> close() async {
    await _subscription.cancel();
    await _http.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/healthz') {
      request.response.write('ok');
      await request.response.close();
      return;
    }
    if (path == '/ws') {
      await _handleWs(request);
      return;
    }
    if (await _handleAdmin(request)) return;
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  /// Upgrades, then hands the connection to the hub. The bearer check
  /// runs BEFORE the upgrade: wrong/absent token → 401, no frames.
  Future<void> _handleWs(HttpRequest request) async {
    final match = _hub.matchBearer(_bearerToken(request));
    if (match == null) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final rawSocket = await _upgrade(request);
    if (rawSocket == null) return; // response already failed
    unawaited(
      _hub
          .serve(
            RawWsConnection(rawSocket, pingInterval: _pingInterval),
            kind: match.kind,
            boundName: match.boundName,
          )
          .catchError((Object _) {}),
    );
  }

  /// Manually performs the RFC 6455 upgrade and returns the RAW socket:
  /// `WebSocketTransformer.upgrade` hides it, and only the raw socket's
  /// `flush()` gives real write backpressure (dart:io's WebSocket.add/
  /// addStream complete once bytes hit the unbounded internal buffer —
  /// the slow-consumer shed needs the kernel-level stall a flush
  /// exposes). Framing is [RawWsConnection]'s job.
  Future<Socket?> _upgrade(HttpRequest request) async {
    final key = request.headers.value('sec-websocket-key');
    final upgrade = request.headers.value('upgrade')?.toLowerCase();
    if (key == null || upgrade != 'websocket') {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return null;
    }
    final accept = base64.encode(
      sha1.convert(utf8.encode(key + _wsGuid)).bytes,
    );
    final response = request.response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.set('Upgrade', 'websocket')
      ..headers.set('Connection', 'Upgrade')
      ..headers.set('Sec-WebSocket-Accept', accept);
    return response.detachSocket();
  }

  /// Routes the admin API; false when the path is not an admin route.
  Future<bool> _handleAdmin(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.isEmpty || segments.first != 'api') return false;
    final bearer = _bearerToken(request);
    final response = switch ((request.method, segments)) {
      ('GET', ['api', 'channels']) => _hub.adminChannelsList(bearer),
      ('PUT', ['api', 'channels', final name, 'acl']) =>
        await _adminSetAcl(bearer, name, request),
      ('GET', ['api', 'agents']) => _hub.adminAgentsList(bearer),
      ('DELETE', ['api', 'agents', final id]) => _hub.adminEvict(bearer, id),
      _ => (status: 404, body: 'not found'),
    };
    request.response.statusCode = response.status;
    if (response.body.isNotEmpty) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(response.body);
    }
    await request.response.close();
    return true;
  }

  Future<DapAdminResponse> _adminSetAcl(
    String bearer,
    String name,
    HttpRequest request,
  ) async {
    final body = await utf8.decoder.bind(request).join();
    return _hub.adminSetAcl(bearer, Uri.decodeComponent(name), body);
  }

  /// The bearer credential of the Authorization header ('' when absent).
  static String _bearerToken(HttpRequest request) {
    final header = request.headers.value('authorization') ?? '';
    return header.startsWith('Bearer ') ? header.substring(7) : '';
  }
}
