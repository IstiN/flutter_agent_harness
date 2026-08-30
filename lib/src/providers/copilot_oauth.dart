/// GitHub Copilot API token plumbing: the short-lived "internal api" token
/// exchange, the mandatory per-request Copilot headers, the `X-Initiator`
/// rule, and the in-memory token manager (single-flight, proactive refresh,
/// minimum exchange spacing).
///
/// Protocol migrated from copilot-proxy-go (internal/auth/github_client.go:
/// FetchCopilotToken, internal/api/config.go: BuildCopilotHeaders) per
/// goal/copilot_provider.md. Pure Dart: no `dart:io`.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../types.dart';
import 'provider_common.dart';

/// Pinned editor identity (the proxy scrapes VS Code versions; we pin one
/// constant — goal/copilot_provider.md).
const _copilotEditorVersion = 'vscode/1.109.3';
const _copilotPluginVersion = 'copilot-chat/0.37.6';
const _copilotUserAgent = 'GitHubCopilotChat/0.37.6';
const _copilotApiVersion = '2025-10-01';

/// The token exchange endpoint — the same for all account types
/// (individual/business/enterprise differ only in the API base URL).
const copilotTokenExchangeUrl =
    'https://api.github.com/copilot_internal/v2/token';

/// Copilot API base URLs per account type (goal: copilot-proxy-go
/// internal/api/config.go: GetBaseURL). Any new/corporate address works
/// via an explicit baseUrl override in config.
const copilotIndividualBaseUrl = 'https://api.githubcopilot.com';
const copilotBusinessBaseUrl = 'https://api.business.githubcopilot.com';
const copilotEnterpriseBaseUrl = 'https://api.enterprise.githubcopilot.com';

/// The GitHub credential was rejected by the token exchange (HTTP 401/403):
/// the GitHub token is dead and must be re-issued (`/provider copilot`),
/// NOT refreshed like a short-lived Copilot token would be.
final class CopilotAuthException implements Exception {
  /// Creates the auth failure with a user-facing [message].
  const CopilotAuthException(this.message);

  /// The human-readable failure description.
  final String message;

  @override
  String toString() => message;
}

/// A short-lived Copilot API token (lifetime ~30 min).
final class CopilotApiToken {
  /// Creates a token.
  const CopilotApiToken({
    required this.token,
    required this.expiresAt,
    required this.refreshIn,
  });

  /// Builds a token from the exchange payload
  /// `{token, expires_at (unix seconds), refresh_in (seconds)}`.
  factory CopilotApiToken.fromJson(Map<String, dynamic> json) {
    return CopilotApiToken(
      token: json['token'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expires_at'] as num).toInt() * 1000,
        isUtc: true,
      ),
      refreshIn: (json['refresh_in'] as num?)?.toInt() ?? 0,
    );
  }

  /// The Bearer credential for Copilot API requests.
  final String token;

  /// When the token stops working (UTC).
  final DateTime expiresAt;

  /// The endpoint's refresh hint in seconds.
  final int refreshIn;
}

/// Exchanges a GitHub token for a Copilot API token (goal:
/// copilot-proxy-go internal/auth/github_client.go).
///
/// Throws [CopilotAuthException] on a non-200 — HTTP 401 means the GitHub
/// token is dead (the caller must trigger re-auth, not a token refresh);
/// every other status carries the response body in the message.
Future<CopilotApiToken> fetchCopilotApiToken({
  required String githubToken,
  http.Client? client,
}) async {
  final httpClient = client ?? sharedProviderHttpClient();
  final response = await httpClient
      .get(
        Uri.parse(copilotTokenExchangeUrl),
        headers: {
          'authorization': 'token $githubToken',
          'accept': 'application/json',
          'editor-version': _copilotEditorVersion,
          'editor-plugin-version': _copilotPluginVersion,
          'user-agent': _copilotUserAgent,
          'copilot-integration-id': 'vscode-chat',
        },
      )
      .timeout(effectiveProviderConnectTimeout);
  if (response.statusCode == 401) {
    throw const CopilotAuthException(
      'GitHub token rejected (401) by the Copilot token exchange — '
      're-authorize Copilot (CLI: /provider copilot).',
    );
  }
  if (response.statusCode != 200) {
    throw CopilotAuthException(
      'Copilot token exchange failed (HTTP ${response.statusCode}): '
      '${response.body.trim()}',
    );
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) {
    throw const CopilotAuthException(
      'Copilot token exchange returned an unexpected payload.',
    );
  }
  return CopilotApiToken.fromJson(decoded);
}

/// The GitHub login behind a token (`GET https://api.github.com/user`,
/// goal: the account name is the default Copilot entry name
/// `copilot-<login>`). Throws [CopilotAuthException] on a non-200.
Future<String> fetchGitHubLogin({
  required String githubToken,
  http.Client? client,
}) async {
  final transport = client ?? sharedProviderHttpClient();
  final response = await transport
      .get(
        Uri.parse('https://api.github.com/user'),
        headers: {
          'authorization': 'token $githubToken',
          'accept': 'application/json',
        },
      )
      .timeout(effectiveProviderConnectTimeout);
  if (response.statusCode != 200) {
    throw CopilotAuthException(
      'could not resolve the GitHub account (HTTP ${response.statusCode}): '
      '${response.body.trim()}',
    );
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic> || decoded['login'] is! String) {
    throw const CopilotAuthException(
      'the GitHub user response had an unexpected shape.',
    );
  }
  return decoded['login'] as String;
}

/// The mandatory Copilot API headers, per request (goal:
/// copilot-proxy-go internal/api/config.go: BuildCopilotHeaders). A fresh
/// `x-request-id` UUID is minted per call.
Map<String, String> copilotApiHeaders({required String copilotToken}) => {
  'authorization': 'Bearer $copilotToken',
  'content-type': 'application/json',
  'copilot-integration-id': 'vscode-chat',
  'editor-version': _copilotEditorVersion,
  'editor-plugin-version': _copilotPluginVersion,
  'user-agent': _copilotUserAgent,
  'openai-intent': 'conversation-agent',
  'x-github-api-version': _copilotApiVersion,
  'x-request-id': _uuidV4(),
  'x-vscode-user-agent-library-version': 'electron-fetch',
};

/// The `X-Initiator` value for [messages]: `agent` when the LAST message is
/// an assistant or tool result (a continuation of the model's own turn),
/// `user` otherwise (goal: copilot-proxy-go requestHeaders).
String copilotInitiatorFor(List<Message> messages) {
  final role = messages.isEmpty ? '' : messages.last.role;
  return role == 'assistant' || role == 'toolResult' ? 'agent' : 'user';
}

final _requestIdRandom = Random.secure();

String _uuidV4() {
  final bytes = List<int>.generate(16, (_) => _requestIdRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// In-memory cache of the short-lived Copilot API token for one GitHub
/// token: single-flight exchange, proactive refresh [refreshLead] before
/// expiry, and at most one exchange per [minSpacing] (proxy semantics:
/// ~30 min tokens, refresh ~2 min early, never more often than 30 s).
final class CopilotTokenManager {
  /// Creates a manager. [now] is injectable for tests; [client] for mock
  /// transports.
  CopilotTokenManager({
    required this.githubToken,
    this.client,
    DateTime Function()? now,
    this.refreshLead = const Duration(minutes: 2),
    this.minSpacing = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now;

  /// The GitHub token exchanged for Copilot API tokens.
  final String githubToken;

  /// The HTTP transport (injectable for tests; the shared provider client
  /// when null).
  final http.Client? client;

  /// Refresh this long before [CopilotApiToken.expiresAt].
  final Duration refreshLead;

  /// Lower bound between two token exchanges.
  final Duration minSpacing;

  final DateTime Function() _now;
  CopilotApiToken? _cached;
  DateTime? _lastExchangeAt;
  Future<String>? _inFlight;

  /// Per-GitHub-token registry: the cache lives as long as the process so
  /// consecutive turns reuse the ~30 min token instead of re-exchanging
  /// per call (one entry per account — no cross-account state).
  static final _byGithubToken = <String, CopilotTokenManager>{};

  /// The shared manager for [githubToken], creating it on first use.
  static CopilotTokenManager forGithubToken(
    String githubToken, {
    http.Client? client,
  }) => _byGithubToken.putIfAbsent(
    githubToken,
    () => CopilotTokenManager(githubToken: githubToken, client: client),
  );

  /// Drops the cached token and the spacing guard: the next [get]
  /// exchanges immediately (used after a 401/403 from the Copilot API).
  void invalidate() {
    _cached = null;
    _lastExchangeAt = null;
  }

  /// A Copilot API token valid at call time, exchanging/refreshing as
  /// needed. Concurrent callers share one exchange (single-flight).
  Future<String> get() =>
      _inFlight ??= _get().whenComplete(() => _inFlight = null);

  Future<String> _get() async {
    final cached = _cached;
    final now = _now();
    if (cached != null && _isUsable(cached, now)) return cached.token;
    final sinceExchange = _lastExchangeAt == null
        ? null
        : now.difference(_lastExchangeAt!);
    // Exchanged too recently: keep the token we have (proxy: min 30 s
    // between exchanges), even if it is inside the refresh lead. Without a
    // token at all the first use beats the spacing rule.
    if (cached != null && sinceExchange != null && sinceExchange < minSpacing) {
      return cached.token;
    }
    return _exchange();
  }

  bool _isUsable(CopilotApiToken token, DateTime now) =>
      token.expiresAt.isAfter(now.add(refreshLead));

  Future<String> _exchange() async {
    _lastExchangeAt = _now();
    final token = await fetchCopilotApiToken(
      githubToken: githubToken,
      client: client,
    );
    _cached = token;
    return token.token;
  }
}
