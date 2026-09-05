// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// AIIN (aiin.by) sign-in and API-key registration client.
///
/// AIIN is an OpenAI-compatible LLM gateway (api.aiin.by) with its own auth
/// service (auth.aiin.by). Third-party clients use the **OAuth proxy flow**,
/// which needs no client registration or secret:
///
/// 1. `initiateAiinOAuth` — server issues a `state` bound to the client's
///    `redirect_uri` and returns the identity-provider sign-in URL;
/// 2. the user completes sign-in in the browser and the auth service
///    redirects to `<redirect_uri>?code=<temp>&state=<state>`;
/// 3. `exchangeAiinOAuthCode` — the temporary code becomes AIIN access and
///    refresh JWTs;
/// 4. `createAiinApiKey` — the access JWT registers a durable
///    `sk-aiin-…` API key (billed to the user) for chat traffic.
///
/// Pure Dart (no `dart:io`); the localhost callback server for desktop/CLI
/// flows lives in `lib/src/cli/aiin_connect_server.dart` (exported from
/// `lib/io.dart`).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// The production AIIN auth service (sign-in, OAuth proxy flow).
const aiinAuthBaseUrl = 'https://auth.aiin.by';

/// The production AIIN OpenAI-compatible API root (`/v1` appended).
const aiinApiBaseUrl = 'https://api.aiin.by';

/// The default identity provider offered when the live provider list cannot
/// be fetched (offline, standalone mode).
const aiinDefaultOAuthProvider = 'google';

/// True when [baseUrl] points at an AIIN endpoint (`api.aiin.by` or
/// `auth.aiin.by`, host-exact — path/query text does not count).
bool isAiinBaseUrl(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase();
  return host == 'api.aiin.by' || host == 'auth.aiin.by';
}

/// The `email` claim of an AIIN JWT payload, or null when the token carries
/// none or is not a JWT. Used to name provider entries after the account.
String? aiinJwtEmail(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  final Object? claims;
  try {
    claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  if (claims is! Map) return null;
  final email = claims['email'];
  return email is String && email.isNotEmpty ? email : null;
}

/// A setup-flow failure talking to the AIIN auth or API service.
///
/// Setup-time only: chat traffic through the resulting `sk-aiin-…` key rides
/// the openai-completions adapter and keeps the errors-as-events invariant.
final class AiinAuthException implements Exception {
  /// Creates the exception for a failed AIIN setup call.
  const AiinAuthException(
    this.message, {
    this.code = 'unknown',
    this.statusCode,
  });

  /// Machine-readable `error` field from the service (best effort).
  final String code;

  /// Human-readable description (the service `message` when present).
  final String message;

  /// HTTP status of the failed call, when the failure was a response.
  final int? statusCode;

  @override
  String toString() =>
      'AiinAuthException($code${statusCode == null ? '' : ', HTTP $statusCode'}): '
      '$message';
}

/// The identity providers AIIN currently accepts for sign-in.
Future<List<String>> fetchAiinOAuthProviders({
  http.Client? client,
  String authBaseUrl = aiinAuthBaseUrl,
}) async {
  final response = await _postOrGet(
    method: 'GET',
    url: Uri.parse('$authBaseUrl/api/oauth-proxy/providers'),
    client: client,
  );
  final body = _decode(response);
  final providers = body['providers'];
  if (providers is! List) return const [];
  return [for (final p in providers) if (p is String && p.isNotEmpty) p];
}

/// The result of [initiateAiinOAuth]: the URL to open in the browser plus
/// the server-issued `state` that binds the redirect back to us.
final class AiinOAuthInitiate {
  /// Creates the initiate result.
  const AiinOAuthInitiate({
    required this.authUrl,
    required this.state,
    required this.expiresIn,
  });

  /// The identity-provider sign-in URL to open in a browser.
  final String authUrl;

  /// Opaque server state; echoed back on the redirect and required by
  /// [exchangeAiinOAuthCode].
  final String state;

  /// Seconds until [state] expires (best-effort hint for the caller UI).
  final int expiresIn;
}

/// Starts the AIIN OAuth proxy flow: returns the sign-in [AiinOAuthInitiate.authUrl]
/// for the browser and the [AiinOAuthInitiate.state] to exchange later.
Future<AiinOAuthInitiate> initiateAiinOAuth({
  required String provider,
  required String redirectUri,
  String clientType = 'desktop',
  String environment = 'prod',
  http.Client? client,
  String authBaseUrl = aiinAuthBaseUrl,
}) async {
  final response = await _postOrGet(
    method: 'POST',
    url: Uri.parse('$authBaseUrl/api/oauth-proxy/initiate'),
    body: jsonEncode({
      'provider': provider,
      'client_redirect_uri': redirectUri,
      'client_type': clientType,
      'environment': environment,
    }),
    client: client,
  );
  final parsed = _decode(response);
  final authUrl = parsed['auth_url'];
  final state = parsed['state'];
  if (authUrl is! String || authUrl.isEmpty || state is! String || state.isEmpty) {
    throw AiinAuthException(
      'AIIN sign-in initiation returned no auth URL/state',
      code: 'invalid_response',
      statusCode: response.statusCode,
    );
  }
  final expiresIn = parsed['expires_in'];
  return AiinOAuthInitiate(
    authUrl: authUrl,
    state: state,
    expiresIn: expiresIn is int ? expiresIn : 900,
  );
}

/// AIIN access + refresh JWTs from [exchangeAiinOAuthCode].
final class AiinOAuthTokens {
  /// Creates the token pair.
  const AiinOAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    required this.refreshExpiresIn,
  });

  /// Bearer JWT for AIIN API calls (key registration, balance).
  final String accessToken;

  /// Long-lived refresh JWT (kept for future silent re-auth; the registered
  /// API key is the durable credential and does not need it).
  final String refreshToken;

  /// Always `Bearer` today.
  final String tokenType;

  /// Access-token TTL in seconds.
  final int expiresIn;

  /// Refresh-token TTL in seconds.
  final int refreshExpiresIn;
}

/// Exchanges the redirect's temporary `code` + `state` for AIIN JWTs.
Future<AiinOAuthTokens> exchangeAiinOAuthCode({
  required String code,
  required String state,
  http.Client? client,
  String authBaseUrl = aiinAuthBaseUrl,
}) async {
  final response = await _postOrGet(
    method: 'POST',
    url: Uri.parse('$authBaseUrl/api/oauth-proxy/exchange'),
    body: jsonEncode({'code': code, 'state': state}),
    client: client,
  );
  final parsed = _decode(response);
  final access = parsed['access_token'];
  if (access is! String || access.isEmpty) {
    throw AiinAuthException(
      'AIIN token exchange returned no access token',
      code: 'invalid_response',
      statusCode: response.statusCode,
    );
  }
  return AiinOAuthTokens(
    accessToken: access,
    refreshToken: switch (parsed['refresh_token']) {
      String value when value.isNotEmpty => value,
      _ => '',
    },
    tokenType: switch (parsed['token_type']) {
      String value when value.isNotEmpty => value,
      _ => 'Bearer',
    },
    expiresIn: switch (parsed['expires_in']) {
      int value => value,
      _ => 0,
    },
    refreshExpiresIn: switch (parsed['refresh_expires_in']) {
      int value => value,
      _ => 0,
    },
  );
}

/// A registered AIIN API key. The raw secret ([raw]) is shown exactly once —
/// store it before leaving the flow.
final class AiinApiKey {
  /// Creates the key record.
  const AiinApiKey({
    required this.raw,
    required this.id,
    required this.prefix,
    required this.createdAt,
  });

  /// The full `sk-aiin-…` secret (chat credential).
  final String raw;

  /// Server-side key id (for later deletion in the AIIN cabinet).
  final String id;

  /// Non-secret prefix the AIIN cabinet displays.
  final String prefix;

  /// ISO-8601 creation timestamp as returned by the service.
  final String createdAt;
}

/// Registers a new AIIN API key for the authenticated user.
///
/// Requires the user's `llm` product; a 403 arrives as
/// [AiinAuthException] with code `llm_access_denied` — surface the message
/// (top up / ask the admin to grant LLM access).
Future<AiinApiKey> createAiinApiKey({
  required String accessToken,
  http.Client? client,
  String apiBaseUrl = aiinApiBaseUrl,
}) async {
  final response = await _postOrGet(
    method: 'POST',
    url: Uri.parse('$apiBaseUrl/v1/keys'),
    headers: {'Authorization': 'Bearer $accessToken'},
    client: client,
  );
  final parsed = _decode(response);
  final key = parsed['key'];
  if (key is! String || key.isEmpty) {
    throw AiinAuthException(
      'AIIN key registration returned no key',
      code: 'invalid_response',
      statusCode: response.statusCode,
    );
  }
  return AiinApiKey(
    raw: key,
    id: switch (parsed['id']) {
      String value => value,
      _ => '',
    },
    prefix: switch (parsed['prefix']) {
      String value => value,
      _ => '',
    },
    createdAt: switch (parsed['created_at']) {
      String value => value,
      _ => '',
    },
  );
}

/// Decodes a JSON-object response or throws [AiinAuthException] with the
/// service's `error`/`message` fields (non-JSON bodies keep the status).
Map<String, Object?> _decode(http.Response response) {
  Map<Object?, Object?>? parsed;
  try {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) parsed = decoded;
  } on FormatException {
    parsed = null;
  }
  if (parsed == null) {
    if (response.statusCode >= 400) {
      throw AiinAuthException(
        'AIIN request failed (HTTP ${response.statusCode})',
        code: 'http_error',
        statusCode: response.statusCode,
      );
    }
    throw AiinAuthException(
      'AIIN returned a non-JSON response',
      code: 'invalid_response',
      statusCode: response.statusCode,
    );
  }
  if (response.statusCode >= 400) {
    throw AiinAuthException(
      switch (parsed['message']) {
        String value when value.isNotEmpty => value,
        _ => 'AIIN request failed (HTTP ${response.statusCode})',
      },
      code: switch (parsed['error']) {
        String value when value.isNotEmpty => value,
        _ => 'http_error',
      },
      statusCode: response.statusCode,
    );
  }
  return Map<String, Object?>.from(parsed);
}

Future<http.Response> _postOrGet({
  required String method,
  required Uri url,
  String? body,
  Map<String, String> headers = const {},
  http.Client? client,
}) async {
  final request = http.Request(method, url)
    ..headers['Accept'] = 'application/json';
  if (body != null) {
    request.headers['Content-Type'] = 'application/json';
    request.body = body;
  }
  request.headers.addAll(headers);
  try {
    final response = await (client ?? http.Client()).send(request);
    // Await the stream so socket errors land in the catch below.
    return await http.Response.fromStream(response);
  } on Object catch (error) {
    throw AiinAuthException(
      'AIIN request to ${url.host} failed: $error',
      code: 'network_error',
    );
  }
}
