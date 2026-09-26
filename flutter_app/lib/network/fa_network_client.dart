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
    Uri? authBaseUrl,
    String? jwtToken,
    String? sessionToken,
  }) : authBaseUrl = authBaseUrl ?? _defaultAuthBaseUrl,
       _http = httpClient,
       _jwt = jwtToken,
       _session = sessionToken;

  /// The ai-native auth service default host (`/api/auth/*` +
  /// `/api/oauth-proxy/*` live there, NOT on the fa_network relay).
  static final Uri _defaultAuthBaseUrl = Uri.parse('https://ai-native.cloud');

  /// REST base, e.g. `https://network.fa1.dev` (trailing slashes tolerated).
  final Uri baseUrl;

  /// The ai-native auth service base (oauth-proxy + /api/auth/*). Separate
  /// from [baseUrl]: the relay does not proxy auth routes — calling them
  /// on the relay 404s.
  final Uri authBaseUrl;
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

  /// `PATCH /api/networks/{id}` — rename / rotate password / toggle the
  /// public-directory listing (owner/admin).
  Future<Network> updateNetwork(
    String networkId, {
    String? name,
    String? password,
    bool? isPublic,
  }) async {
    final res = await _request(
      'PATCH',
      '/api/networks/$networkId',
      body: {'''name''': ?name, '''password''': ?password, 'public': ?isPublic},
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

  /// `GET /api/networks/public?limit&cursor` — the public-networks
  /// directory (deployed contract, issue #955 iteration 2): ANONYMOUS
  /// (no tokens sent; rate-limited 30/min with 429 + Retry-After),
  /// `limit` defaults to 50 server-side (max 200), `cursor` is opaque
  /// (a malformed cursor silently restarts at the first page). The
  /// response is `{"items": [...], "nextCursor": ""}` — [nextCursor] is
  /// null on the last page. Returns null on any [FaNetworkException]
  /// (404/429/...) so the UI silently hides the section — it never
  /// throws into the widget tree.
  Future<({List<PublicNetworkInfo> items, String? nextCursor})?>
  listPublicNetworks({int? limit, String? cursor}) async {
    try {
      final res = await _request(
        'GET',
        '/api/networks/public',
        query: {'''limit''': ?limit?.toString(), '''cursor''': ?cursor},
        auth: false,
        expected: {200},
      );
      final json = _decodeMap(res);
      final items = json['items'] is List
          ? (json['items']! as List)
                .whereType<Map>()
                .map(
                  (e) => PublicNetworkInfo.fromJson(e.cast<String, Object?>()),
                )
                .toList()
          : <PublicNetworkInfo>[];
      final next = json['nextCursor'];
      return (
        items: items,
        nextCursor: next is String && next.isNotEmpty ? next : null,
      );
    } on FaNetworkException {
      return null;
    }
  }

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

  // ------------------------------------------------------------------ auth

  /// `GET /api/oauth-proxy/providers` — the OAuth providers this deploy
  /// has configured (issue #955 iteration 3). Anonymous. Tolerant parse:
  /// accepts a bare JSON list, `{providers: [...]}`, or
  /// `{enabledProviders: [...]}` (the `/api/auth/config` shape).
  Future<List<String>> oauthProviders() async {
    final res = await _request(
      'GET',
      '/api/oauth-proxy/providers',
      auth: false,
      authService: true,
      expected: {200},
    );
    final decoded = jsonDecode(res.body);
    List<String> names(Object? value) =>
        value is List ? value.whereType<String>().toList() : const [];
    if (decoded is List) return names(decoded);
    if (decoded is Map) {
      return names(decoded['providers'] ?? decoded['enabledProviders']);
    }
    throw FormatException(
      'oauthProviders: unexpected JSON (${decoded.runtimeType})',
      res.body,
    );
  }

  /// `POST /api/oauth-proxy/initiate` — starts the OAuth flow for
  /// [provider]; the returned [authUrl] is opened in the system browser,
  /// which redirects back to [redirectUri] with `?code&state`
  /// (desktop loopback per RFC 8252: `http://127.0.0.1:<port>/callback`
  /// is always allowlisted). Anonymous.
  Future<({Uri authUrl, String state, int expiresIn})> oauthInitiate({
    required String provider,
    required Uri redirectUri,
    String clientType = 'desktop',
    String environment = 'prod',
  }) async {
    final res = await _request(
      'POST',
      '/api/oauth-proxy/initiate',
      body: {
        'provider': provider,
        'client_redirect_uri': redirectUri.toString(),
        'client_type': clientType,
        'environment': environment,
      },
      auth: false,
      authService: true,
      expected: {200},
    );
    final json = _decodeMap(res);
    final authUrl = json['auth_url'];
    final state = json['state'];
    if (authUrl is! String || state is! String) {
      throw FormatException(
        'oauthInitiate: "auth_url"/"state" are required strings',
        res.body,
      );
    }
    final expiresIn = json['expires_in'];
    return (
      authUrl: Uri.parse(authUrl),
      state: state,
      expiresIn: expiresIn is num ? expiresIn.toInt() : 0,
    );
  }

  /// `POST /api/oauth-proxy/exchange` — swaps the temporary callback
  /// [code] (+ the initiate [state]) for the real token set. Anonymous.
  Future<TokenBundle> oauthExchange({
    required String code,
    required String state,
    DateTime? now,
  }) async {
    final res = await _request(
      'POST',
      '/api/oauth-proxy/exchange',
      body: {'code': code, 'state': state},
      auth: false,
      authService: true,
      expected: {200},
    );
    return TokenBundle.fromJson(_decodeMap(res), now: now);
  }

  /// `POST /api/auth/refresh` — trades [refreshToken] for a fresh token
  /// set. Anonymous (the refresh token IS the credential).
  Future<TokenBundle> refreshTokens(
    String refreshToken, {
    DateTime? now,
  }) async {
    final res = await _request(
      'POST',
      '/api/auth/refresh',
      body: {'refreshToken': refreshToken},
      auth: false,
      authService: true,
      expected: {200},
    );
    return TokenBundle.fromJson(_decodeMap(res), now: now);
  }

  /// `GET /api/auth/user` with an explicit Bearer [accessToken] (the
  /// freshly exchanged token — the client's stored tokens are NOT sent).
  Future<AuthProfile> authUser(String accessToken) async {
    final res = await _request(
      'GET',
      '/api/auth/user',
      auth: false,
      authService: true,
      headers: {'authorization': 'Bearer $accessToken'},
      expected: {200},
    );
    return AuthProfile.fromJson(_decodeMap(res));
  }

  // -------------------------------------------------------------- internal

  Uri _uri(String path, Map<String, String>? query, {Uri? base}) {
    final baseStr = (base ?? baseUrl).toString().replaceAll(RegExp(r'/+$'), '');
    final rel = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$baseStr$rel');
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
    Map<String, String>? headers,

    /// Route to the ai-native auth service ([authBaseUrl]) instead of the
    /// fa_network relay — `/api/auth/*` and `/api/oauth-proxy/*` live there.
    bool authService = false,
    required Set<int> expected,
  }) async {
    final uri = _uri(path, query, base: authService ? authBaseUrl : null);
    final requestHeaders = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
      ...?headers,
    };
    if (auth) {
      final token = _token(management: management);
      if (token != null) requestHeaders['authorization'] = 'Bearer $token';
    }
    final encodedBody = body == null ? null : jsonEncode(body);
    final request = http.Request(method, uri)..headers.addAll(requestHeaders);
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
