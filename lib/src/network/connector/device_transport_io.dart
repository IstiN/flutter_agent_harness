// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The `dart:io` device transport + enrollment of the machine connector
/// (contract `docs/fa_network_connector.md` §4/§9): the real upstream WS
/// dial ([IoConnectorTransport] over `dart:io`'s `WebSocket.connect`) and
/// the two device REST calls ([DeviceEnrollmentClient]):
/// - `POST /api/devices/enroll` (JWT bearer) → `{deviceId, deviceToken}` —
///   the stable §1 identity pair persisted by the host;
/// - `POST /api/ws-ticket` (deviceToken bearer) → a single-use ticket,
///   TTL 60 s, one dial each (§4).
///
/// The socket adapter ([ConnectorSocketAdapter]) mirrors the fake-device-
/// server client-socket semantics: writes after close throw, close is
/// idempotent, and the frames stream completes when the peer goes away —
/// the upstream client treats any of that as "link gone" and reconnects.
/// Malformed inbound text (one corrupt frame) is skipped with a
/// diagnostic instead of tearing the link down; JSON frames resync
/// trivially per WS text message.
///
/// NOT web-compilable: exported from `lib/io.dart` only, never the pure
/// core barrel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'envelope.dart';
import 'upstream_client.dart';

/// A plain text duplex between a socket and the adapter — the seam that
/// keeps [ConnectorSocketAdapter] unit-testable without dart:io sockets:
/// tests drive it with in-memory pipes, production binds a [WebSocket].
abstract interface class ConnectorTextDuplex {
  /// Inbound text frames (one JSON envelope per WS text message).
  Stream<String> get inbound;

  /// Writes one outbound text frame. Throws when the socket is gone.
  Future<void> write(String text);

  /// Closes the underlying socket; idempotent.
  Future<void> shutdown();
}

/// The dart:io WebSocket duplex.
final class WebSocketDuplex implements ConnectorTextDuplex {
  /// Wraps [socket].
  WebSocketDuplex(this.socket);

  /// The live `dart:io` WebSocket.
  final WebSocket socket;

  @override
  Stream<String> get inbound => socket.cast<String>();

  @override
  Future<void> write(String text) async => socket.add(text);

  @override
  Future<void> shutdown() => socket.close();
}

/// The [ConnectorSocket] adapter over a [ConnectorTextDuplex]: decodes
/// inbound JSON text into [NetworkEnvelope]s, encodes outbound envelopes
/// into JSON text, and owns the closed/open state machine the upstream
/// client relies on (`isOpen`, throw-on-send-after-close, idempotent
/// close, frames stream completing on either side going away).
final class ConnectorSocketAdapter implements ConnectorSocket {
  /// Binds the adapter to [duplex]. [onLog] is the soft diagnostics sink
  /// (null = drop); it carries skipped-frame reports, never tokens.
  ConnectorSocketAdapter({required ConnectorTextDuplex duplex, this.onLog})
    : _duplex = duplex {
    _subscription = duplex.inbound.listen(
      _onText,
      onDone: () => _peerGone('closed by peer'),
      onError: (Object error) => _peerGone('$error'),
    );
  }

  final ConnectorTextDuplex _duplex;

  /// Soft diagnostics sink (null = drop).
  void Function(String message)? onLog;

  final _frames = StreamController<NetworkEnvelope>.broadcast();
  StreamSubscription<String>? _subscription;
  var _shutdown = false;
  var _closed = false;

  @override
  Stream<NetworkEnvelope> get frames => _frames.stream;

  /// True until [close] or the peer's side ended the socket.
  @override
  bool get isOpen => !_closed;

  @override
  Future<void> send(NetworkEnvelope envelope) async {
    if (_closed) throw StateError('socket closed');
    await _duplex.write(jsonEncode(envelope.toJson()));
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (_shutdown) return;
    _shutdown = true;
    await _subscription?.cancel();
    _subscription = null;
    await _duplex.shutdown();
    await _closeFrames();
  }

  /// The peer side ended the socket (clean close or inbound error): the
  /// socket is gone for the upstream client even before [close] runs.
  void _peerGone(String reason) {
    onLog?.call('device socket gone: $reason');
    _closed = true;
    if (!_shutdown) {
      _shutdown = true;
      unawaited(_subscription?.cancel());
      _subscription = null;
      unawaited(_duplex.shutdown());
    }
    unawaited(_closeFrames());
  }

  Future<void> _closeFrames() async {
    if (_frames.isClosed) return;
    await _frames.close();
  }

  /// Decodes one inbound text frame; malformed JSON or an invalid
  /// envelope is skipped with a diagnostic — the link stays up.
  void _onText(String text) {
    if (_closed) return;
    try {
      _frames.add(NetworkEnvelope.fromJson(jsonDecode(text)));
    } on FormatException catch (error) {
      onLog?.call('skipping malformed device frame: $error');
    }
  }
}

/// Dials the device WS with `dart:io`: the ticket rides the URL query
/// (`?ticket=<...>`, already folded in by the upstream client — the
/// parameter is accepted for the seam's shape and asserted nowhere).
/// Throws when the endpoint refuses the upgrade or is unreachable; the
/// upstream client retries with backoff.
final class IoConnectorTransport implements ConnectorTransport {
  /// Builds the transport (stateless).
  const IoConnectorTransport();

  @override
  Future<ConnectorSocket> dial(Uri url, String ticket) async {
    final socket = await WebSocket.connect(url.toString());
    return ConnectorSocketAdapter(duplex: WebSocketDuplex(socket));
  }
}

/// Thrown by [DeviceEnrollmentClient] for any failure: a non-success
/// HTTP status ([statusCode] set) or a network-level error (null).
final class DeviceEnrollmentException implements Exception {
  /// Builds the exception; [statusCode] is null for network errors.
  const DeviceEnrollmentException(this.message, {this.statusCode});

  /// HTTP status when the server answered, else null (network error).
  final int? statusCode;

  /// Human-readable failure reason.
  final String message;

  @override
  String toString() => statusCode == null
      ? 'DeviceEnrollmentException: $message'
      : 'DeviceEnrollmentException($statusCode): $message';
}

/// The enrollment result (§1): the stable device identity pair the host
/// persists and resumes with (§4). `deviceToken` is a bearer — never
/// logged.
final class DeviceEnrollment {
  /// Wraps the server-issued pair.
  const DeviceEnrollment({required this.deviceId, required this.deviceToken});

  /// Stable device id minted at enroll (§1).
  final String deviceId;

  /// Opaque bearer bound to (userId, deviceId); WS + device-REST auth.
  final String deviceToken;

  @override
  String toString() =>
      'DeviceEnrollment($deviceId, deviceToken:<${deviceToken.length} chars>)';
}

/// The device enrollment + ticket client (§9): the two REST calls a host
/// needs before (and between) WS dials. [httpClient] is injectable —
/// tests use `package:http/testing`.
final class DeviceEnrollmentClient {
  /// Builds a client; with no [httpClient] injected a fresh `http.Client`
  /// is used.
  DeviceEnrollmentClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// `POST /api/devices/enroll` (JWT bearer) → the {deviceId, deviceToken}
  /// pair (§9). The server auto-provisions the personal network on first
  /// enroll (§2) — irrelevant to this call's shape. Any 4xx/5xx status or
  /// network failure throws [DeviceEnrollmentException].
  Future<DeviceEnrollment> enrollDevice({
    required String baseUrl,
    required String jwt,
  }) async {
    final body = await _post(
      _endpoint(baseUrl, '/api/devices/enroll'),
      bearer: jwt,
    );
    final deviceId = body['deviceId'];
    final deviceToken = body['deviceToken'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceToken is! String ||
        deviceToken.isEmpty) {
      throw const DeviceEnrollmentException(
        'device enrollment response lacks deviceId/deviceToken',
      );
    }
    return DeviceEnrollment(deviceId: deviceId, deviceToken: deviceToken);
  }

  /// `POST /api/ws-ticket` (deviceToken bearer) → the single-use ticket
  /// string, TTL 60 s (§4) — feed it to [IoConnectorTransport.dial]
  /// immediately (the upstream client mints one per dial). Accepts both
  /// the JSON-object form (`{"ticket": ...}`) and a bare JSON string.
  /// Any non-success status or network failure throws
  /// [DeviceEnrollmentException].
  Future<String> wsTicket({
    required String baseUrl,
    required String deviceToken,
  }) async {
    final body = await _post(
      _endpoint(baseUrl, '/api/ws-ticket'),
      bearer: deviceToken,
    );
    final ticket = body['ticket'];
    if (ticket is String && ticket.isNotEmpty) return ticket;
    throw const DeviceEnrollmentException(
      'ws-ticket response lacks a ticket string',
    );
  }

  /// One bearer-authenticated POST; returns the decoded JSON object body.
  /// Maps non-success statuses and network errors to
  /// [DeviceEnrollmentException].
  Future<Map<String, Object?>> _post(Uri uri, {required String bearer}) async {
    http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $bearer',
        },
        body: jsonEncode(const <String, Object?>{}),
      );
    } on Object catch (error) {
      throw DeviceEnrollmentException('device REST call failed: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeviceEnrollmentException(
        'device REST call rejected: ${_snippet(response.body)}',
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
      if (decoded is String) return {'ticket': decoded};
      throw FormatException('unexpected JSON ${decoded.runtimeType}');
    } on FormatException catch (error) {
      throw DeviceEnrollmentException('malformed device REST body: $error');
    }
  }

  /// Joins [baseUrl] and [path] (tolerant of trailing slashes, like the
  /// fa_network client's `_uri`).
  Uri _endpoint(String baseUrl, String path) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// A one-line body snippet for error messages (never tokens — enroll
  /// and ticket responses carry secrets only on success paths).
  String _snippet(String body) {
    final flat = body.replaceAll('\n', ' ').trim();
    return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
  }
}
