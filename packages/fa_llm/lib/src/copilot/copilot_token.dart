import 'dart:convert';

import 'package:http/http.dart' as http;

import 'copilot_endpoints.dart';

/// Base exception for the Copilot auth chain.
class CopilotAuthException implements Exception {
  final String message;

  CopilotAuthException(this.message);

  @override
  String toString() => 'CopilotAuthException: $message';
}

/// GitHub OAuth device-flow failures (expired code, user denial).
class CopilotDeviceFlowException extends CopilotAuthException {
  CopilotDeviceFlowException(super.message);
}

/// Copilot token exchange failures (non-200 from the internal API).
class CopilotTokenExchangeException extends CopilotAuthException {
  CopilotTokenExchangeException(super.message);
}

/// The GitHub token is dead (401 from the exchange endpoint): refreshing is
/// pointless — the caller must re-authenticate.
class CopilotDeadGithubTokenException extends CopilotTokenExchangeException {
  CopilotDeadGithubTokenException(super.message);
}

/// Result of the device-flow start.
class CopilotDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;

  /// Seconds the device code stays valid.
  final int expiresIn;

  /// Base polling interval.
  final Duration interval;

  const CopilotDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });
}

/// A short-lived Copilot API token.
class CopilotToken {
  final String token;

  /// Absolute expiry (from `expires_at`, unix seconds).
  final DateTime expiresAt;

  /// Server-suggested refresh window in seconds, if provided.
  final int? refreshIn;

  const CopilotToken({
    required this.token,
    required this.expiresAt,
    this.refreshIn,
  });

  factory CopilotToken.fromJson(Map<String, dynamic> json) => CopilotToken(
    token: json['token'] as String,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      (json['expires_at'] as int) * 1000,
      isUtc: true,
    ),
    refreshIn: json['refresh_in'] as int?,
  );
}

Map<String, String> _editorHeaders() => const {
  'Accept': 'application/json',
  'Editor-Version': 'vscode/1.109.3',
  'Editor-Plugin-Version': 'copilot-chat/0.37.6',
  'User-Agent': 'GitHubCopilotChat/0.37.6',
  'Copilot-Integration-Id': 'vscode-chat',
};

/// Starts the GitHub OAuth device flow (copilot-proxy-go
/// `internal/auth/device_flow.go`): POST /login/device/code.
Future<CopilotDeviceCode> requestCopilotDeviceCode({
  String? clientId,
  String scope = 'read:user',
  http.Client? client,
}) async {
  final response = await (client ?? http.Client()).post(
    Uri.parse('https://github.com/login/device/code'),
    headers: {'Accept': 'application/json'},
    body: {'client_id': clientId ?? copilotDefaultClientId, 'scope': scope},
  );
  if (response.statusCode != 200) {
    throw CopilotDeviceFlowException(
      'Device-code request failed: ${response.statusCode} ${response.body}',
    );
  }
  final json = jsonDecodeMap(response.body);
  return CopilotDeviceCode(
    deviceCode: json['device_code'] as String,
    userCode: json['user_code'] as String,
    verificationUri: json['verification_uri'] as String,
    expiresIn: json['expires_in'] as int,
    interval: Duration(seconds: json['interval'] as int),
  );
}

Map<String, dynamic> jsonDecodeMap(String body) =>
    (jsonDecode(body) as Map).cast<String, dynamic>();

/// Polls GitHub until the device flow completes and returns the GitHub
/// access token.
///
/// Semantics (copilot-proxy-go `internal/auth/device_flow.go`):
/// `authorization_pending` → keep waiting; `slow_down` → +5s to the interval
/// (cumulative); `expired_token` / `access_denied` → fail; the loop is
/// bounded by [expiresIn] seconds of accumulated wait time. [delay] is
/// injectable so tests never sleep.
Future<String> pollCopilotAccessToken({
  required String deviceCode,
  String? clientId,
  int? expiresIn,
  Duration interval = const Duration(seconds: 5),
  http.Client? client,
  Future<void> Function(Duration wait)? delay,
}) async {
  Future<void> wait(Duration d) => delay != null ? delay(d) : Future.delayed(d);
  var waited = Duration.zero;
  while (expiresIn == null || waited.inSeconds < expiresIn) {
    final response = await (client ?? http.Client()).post(
      Uri.parse('https://github.com/login/oauth/access_token'),
      headers: {'Accept': 'application/json'},
      body: {
        'client_id': clientId ?? copilotDefaultClientId,
        'device_code': deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    );
    final json = jsonDecodeMap(response.body);
    final accessToken = json['access_token'] as String?;
    if (accessToken != null) return accessToken;

    switch (json['error'] as String?) {
      case 'authorization_pending':
        break;
      case 'slow_down':
        interval += const Duration(seconds: 5);
        break;
      case 'expired_token':
        throw CopilotDeviceFlowException(
          'Device flow failed: the device code expired. Start over.',
        );
      case 'access_denied':
        throw CopilotDeviceFlowException(
          'Device flow failed: access was denied by the user.',
        );
      default:
        throw CopilotDeviceFlowException(
          'Device flow failed: ${json['error'] ?? response.body}',
        );
    }
    waited += interval;
    await wait(interval);
  }
  throw CopilotDeviceFlowException(
    'Device flow failed: the device code expired. Start over.',
  );
}

/// Exchanges a GitHub token for a short-lived Copilot API token
/// (copilot-proxy-go `internal/auth/github_client.go: FetchCopilotToken`).
///
/// The endpoint is the same for all account types.
Future<CopilotToken> fetchCopilotToken({
  required String githubToken,
  http.Client? client,
}) async {
  final response = await (client ?? http.Client()).get(
    Uri.parse('https://api.github.com/copilot_internal/v2/token'),
    headers: {'Authorization': 'token $githubToken', ..._editorHeaders()},
  );
  if (response.statusCode == 401) {
    throw CopilotDeadGithubTokenException(
      'GitHub token was rejected (401); re-authentication required. '
      'Body: ${response.body}',
    );
  }
  if (response.statusCode != 200) {
    throw CopilotTokenExchangeException(
      'Copilot token exchange failed: ${response.statusCode} ${response.body}',
    );
  }
  return CopilotToken.fromJson(jsonDecodeMap(response.body));
}

/// Resolves the GitHub login for a token (GET /user) — used as the default
/// entry name for multiple accounts (`copilot-<login>`).
Future<String> fetchGithubLogin({
  required String githubToken,
  http.Client? client,
}) async {
  final response = await (client ?? http.Client()).get(
    Uri.parse('https://api.github.com/user'),
    headers: {
      'Authorization': 'Bearer $githubToken',
      'Accept': 'application/json',
    },
  );
  if (response.statusCode != 200) {
    throw CopilotAuthException(
      'GitHub /user failed: ${response.statusCode} ${response.body}',
    );
  }
  return jsonDecodeMap(response.body)['login'] as String;
}
