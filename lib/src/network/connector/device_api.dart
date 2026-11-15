// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pure HTTP enrollment and WebSocket-ticket client for the machine
/// connector. Native socket code lives in `device_transport_io.dart`; this
/// file is web-safe and uses an injectable `package:http` client.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../secret_redaction.dart';

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

/// The enrollment result: the stable device identity pair and personal
/// network the host persists. `deviceToken` is a bearer — never log it.
final class DeviceEnrollment {
  /// Wraps the server-issued identity.
  const DeviceEnrollment({
    required this.deviceId,
    required this.deviceToken,
    this.personalNetworkId,
  });

  /// Stable device id minted at enroll.
  final String deviceId;

  /// Opaque bearer bound to (userId, deviceId); WS + device-REST auth.
  final String deviceToken;

  /// The personal network provisioned by the server, when returned.
  final String? personalNetworkId;

  @override
  String toString() =>
      'DeviceEnrollment($deviceId, deviceToken:<${deviceToken.length} chars>)';
}

/// One own-machine row from `GET /api/devices`.
final class DeviceSummary {
  /// Builds a device summary.
  const DeviceSummary({
    required this.deviceId,
    required this.name,
    this.friendlyName,
    this.createdAt,
    this.revokedAt,
  });

  /// Stable device id.
  final String deviceId;

  /// Enrollment host name.
  final String name;

  /// Owner-set friendly name, when present.
  final String? friendlyName;

  /// Creation timestamp, when supplied.
  final DateTime? createdAt;

  /// Revocation timestamp, when the device is revoked.
  final DateTime? revokedAt;

  /// Best display label.
  String get displayName => friendlyName ?? name;

  /// Parses one wire row.
  factory DeviceSummary.fromJson(Map<String, Object?> json) {
    final id = json['deviceId'];
    if (id is! String || id.isEmpty) {
      throw const DeviceEnrollmentException('device row lacks deviceId');
    }
    return DeviceSummary(
      deviceId: id,
      name: _nonEmptyString(json['name']) ?? id,
      friendlyName: _nonEmptyString(json['friendlyName']),
      createdAt: _dateTime(json['createdAt']),
      revokedAt: _dateTime(json['revokedAt']),
    );
  }
}

/// One agent entry in a device roster merge patch.
final class DeviceRosterAgent {
  /// Builds an agent projection entry.
  const DeviceRosterAgent({
    required this.name,
    required this.state,
    required this.exposed,
    this.dmPub,
  });

  /// Bare agent name; the server scopes it to the patched device.
  final String name;

  /// Roster presence: `live`, `busy`, or `offline`.
  final String state;

  /// Whether other devices may discover this agent.
  final bool exposed;

  /// Base64 X25519 DM public key for this agent's full address (§7).
  final String? dmPub;

  /// JSON representation for the roster endpoint.
  Map<String, Object?> toJson() => {
    'name': name,
    'state': state,
    'exposed': exposed,
    if (dmPub != null) 'dmPub': dmPub,
  };
}

/// One session entry in a device roster merge patch.
final class DeviceRosterSession {
  /// Builds a session projection entry.
  const DeviceRosterSession({
    required this.id,
    required this.state,
    this.networks = const [],
    this.title,
    this.path,
    this.lastActivity,
  });

  /// Stable CLI session id.
  final String id;

  /// Session presence: `live`, `wake-on-DM`, or `offline`.
  final String state;

  /// Networks on which this session is exposed.
  final List<String> networks;

  /// Optional human-readable title; omitted by legacy peers.
  final String? title;

  /// Optional project/working-directory path for the session row subtitle.
  final String? path;

  /// Optional RFC3339 last-activity timestamp.
  final String? lastActivity;

  /// JSON representation for the roster endpoint.
  Map<String, Object?> toJson() => {
    'id': id,
    'state': state,
    'networks': networks,
    if (title != null) 'title': title,
    if (path != null) 'path': path,
    if (lastActivity != null) 'lastActivity': lastActivity,
  };
}

DeviceEnrollment _enrollmentFromJson(Map<String, Object?> body) {
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
  final personal = body['personalNetwork'];
  final nestedId = personal is Map ? personal['id'] : null;
  final flatId = body['personalNetworkId'];
  final personalNetworkId = switch ((nestedId, flatId)) {
    (final String id, _) when id.isNotEmpty => id,
    (_, final String id) when id.isNotEmpty => id,
    _ => null,
  };
  return DeviceEnrollment(
    deviceId: deviceId,
    deviceToken: deviceToken,
    personalNetworkId: personalNetworkId,
  );
}

/// The device enrollment + ticket client. [httpClient] is injectable —
/// tests use `package:http/testing` and never dial a real service.
final class DeviceEnrollmentClient {
  /// Builds a client; with no [httpClient] injected a fresh `http.Client`
  /// is used.
  DeviceEnrollmentClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// `POST /api/devices/enroll` (JWT bearer) → the stable device identity.
  /// [name] and [platform] describe the host in the Devices roster. Both
  /// are optional for compatibility with older callers; the CLI supplies
  /// them. Accepts both the server's `personalNetwork: {id: …}` shape and
  /// the additive flat `personalNetworkId` form.
  Future<DeviceEnrollment> enrollDevice({
    required String baseUrl,
    required String jwt,
    String? name,
    String? platform,
  }) async {
    final body = await _post(
      _endpoint(baseUrl, '/api/devices/enroll'),
      bearer: jwt,
      body: {
        if (name != null && name.isNotEmpty) 'name': name,
        if (platform != null && platform.isNotEmpty) 'platform': platform,
      },
    );
    return _enrollmentFromJson(body);
  }

  /// `POST /api/ws-ticket` (deviceToken bearer) → a single-use ticket.
  /// Feed it to the device transport immediately (TTL 60 s). Accepts both
  /// the JSON-object form (`{"ticket": ...}`) and a bare JSON string.
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

  /// `GET /api/devices` (account JWT bearer) → this account's machines,
  /// including their enrollment/friendly names and revocation state.
  Future<List<DeviceSummary>> listDevices({
    required String baseUrl,
    required String jwt,
  }) async {
    final body = await _request(
      'GET',
      _endpoint(baseUrl, '/api/devices'),
      bearer: jwt,
    );
    final devices = body['devices'];
    if (devices is! List) {
      throw const DeviceEnrollmentException(
        'device list response lacks a devices list',
      );
    }
    return List.unmodifiable([
      for (final device in devices)
        if (device is Map)
          DeviceSummary.fromJson(device.cast<String, Object?>()),
    ]);
  }

  /// `PATCH /api/devices/{deviceId}/name` (account JWT bearer). Empty
  /// [name] clears the friendly name; the server limits it to 64 runes.
  Future<String> renameDevice({
    required String baseUrl,
    required String jwt,
    required String deviceId,
    required String name,
  }) async {
    if (name.runes.length > 64) {
      throw const DeviceEnrollmentException(
        'device friendly name must be at most 64 characters',
      );
    }
    final body = await _request(
      'PATCH',
      _endpoint(baseUrl, '/api/devices/${Uri.encodeComponent(deviceId)}/name'),
      bearer: jwt,
      body: {'name': name},
    );
    final responseId = body['deviceId'];
    if (responseId is! String || responseId.isEmpty) {
      throw const DeviceEnrollmentException(
        'device rename response lacks deviceId',
      );
    }
    final friendly = body['friendlyName'];
    return friendly is String ? friendly : name;
  }

  /// `PATCH /api/devices/{deviceId}/roster` (deviceToken bearer). Entries
  /// are merged by agent name/session id; omitted roster rows are unchanged.
  Future<void> patchRoster({
    required String baseUrl,
    required String deviceId,
    required String deviceToken,
    List<DeviceRosterAgent> agents = const [],
    List<DeviceRosterSession> sessions = const [],
  }) async {
    await _request(
      'PATCH',
      _endpoint(
        baseUrl,
        '/api/devices/${Uri.encodeComponent(deviceId)}/roster',
      ),
      bearer: deviceToken,
      body: {
        'agents': [for (final agent in agents) agent.toJson()],
        'sessions': [for (final session in sessions) session.toJson()],
      },
    );
  }

  /// One bearer-authenticated POST; returns the decoded JSON object body.
  Future<Map<String, Object?>> _post(
    Uri uri, {
    required String bearer,
    Map<String, Object?> body = const {},
  }) => _request('POST', uri, bearer: bearer, body: body);

  Future<Map<String, Object?>> _request(
    String method,
    Uri uri, {
    required String bearer,
    Map<String, Object?>? body,
  }) async {
    http.Response response;
    try {
      final request = http.Request(method, uri)
        ..headers['authorization'] = 'Bearer $bearer';
      if (body != null) {
        request
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode(body);
      }
      response = await _http.send(request).then(http.Response.fromStream);
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

  Uri _endpoint(String baseUrl, String path) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// Error snippets are bounded; successful token-bearing responses never
  /// pass through this helper.
  String _snippet(String body) {
    final flat = redactNetworkSecretText(body.replaceAll('\n', ' ').trim());
    return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
  }
}

String? _nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

DateTime? _dateTime(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}
