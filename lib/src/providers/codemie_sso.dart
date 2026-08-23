/// CodeMie authentication helpers: browser-based SSO (`/v1/auth/login/<port>`
/// redirects to a localhost callback with a base64 token carrying session
/// cookies) and JWT Bearer authorization. The CodeMie API accepts auth either
/// via the FULL cookie string (sent as a `Cookie:` header) from SSO, or via
/// an `Authorization: Bearer <jwt>` header for headless/CI use. The chat
/// traffic rides the standard openai-completions adapter: SSO uses a `cookie:`
/// model header that suppresses the default `authorization` header, while JWT
/// uses the adapter's regular Bearer auth path.
///
/// Pure Dart (no `dart:io`); the localhost callback server lives in
/// `lib/src/cli/codemie_sso_server.dart` (exported from `lib/io.dart`).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions.dart';

/// The hosted CodeMie default (an on-prem org URL can always be typed).
const defaultCodeMieBaseUrl = 'https://codemie.lab.epam.com';

/// Normalizes an organization URL to the API base:
/// `https://host` → `https://host/code-assistant-api` (idempotent).
String codeMieApiBase(String rawUrl) {
  var base = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (!RegExp(
    r'/code-assistant-api(/|$)',
    caseSensitive: false,
  ).hasMatch(base)) {
    base = '$base/code-assistant-api';
  }
  return base;
}

/// The SSO login URL embedding the local callback [port] — the organization
/// redirects to `http://localhost:<port>/?token=...` after the browser login.
String buildCodeMieSsoUrl(String codeMieUrl, int port) =>
    '${codeMieApiBase(codeMieUrl)}/v1/auth/login/$port';

/// True when [baseUrl] points at a CodeMie API endpoint
/// (`<org>/code-assistant-api[/v1]`).
bool isCodeMieBaseUrl(String baseUrl) =>
    RegExp(r'/code-assistant-api(/|$)', caseSensitive: false).hasMatch(baseUrl);

/// The inverse of the stored provider base URL:
/// `<org>/code-assistant-api/v1` → `<org>` — the bare organization URL the
/// SSO flow needs (re-login from the provider editor).
String codeMieOrgUrl(String baseUrl) => baseUrl.trim().replaceFirst(
  RegExp(r'/code-assistant-api(/v1)?/?$', caseSensitive: false),
  '',
);

/// The result of a successful CodeMie SSO login: the session cookies plus
/// the resolved API base URL.
final class CodeMieSsoCredentials {
  const CodeMieSsoCredentials({
    required this.cookies,
    required this.apiUrl,
    required this.expiresAt,
  });

  /// The session cookies from the callback token.
  final Map<String, String> cookies;

  /// The API base (`<org>/code-assistant-api`).
  final String apiUrl;

  /// Expiry in milliseconds since epoch (from the access-token JWT `exp`,
  /// 24h fallback).
  final int expiresAt;

  /// The full cookie string (`key=value;key=value`) used for Cookie-header
  /// authentication against the CodeMie API. All cookies from the SSO
  /// callback are joined — the CodeMie API expects the complete cookie jar,
  /// not a single Bearer JWT.
  String get authToken =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join(';');

  /// Whether the credentials are past [expiresAt].
  bool get isExpired => DateTime.now().millisecondsSinceEpoch > expiresAt;
}

/// Decodes the callback `token` parameter: base64 JSON with a `cookies`
/// object. Throws [FormatException] on any malformed shape.
Map<String, String> decodeCodeMieSsoToken(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(base64.decode(base64.normalize(raw))));
  } on Object {
    throw const FormatException('CodeMie SSO token is not base64 JSON');
  }
  if (decoded is! Map) {
    throw const FormatException('CodeMie SSO token is not an object');
  }
  final cookies = decoded['cookies'];
  if (cookies is! Map) {
    throw const FormatException('CodeMie SSO token has no cookies');
  }
  return {
    for (final entry in cookies.entries)
      if (entry.value is String) entry.key.toString(): entry.value as String,
  };
}

/// The expiry (ms epoch) of the first JWT cookie's `exp` claim.
///
/// CodeMie instances have been observed using `codemie_access_token`,
/// `access_token`, and other cookie names, so every cookie value that looks
/// like a JWT is inspected. When no JWT with an `exp` claim is found, falls
/// back to 24h from now.
int deriveCodeMieExpiresAt(Map<String, String> cookies) {
  for (final value in cookies.values) {
    final expiresAt = _codeMieJwtExpMs(value);
    if (expiresAt != null) return expiresAt;
  }
  return DateTime.now().millisecondsSinceEpoch + 24 * 60 * 60 * 1000;
}

/// Extracts the `exp` claim from [value] when it is a JWT, or null otherwise.
int? _codeMieJwtExpMs(String value) {
  final trimmed = value.trim();
  if (trimmed.contains(';')) return null;
  final parts = trimmed.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is Map && payload['exp'] is int) {
      return (payload['exp'] as int) * 1000;
    }
  } on Object {
    // Not a decodable JWT.
  }
  return null;
}

/// Parses a CodeMie cookie string (`k=v; k=v`) and checks whether the
/// access-token JWT is past its `exp` claim. If parsing fails, treats the
/// cookie as expired so the caller can force a fresh SSO login.
bool codeMieCookieExpired(String cookie) {
  try {
    final cookies = <String, String>{};
    for (final part in cookie.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      cookies[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
    }
    final expiresAt = deriveCodeMieExpiresAt(cookies);
    return DateTime.now().millisecondsSinceEpoch > expiresAt;
  } on Object {
    return true;
  }
}

/// True when [token] looks like a JWT (`header.payload.signature`). This is a
/// shallow format check; [codeMieJwtExpired] validates the payload too.
/// Cookie strings (`k=v; k=v`) are rejected because they can also contain
/// dots and split into three parts. JWT padding (`=`) is allowed and
/// normalized during decoding.
bool isCodeMieJwtToken(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return false;
  // Cookie-auth strings always contain `;`; a raw JWT never does.
  if (trimmed.contains(';')) return false;
  final parts = trimmed.split('.');
  if (parts.length != 3 || parts.any((p) => p.isEmpty)) return false;
  // Validate that the header decodes as base64url JSON.
  try {
    final header = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
    );
    return header is Map;
  } on Object {
    return false;
  }
}

/// The expiry (ms epoch) of a CodeMie JWT Bearer token's `exp` claim, or null
/// when the token is malformed or has no `exp`.
int? codeMieJwtExpiresAtMs(String token) {
  final parts = token.trim().split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is Map && payload['exp'] is int) {
      return (payload['exp'] as int) * 1000;
    }
  } on Object {
    // Malformed JWT payload.
  }
  return null;
}

/// Whether a CodeMie JWT Bearer token is past its `exp` claim. Tokens without
/// an `exp` claim are treated as non-expired.
bool codeMieJwtExpired(String token) {
  final expiresAt = codeMieJwtExpiresAtMs(token);
  if (expiresAt == null) return false;
  return DateTime.now().millisecondsSinceEpoch > expiresAt;
}

/// Collects application names from the three known fields of the `/v1/user`
/// response, trimming and deduplicating into a sorted list.
List<String> _collectAppNames(Map decoded) {
  final apps = <String>{};
  for (final field in const [
    'applications',
    'applications_admin',
    'applicationsAdmin',
  ]) {
    final value = decoded[field];
    if (value is List) {
      apps.addAll(_filterAppNames(value));
    }
  }
  return apps.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// Filters a raw list down to non-blank, trimmed strings.
Iterable<String> _filterAppNames(List value) sync* {
  for (final item in value) {
    if (item is String && item.trim().isNotEmpty) yield item.trim();
  }
}

/// Fetches the user's accessible projects from `<apiBase>/v1/user` — the
/// `applications` + `applications_admin` arrays merged and deduplicated.
/// Authentication uses the full cookie string as a `Cookie:` header.
Future<List<String>> fetchCodeMieProjects(
  String apiBase,
  String cookie, {
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final response = await httpClient
        .get(Uri.parse('$apiBase/v1/user'), headers: {'cookie': cookie})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ConfigException(
        'CodeMie user info failed (${response.statusCode})',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return const [];
    return _collectAppNames(decoded);
  } finally {
    if (ownsClient) httpClient.close();
  }
}

/// Fetches the model ids from `<apiBase>/llm_models?include_all=true`
/// ([apiBase] is `<org>/code-assistant-api/v1`), authenticating with the
/// full cookie string as a `Cookie:` header. The response is a list of
/// descriptors whose id lives in `id`, `base_name`, or `deployment_name`
/// (first non-empty wins).
Future<List<String>> fetchCodeMieModels(
  String apiBase,
  String cookie, {
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final response = await httpClient
        .get(
          Uri.parse('$apiBase/llm_models?include_all=true'),
          headers: {'cookie': cookie},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ConfigException(
        'CodeMie authentication failed — invalid or expired credentials '
        '(re-run /provider codemie sso)',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ConfigException(
        'CodeMie models request failed (${response.statusCode})',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return [
      for (final model in decoded)
        if (model is Map) ?_modelId(model),
    ];
  } finally {
    if (ownsClient) httpClient.close();
  }
}

/// The first non-empty id field of a CodeMie model descriptor.
String? _modelId(Map<dynamic, dynamic> model) {
  for (final field in const ['id', 'base_name', 'deployment_name']) {
    final value = model[field];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

/// Fetches the model ids from `<apiBase>/llm_models?include_all=true` using
/// JWT Bearer authorization (`Authorization: Bearer <jwtToken>`).
Future<List<String>> fetchCodeMieModelsWithJwt(
  String apiBase,
  String jwtToken, {
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final response = await httpClient
        .get(
          Uri.parse('$apiBase/llm_models?include_all=true'),
          headers: {'authorization': 'Bearer $jwtToken'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ConfigException(
        'CodeMie authentication failed — invalid or expired JWT token '
        '(re-run /provider codemie jwt)',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ConfigException(
        'CodeMie models request failed (${response.statusCode})',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return [
      for (final model in decoded)
        if (model is Map) ?_modelId(model),
    ];
  } finally {
    if (ownsClient) httpClient.close();
  }
}
