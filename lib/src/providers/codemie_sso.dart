/// CodeMie SSO helpers: browser-based login against a CodeMie organization
/// (`/v1/auth/login/<port>` redirects to a localhost callback with a base64
/// token carrying the session cookies) and the model list endpoint. The
/// CodeMie API authenticates via the FULL cookie string (sent as a `Cookie:`
/// header), not via a Bearer JWT — the SSO callback returns an
/// `_oauth2_proxy` cookie (Keycloak OAuth2 proxy), and the API expects the
/// entire cookie jar. The chat traffic rides the standard openai-completions
/// adapter with a `cookie:` model header that suppresses the default
/// `authorization` header.
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

/// The expiry (ms epoch) of the `codemie_access_token` JWT's `exp` claim,
/// falling back to 24h from now when the cookie is absent or undecodable.
int deriveCodeMieExpiresAt(Map<String, String> cookies) {
  final jwt = cookies['codemie_access_token'];
  if (jwt != null) {
    final parts = jwt.split('.');
    if (parts.length == 3) {
      try {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (payload is Map && payload['exp'] is int) {
          return (payload['exp'] as int) * 1000;
        }
      } on Object {
        // Malformed JWT — fall through to the default TTL.
      }
    }
  }
  return DateTime.now().millisecondsSinceEpoch + 24 * 60 * 60 * 1000;
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
    final apps = <String>{};
    for (final field in const [
      'applications',
      'applications_admin',
      'applicationsAdmin',
    ]) {
      final value = decoded[field];
      if (value is List) {
        for (final item in value) {
          if (item is String && item.trim().isNotEmpty) apps.add(item.trim());
        }
      }
    }
    final sorted = apps.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
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
