/// ChatGPT OAuth helpers used by the Codex-compatible provider.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_sandbox/flutter_sandbox.dart';

const chatGptIssuer = 'https://auth.openai.com';
const chatGptCodexBaseUrl = 'https://chatgpt.com/backend-api/codex';
const chatGptOAuthClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const chatGptOAuthScope =
    'openid profile email offline_access api.connectors.read api.connectors.invoke';

/// OAuth credentials issued for a ChatGPT account.
final class ChatGptOAuthCredentials {
  const ChatGptOAuthCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    this.accountId,
    this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String idToken;
  final String? accountId;

  /// When the access token expires, in UTC; null when unknown.
  final DateTime? expiresAt;

  Map<String, String> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'id_token': idToken,
    if (accountId != null) 'chatgpt_account_id': ?accountId,
    if (expiresAt != null)
      'expires_at': expiresAt!.millisecondsSinceEpoch.toString(),
  };

  String encode() => jsonEncode(toJson());

  factory ChatGptOAuthCredentials.decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      throw const FormatException('OAuth credentials are not an object');
    }
    String field(String name) {
      final result = decoded[name];
      if (result is! String || result.isEmpty) {
        throw FormatException('OAuth credentials are missing $name');
      }
      return result;
    }

    final accountId = decoded['chatgpt_account_id'];
    return ChatGptOAuthCredentials(
      accessToken: field('access_token'),
      refreshToken: field('refresh_token'),
      idToken: field('id_token'),
      accountId: accountId is String && accountId.isNotEmpty
          ? accountId
          : _accountIdFromJwt(field('id_token')),
      expiresAt: _persistedExpiry(decoded['expires_at']),
    );
  }

  /// Whether [now] is at or past expiry minus [skew].
  bool needsRefresh(
    DateTime now, {
    Duration skew = const Duration(seconds: 60),
  }) {
    final expiresAt = this.expiresAt;
    return expiresAt != null && !now.isBefore(expiresAt.subtract(skew));
  }
}

/// Parses the persisted `expires_at`: an epoch-millisecond string (what
/// [ChatGptOAuthCredentials.toJson] writes) or a raw int (blobs persisted
/// before the string tightening). Anything else counts as unknown.
DateTime? _persistedExpiry(Object? value) => switch (value) {
  final int milliseconds => DateTime.fromMillisecondsSinceEpoch(
    milliseconds,
    isUtc: true,
  ),
  final String milliseconds when int.tryParse(milliseconds) != null =>
    DateTime.fromMillisecondsSinceEpoch(int.parse(milliseconds), isUtc: true),
  _ => null,
};

String generateChatGptPkceVerifier() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final random = _secureRandom();
  final bytes = Uint8List(96);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = alphabet.codeUnitAt(random.nextInt(alphabet.length));
  }
  return String.fromCharCodes(bytes);
}

String generateChatGptPkceChallenge(String verifier) => base64UrlEncode(
  sha256.convert(utf8.encode(verifier)).bytes,
).replaceAll('=', '');

String generateChatGptState() {
  final random = _secureRandom();
  final bytes = Uint8List(32);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll('=', '');
}

Uri buildChatGptAuthorizeUrl({
  required String redirectUri,
  required String codeChallenge,
  required String state,
}) => Uri.parse('$chatGptIssuer/oauth/authorize').replace(
  queryParameters: {
    'response_type': 'code',
    'client_id': chatGptOAuthClientId,
    'redirect_uri': redirectUri,
    'scope': chatGptOAuthScope,
    'code_challenge': codeChallenge,
    'code_challenge_method': 'S256',
    'id_token_add_organizations': 'true',
    'codex_cli_simplified_flow': 'true',
    'state': state,
    'originator': 'codex_cli_rs',
  },
);

Future<ChatGptOAuthCredentials> exchangeChatGptAuthorizationCode({
  required String code,
  required String redirectUri,
  required String codeVerifier,
  http.Client? client,
}) => _tokenRequest({
  'grant_type': 'authorization_code',
  'code': code,
  'redirect_uri': redirectUri,
  'client_id': chatGptOAuthClientId,
  'code_verifier': codeVerifier,
}, client: client);

Future<ChatGptOAuthCredentials> refreshChatGptCredentials(
  ChatGptOAuthCredentials credentials, {
  http.Client? client,
}) async {
  final refreshed = await _tokenRequest(
    {
      'grant_type': 'refresh_token',
      'refresh_token': credentials.refreshToken,
      'client_id': chatGptOAuthClientId,
    },
    client: client,
    jsonBody: true,
  );
  return ChatGptOAuthCredentials(
    accessToken: refreshed.accessToken,
    refreshToken: refreshed.refreshToken.isEmpty
        ? credentials.refreshToken
        : refreshed.refreshToken,
    idToken: refreshed.idToken.isEmpty
        ? credentials.idToken
        : refreshed.idToken,
    accountId: refreshed.accountId ?? credentials.accountId,
    expiresAt: refreshed.expiresAt ?? credentials.expiresAt,
  );
}

Future<ChatGptOAuthCredentials> _tokenRequest(
  Map<String, String> fields, {
  http.Client? client,
  bool jsonBody = false,
}) async {
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final response = await httpClient
        .post(
          Uri.parse('$chatGptIssuer/oauth/token'),
          headers: {
            'Content-Type': jsonBody
                ? 'application/json'
                : 'application/x-www-form-urlencoded',
          },
          body: jsonBody
              ? jsonEncode(fields)
              : fields.entries
                    .map(
                      (e) =>
                          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
                    )
                    .join('&'),
        )
        .timeout(const Duration(seconds: 30));
    final body = _jsonObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ConfigException(
        'ChatGPT OAuth token request failed (${response.statusCode}): ${body['error_description'] ?? body['error'] ?? response.body}',
      );
    }
    String token(String name, {bool required = true}) {
      final value = body[name];
      if (value is String && value.isNotEmpty) return value;
      if (!required) return '';
      throw ConfigException('ChatGPT OAuth token response has no $name');
    }

    final idToken = token('id_token', required: false);
    final expiresIn = body['expires_in'];
    return ChatGptOAuthCredentials(
      accessToken: token('access_token'),
      refreshToken: token('refresh_token', required: false),
      idToken: idToken,
      accountId: _accountIdFromJwt(idToken),
      expiresAt: expiresIn is int
          ? DateTime.now().toUtc().add(Duration(seconds: expiresIn))
          : null,
    );
  } on ConfigException {
    rethrow;
  } on Object catch (error) {
    throw ConfigException('ChatGPT OAuth token request failed: $error');
  } finally {
    if (ownsClient) httpClient.close();
  }
}

Map<String, dynamic> _jsonObject(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : const {};
  } on Object {
    return const {};
  }
}

String? _accountIdFromJwt(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map) return null;
    final auth = payload['https://api.openai.com/auth'];
    final value = auth is Map ? auth['chatgpt_account_id'] : null;
    return value is String && value.isNotEmpty ? value : null;
  } on Object {
    return null;
  }
}

Random _secureRandom() {
  try {
    return Random.secure();
  } on Object {
    return Random();
  }
}
