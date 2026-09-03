/// OpenRouter OAuth PKCE utilities.
///
/// Pure Dart: no `dart:io`, so it compiles for web and Flutter. The IO-backed
/// pieces (local callback server, browser launcher) live in the CLI layer.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_sandbox/flutter_sandbox.dart';

/// The OpenRouter authorization endpoint.
const openRouterAuthEndpoint = 'https://openrouter.ai/auth';

/// The OpenRouter token/key exchange endpoint.
const openRouterTokenEndpoint = 'https://openrouter.ai/api/v1/auth/keys';

/// Default app label shown to the user on the OpenRouter authorization page.
const openRouterDefaultKeyLabel = 'Fa';

/// Length of the random PKCE code verifier in bytes (produces a URL-safe
/// base64 string of ~128 characters).
const _verifierByteLength = 96;

/// Characters allowed in the PKCE code verifier: [A-Z] / [a-z] / [0-9] /
/// '-' / '.' / '_' / '~' (RFC 7636).
const _verifierAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// Generates a PKCE code verifier.
///
/// The output is a random URL-safe string suitable for the `code_verifier`
/// parameter. It uses a cryptographically secure random source when available
/// (`Random.secure`), falling back to a non-secure source only in test/JS
/// environments where `Random.secure` throws.
String generateOpenRouterCodeVerifier() {
  final random = _secureRandom();
  final bytes = Uint8List(_verifierByteLength);
  for (var i = 0; i < _verifierByteLength; i++) {
    bytes[i] = random.nextInt(_verifierAlphabet.length);
  }
  return String.fromCharCodes(
    bytes.map((b) => _verifierAlphabet.codeUnitAt(b)),
  );
}

Random _secureRandom() {
  try {
    return Random.secure();
  } on Object {
    // Some JS/test environments do not support secure random; degrade
    // gracefully — PKCE still works, just with less entropy.
    return Random(DateTime.now().microsecondsSinceEpoch);
  }
}

/// Generates the S256 code challenge for a [verifier].
///
/// Returns the base64url-encoded SHA-256 hash, without padding, as required
/// by OpenRouter's PKCE docs.
String generateOpenRouterCodeChallenge(String verifier) {
  final hash = sha256.convert(utf8.encode(verifier));
  return base64UrlEncode(hash.bytes).replaceAll('=', '');
}

/// Result of a successful OAuth code exchange.
final class OpenRouterOAuthKey {
  /// Creates a result.
  const OpenRouterOAuthKey({required this.key, this.keyHash, this.label});

  /// The user-controlled OpenRouter API key.
  final String key;

  /// SHA-256 lowercase hex digest of [key], used to build the user's key
  /// settings/logs URLs (`https://openrouter.ai/keys/<hash>`).
  final String? keyHash;

  /// The optional `key_label` that was sent with the authorization request.
  final String? label;

  /// The key settings URL for the signed-in owner, or null when [keyHash] is
  /// unavailable.
  String? get settingsUrl =>
      keyHash == null ? null : 'https://openrouter.ai/keys/$keyHash';

  /// The usage logs URL for the signed-in owner, or null when [keyHash] is
  /// unavailable.
  String? get logsUrl => keyHash == null
      ? null
      : 'https://openrouter.ai/logs?api_key_hash=$keyHash';
}

/// Builds the OpenRouter authorization URL.
///
/// If [callbackUrl] is provided, OpenRouter redirects back to it with a
/// `code` query parameter. If omitted, OpenRouter shows the code on screen
/// (headless/SSH/container mode) and uses [keyLabel] as the display label.
///
/// [codeChallenge] must be the S256 challenge derived from the verifier.
Uri buildOpenRouterAuthUrl({
  required String codeChallenge,
  String? callbackUrl,
  String? keyLabel,
  String? state,
}) {
  final params = <String, String>{
    'code_challenge': codeChallenge,
    'code_challenge_method': 'S256',
  };
  if (callbackUrl != null && callbackUrl.isNotEmpty) {
    params['callback_url'] = callbackUrl;
  }
  if (keyLabel != null && keyLabel.isNotEmpty) {
    params['key_label'] = keyLabel;
  }
  if (state != null && state.isNotEmpty) {
    params['state'] = state;
  }
  return Uri.parse(openRouterAuthEndpoint).replace(queryParameters: params);
}

/// Exchanges an authorization [code] for an OpenRouter API key.
///
/// [codeVerifier] is required when a code challenge was used to start the
/// flow. Pass the same [http.Client] for testability.
///
/// Throws [ConfigException] on invalid/expired codes or network failures.
Future<OpenRouterOAuthKey> exchangeOpenRouterCode(
  String code, {
  required String codeVerifier,
  http.Client? client,
  String? label,
}) async {
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final response = await httpClient
        .post(
          Uri.parse(openRouterTokenEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'code': code,
            'code_verifier': codeVerifier,
            'code_challenge_method': 'S256',
          }),
        )
        .timeout(const Duration(seconds: 30));

    final body = _decodeBody(response.body);

    if (response.statusCode == 200) {
      final key = body['key'];
      if (key is! String || key.isEmpty) {
        throw ConfigException(
          'OpenRouter OAuth exchange succeeded but returned no key',
        );
      }
      final hash = await sha256Hex(key);
      return OpenRouterOAuthKey(key: key, keyHash: hash, label: label);
    }

    final error = body['error'] ?? body['message'] ?? response.body;
    throw ConfigException(
      'OpenRouter OAuth exchange failed (${response.statusCode}): $error',
    );
  } on ConfigException {
    rethrow;
  } on Exception catch (e) {
    throw ConfigException('OpenRouter OAuth exchange failed: $e');
  } finally {
    if (ownsClient) httpClient.close();
  }
}

Map<String, dynamic> _decodeBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return {};
  } on Object {
    return {};
  }
}

/// Computes the lowercase hex SHA-256 digest of [value].
Future<String> sha256Hex(String value) async {
  final hash = sha256.convert(utf8.encode(value));
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}
