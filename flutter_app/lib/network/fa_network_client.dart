// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Error raised by [FaNetworkClient] for any non-success response.
///
/// [code] is the server error code (`unauthorized`, `invalid_credentials`,
/// `forbidden_by_class`, `channel_read_only`, `throttled`, `not_found`,
/// `conflict`). When the body does not match the Error schema, [code] is
/// `http_5xx` for server errors and `http_<status>` otherwise.
class FaNetworkException implements Exception {
  const FaNetworkException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.retryAfterSeconds,
  });

  final int statusCode;
  final String code;
  final String message;

  /// `Retry-After` header (seconds), present on some 403/429 responses.
  final int? retryAfterSeconds;

  @override
  String toString() =>
      'FaNetworkException($statusCode, $code): $message'
      '${retryAfterSeconds != null ? ' (retry after ${retryAfterSeconds}s)' : ''}';
}

/// REST client for the fa_network edge (fa_network/docs/openapi.yaml).
///
/// Pure `package:http` — web-safe, no dart:io. Inject [httpClient] for
/// tests. Auth: management routes send the ai-native [jwtToken], member
/// routes the fa_network [sessionToken] from join (each falls back to the
/// other when only one is set).
class FaNetworkClient {
  FaNetworkClient({
    required this.baseUrl,
    required http.Client httpClient,
    String? jwtToken,
    String? sessionToken,
  }) : _http = httpClient,
       _jwt = jwtToken,
       _session = sessionToken;

  /// REST base, e.g. `https://network.fa1.dev` (trailing slashes tolerated).
  final Uri baseUrl;
  final http.Client _http;

  String? _jwt;
  String? _session;

  /// Sets (or clears) the ai-native JWT used by management routes.
  set jwt(String? token) => _jwt = token;

  /// Sets (or clears) the fa_network session token used by member routes.
  set session(String? token) => _session = token;

  // ---------------------------------------------------------------- health

  /// `GET /healthz` — true when the service reports `{"status":"ok"}`.
  Future<bool> health() async {
    final res = await _request('GET', '/healthz', expected: {200});
    return _decodeMap(res)['status'] == 'ok';
  }

  // --------------------------------------------------------------- networks

  /// `POST /api/networks` — creates a network; the caller becomes owner.
  /// Returns the network plus the one-time join credentials (when present).
  Future<({Network network, JoinCredentials? joinCredentials})> createNetwork({
    required String name,
    required String password,
  }) async {
    final res = await _request(
      'POST',
      '/api/networks',
      body: {'name': name, 'password': password},
      management: true,
      expected: {201},
    );
    final json = _decodeMap(res);
    final credentials = json['joinCredentials'];
    return (
      network: Network.fromJson(json),
      joinCredentials: credentials is Map
          ? JoinCredentials.fromJson(credentials.cast<String, Object?>())
          : null,
    );
  }

  /// `POST /api/networks/{id}/join` — joins a network (auth optional).
  Future<JoinResult> joinNetwork(
    String networkId, {
    required String password,
    String? displayName,
  }) async {
    final res = await _request(
      'POST',
      '/api/networks/$networkId/join',
      body: {'password': password, '''displayName''': ?displayName},
      management: true, // authed join locks the display name to the JWT
      expected: {200},
    );
    return JoinResult.fromJson(_decodeMap(res));
  }

  /// `GET /api/networks/{id}` — network metadata (member).
  Future<Network> getNetwork(String networkId) async {
    final res = await _request(
      'GET',
      '/api/networks/$networkId',
      expected: {200},
    );
    return Network.fromJson(_decodeMap(res));
  }

  /// `PATCH /api/networks/{id}` — rename / rotate password (owner/admin).
  Future<Network> updateNetwork(
    String networkId, {
    String? name,
    String? password,
  }) async {
    final res = await _request(
      'PATCH',
      '/api/networks/$networkId',
      body: {'''name''': ?name, '''password''': ?password},
      management: true,
      expected: {200},
    );
    return Network.fromJson(_decodeMap(res));
  }

  /// `DELETE /api/networks/{id}` (owner only).
  Future<void> deleteNetwork(String networkId) => _request(
    'DELETE',
    '/api/networks/$networkId',
    management: true,
    expected: {204},
  ).then((_) {});

  // ---------------------------------------------------------------- admins

  /// `POST /api/networks/{id}/admins` — appoint an admin (owner only).
  Future<Member> addAdmin(String networkId, {required String userId}) async {
    final res = await _request(
      'POST',
      '/api/networks/$networkId/admins',
      body: {'userId': userId},
      management: true,
      expected: {201},
    );
    return Member.fromJson(_decodeMap(res));
  }

  /// `DELETE /api/networks/{id}/admins/{userId}` (owner only).
  Future<void> removeAdmin(String networkId, String userId) => _request(
    'DELETE',
    '/api/networks/$networkId/admins/$userId',
    management: true,
    expected: {204},
  ).then((_) {});

  // --------------------------------------------------------------- members

  /// `GET /api/networks/{id}/members` — roster with presence (member).
  Future<List<Member>> listMembers(String networkId) async {
    final res = await _request(
      'GET',
      '/api/networks/$networkId/members',
      expected: {200},
    );
    return _decodeList(res, Member.fromJson);
  }

  // -------------------------------------------------------------- channels

  /// `GET /api/networks/{id}/channels` (member).
  Future<List<Channel>> listChannels(String networkId) async {
    final res = await _request(
      'GET',
      '/api/networks/$networkId/channels',
      expected: {200},
    );
    return _decodeList(res, Channel.fromJson);
  }

  /// `POST /api/networks/{id}/channels` (authed only; public channels
  /// require owner/admin).
  Future<Channel> createChannel(
    String networkId, {
    required String name,
    bool isPublic = false,
    int? retentionDays,
  }) async {
    final res = await _request(
      'POST',
      '/api/networks/$networkId/channels',
      body: {
        'name': name,
        'public': isPublic,
        '''retentionDays''': ?retentionDays,
      },
      management: true,
      expected: {201},
    );
    return Channel.fromJson(_decodeMap(res));
  }

  /// `GET /api/channels/{id}` (member).
  Future<Channel> getChannel(String channelId) async {
    final res = await _request(
      'GET',
      '/api/channels/$channelId',
      expected: {200},
    );
    return Channel.fromJson(_decodeMap(res));
  }

  /// `PATCH /api/channels/{id}` (owner/admin).
  ///
  /// Pass [clearRetention] true (with [retentionDays] omitted) to remove the
  /// per-channel retention override.
  Future<Channel> updateChannel(
    String channelId, {
    String? name,
    bool? isPublic,
    List<String>? acl,
    int? retentionDays,
    bool? clearRetention,
  }) async {
    final res = await _request(
      'PATCH',
      '/api/channels/$channelId',
      body: {
        '''name''': ?name,
        'public': ?isPublic,
        '''acl''': ?acl,
        '''retentionDays''': ?retentionDays,
        '''clearRetention''': ?clearRetention,
      },
      management: true,
      expected: {200},
    );
    return Channel.fromJson(_decodeMap(res));
  }

  /// `DELETE /api/channels/{id}` (owner/admin).
  Future<void> deleteChannel(String channelId) => _request(
    'DELETE',
    '/api/channels/$channelId',
    management: true,
    expected: {204},
  ).then((_) {});

  // -------------------------------------------------------------- messages

  /// `GET /api/channels/{id}/messages?cursor&limit` (member).
  Future<MessagePage> listMessages(
    String channelId, {
    String? cursor,
    int? limit,
  }) async {
    final res = await _request(
      'GET',
      '/api/channels/$channelId/messages',
      query: {'''cursor''': ?cursor, 'limit': ?limit?.toString()},
      expected: {200},
    );
    return MessagePage.fromJson(_decodeMap(res));
  }

  /// `POST /api/channels/{id}/messages` — relay-accept an envelope
  /// (member; public channels owner/admin only). Returns the 202 echo.
  Future<Envelope> sendMessage(
    String channelId, {
    required String id,
    required String payload,
    List<String>? mentions,
    String? senderKey,
  }) async {
    final res = await _request(
      'POST',
      '/api/channels/$channelId/messages',
      body: {
        'id': id,
        'payload': payload,
        '''mentions''': ?mentions,
        '''senderKey''': ?senderKey,
      },
      expected: {202},
    );
    return Envelope.fromJson(_decodeMap(res));
  }

  // ---------------------------------------------------------------- agents

  /// `GET /api/networks/{id}/agents` — agent roster with presence (member).
  Future<List<NetworkAgent>> listAgents(String networkId) async {
    final res = await _request(
      'GET',
      '/api/networks/$networkId/agents',
      expected: {200},
    );
    return _decodeList(res, NetworkAgent.fromJson);
  }

  // --------------------------------------------------------------- wakeups

  /// `GET /api/networks/{id}/agents/{agentId}/wakeups` (owner/admin).
  Future<WakeupRegistration> getWakeup(String networkId, String agentId) async {
    final res = await _request(
      'GET',
      '/api/networks/$networkId/agents/$agentId/wakeups',
      management: true,
      expected: {200},
    );
    return WakeupRegistration.fromJson(_decodeMap(res));
  }

  /// `POST /api/networks/{id}/agents/{agentId}/wakeups` (owner/admin).
  Future<WakeupRegistration> registerWakeup(
    String networkId,
    String agentId, {
    required String url,
    String? secret,
    int? debounceSeconds,
  }) async {
    final res = await _request(
      'POST',
      '/api/networks/$networkId/agents/$agentId/wakeups',
      body: {
        'url': url,
        '''secret''': ?secret,
        '''debounceSeconds''': ?debounceSeconds,
      },
      management: true,
      expected: {201},
    );
    return WakeupRegistration.fromJson(_decodeMap(res));
  }

  /// `DELETE /api/networks/{id}/agents/{agentId}/wakeups` (owner/admin).
  Future<void> deleteWakeup(String networkId, String agentId) => _request(
    'DELETE',
    '/api/networks/$networkId/agents/$agentId/wakeups',
    management: true,
    expected: {204},
  ).then((_) {});

  /// `GET /api/networks/{id}/wakeups/log?cursor` (owner/admin).
  Future<({List<WakeupDispatch> items, String? nextCursor})> listWakeupLog(
    String networkId, {
    String? cursor,
  }) async {
    final res = await _request(
      'GET',
      '/api/networks/$networkId/wakeups/log',
      query: {'cursor': ?cursor},
      management: true,
      expected: {200},
    );
    final json = _decodeMap(res);
    final items = json['items'] is List
        ? (json['items']! as List)
              .whereType<Map>()
              .map((e) => WakeupDispatch.fromJson(e.cast<String, Object?>()))
              .toList()
        : <WakeupDispatch>[];
    final nextCursor = json['nextCursor'];
    return (items: items, nextCursor: nextCursor is String ? nextCursor : null);
  }

  // ------------------------------------------------------------------- dev

  /// `POST /api/dev/login` — dev-only mock auth; returns the JWT token.
  Future<String> devLogin({
    required String login,
    required String password,
  }) async {
    final res = await _request(
      'POST',
      '/api/dev/login',
      body: {'login': login, 'password': password},
      auth: false,
      expected: {200},
    );
    final token = _decodeMap(res)['token'];
    if (token is! String) {
      throw const FormatException('devLogin: response has no string "token"');
    }
    return token;
  }

  // -------------------------------------------------------------- internal

  Uri _uri(String path, Map<String, String>? query) {
    final base = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    final rel = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$rel');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  String? _token({required bool management}) =>
      management ? (_jwt ?? _session) : (_session ?? _jwt);

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool management = false,
    bool auth = true,
    required Set<int> expected,
  }) async {
    final uri = _uri(path, query);
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    if (auth) {
      final token = _token(management: management);
      if (token != null) headers['authorization'] = 'Bearer $token';
    }
    final encodedBody = body == null ? null : jsonEncode(body);
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (encodedBody != null) request.body = encodedBody;
    final streamed = await _http.send(request);
    final response = await http.Response.fromStream(streamed);
    if (!expected.contains(response.statusCode)) {
      throw _errorFor(response);
    }
    return response;
  }

  FaNetworkException _errorFor(http.Response response) {
    final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    var code = response.statusCode >= 500
        ? 'http_5xx'
        : 'http_${response.statusCode}';
    var message = response.body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = (decoded['error'] as Map).cast<String, Object?>();
        final c = error['code'];
        final m = error['message'];
        if (c is String) code = c;
        if (m is String) message = m;
      }
    } on FormatException {
      // Body is not JSON — keep the http_* fallback code.
    }
    return FaNetworkException(
      statusCode: response.statusCode,
      code: code,
      message: message,
      retryAfterSeconds: retryAfter,
    );
  }

  Map<String, Object?> _decodeMap(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw FormatException(
        'expected a JSON object, got ${decoded.runtimeType}',
        response.body,
      );
    }
    return decoded.cast<String, Object?>();
  }

  List<T> _decodeList<T>(
    http.Response response,
    T Function(Map<String, Object?>) parse,
  ) {
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw FormatException(
        'expected a JSON array, got ${decoded.runtimeType}',
        response.body,
      );
    }
    return decoded
        .whereType<Map>()
        .map((e) => parse(e.cast<String, Object?>()))
        .toList();
  }
}
