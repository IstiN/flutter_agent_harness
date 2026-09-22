// l10n:ignore-file — OAuth flow screens — en-only by design
import 'dart:async';
import 'dart:convert' show base64Url, jsonDecode, utf8;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    if (dart.library.html) 'package:fa/services/oauth_cli_flow_stubs.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/screens/chatgpt_oauth_webview.dart';

/// Runs the full ChatGPT OAuth flow:
///
/// **macOS** — a local callback server (`ChatGptOAuthLocalCallbackServer`) is
/// started, the system browser is opened so the user authenticates with their
/// ChatGPT account, and the redirect to `http://127.0.0.1:<port>/auth/callback`
/// is caught by the server. This mirrors the CLI flow.
///
/// **iOS** — no server is ever bound. The flow assembles the PKCE authorize
/// URL from the harness functions (`buildChatGptAuthorizeUrl`, loopback-shaped
/// redirect) and pushes [ChatGptOAuthWebViewPage], whose `NavigationDelegate`
/// intercepts the `http://localhost:<port>/auth/callback` redirect and hands
/// back the state-validated `code`; the flow then completes the
/// `exchangeChatGptAuthorizationCode` token exchange in Dart. This mirrors
/// the CodeMie SSO WebView hop.
///
/// Both hops funnel into the same shared tail: the credentials are saved as a
/// custom provider with `providerKind: 'chatgpt-codex'` and the encoded
/// credentials as the API key. The entry name comes from the OAuth account's
/// email, so several ChatGPT accounts coexist as separate entries, each with
/// its own entry-scoped key slot (the CLI contract).
///
/// Returns `true` when the flow completed and the service was reconfigured,
/// `false` when the user cancelled.
Future<bool> runChatGptOAuthFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  Future<ChatGptOAuthCredentials?> Function()? chatGptOAuthFlowFn,
  bool Function()? platformSupportedFn,

  /// iOS hop seams (tests); production passes the defaults.
  bool Function()? iosFn,
  ChatGptCodeExchange? exchangeFn,
  Future<String?> Function(BuildContext, Uri, String)? pushWebView,
}) async {
  // Issue #586 (CodeMie): the caller's context can be disposed by a
  // transcript rebuild mid-flow — anchor the flow on the ROOT navigator.
  final flowContext = Navigator.of(context, rootNavigator: true).context;
  final sessionKeys = sessionKeysStore ?? SessionKeysScope.maybeOf(flowContext);
  final keychain = keychainStore ?? const KeychainStore();
  final refusal = _unsupportedMessage(platformSupportedFn);
  if (refusal != null) return _refuse(flowContext, refusal);

  final credentials = await _acquireCredentials(
    flowContext,
    chatGptOAuthFlowFn: chatGptOAuthFlowFn,
    iosFn: iosFn,
    exchangeFn: exchangeFn,
    pushWebView: pushWebView,
  );
  if (credentials == null || !flowContext.mounted) return false;

  final encoded = credentials.encode();
  final provider = await _saveCredentials(
    registry,
    keychain,
    sessionKeys,
    credentials,
    encoded,
  );
  await _connect(
    service,
    lastConnectionStore,
    AgentConfig(
      providerKind: 'chatgpt-codex',
      modelId: provider.modelId,
      baseUrl: chatGptCodexBaseUrl,
      apiKey: encoded,
    ),
  );
  return true;
}

const _webUnsupportedMessage =
    'ChatGPT sign-in needs the desktop or mobile app '
    '(a localhost callback server or the in-app sign-in browser). '
    'Use OpenAI with an API key in the web build.';

const _otherPlatformUnsupportedMessage =
    'ChatGPT sign-in ships on macOS and iOS. '
    'Use OpenAI with an API key on this platform.';

/// Why ChatGPT sign-in cannot run on this surface, or null when it can:
/// the web build has no OAuth browser surface, and the sign-in hop ships
/// on macOS (local callback server) and iOS (in-app WebView interception)
/// only.
String? _unsupportedMessage(bool Function()? platformSupportedFn) {
  if (kIsWeb) return _webUnsupportedMessage;
  final supported =
      platformSupportedFn?.call() ?? (Platform.isMacOS || Platform.isIOS);
  if (supported) return null;
  return _otherPlatformUnsupportedMessage;
}

/// The honest unsupported-surface snackbar; the flow always returns
/// `false`.
bool _refuse(BuildContext context, String message) {
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
  return false;
}

/// Runs the injected flow (tests) or the real per-surface hop: iOS the
/// in-app WebView interception, everything else the CLI flow (local
/// callback server + system browser).
Future<ChatGptOAuthCredentials?> _acquireCredentials(
  BuildContext context, {
  Future<ChatGptOAuthCredentials?> Function()? chatGptOAuthFlowFn,
  bool Function()? iosFn,
  ChatGptCodeExchange? exchangeFn,
  Future<String?> Function(BuildContext, Uri, String)? pushWebView,
}) async {
  if (chatGptOAuthFlowFn != null) return chatGptOAuthFlowFn();
  if (iosFn?.call() ?? Platform.isIOS) {
    return _acquireIosCredentials(
      context,
      pushWebView: pushWebView ?? _pushChatGptOAuthWebView,
      exchangeFn: exchangeFn,
    );
  }
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Opening browser for ChatGPT sign-in…'),
      duration: Duration(seconds: 3),
    ),
  );
  return runChatGptOAuthCliFlow(
    onStatus: (msg) => debugPrint('[ChatGPT OAuth] $msg'),
    openBrowserFn: (url) async {
      return url_launcher.launchUrl(
        Uri.parse(url),
        mode: url_launcher.LaunchMode.externalApplication,
      );
    },
  );
}

/// The loopback redirect the iOS WebView intercepts. The port is never
/// bound — the Codex OAuth client registers the loopback redirect with a
/// variable port (standard for native clients), so the canonical codex
/// port keeps the URL predictable.
const _iosCallbackPort = 1455;

/// The shape of [exchangeChatGptAuthorizationCode] without its test-only
/// `client` parameter.
typedef ChatGptCodeExchange =
    Future<ChatGptOAuthCredentials> Function({
      required String code,
      required String redirectUri,
      required String codeVerifier,
    });

/// The iOS acquisition hop (issue #773): assemble the PKCE authorize URL
/// from the harness functions only, let [ChatGptOAuthWebViewPage] intercept
/// the loopback redirect (no port bound), then exchange the code in Dart.
/// A cancellation returns null with no partial state; an exchange failure
/// surfaces a named error and the flow re-arms on the next run (every run
/// generates a fresh state + verifier).
Future<ChatGptOAuthCredentials?> _acquireIosCredentials(
  BuildContext context, {
  required Future<String?> Function(BuildContext, Uri, String) pushWebView,
  ChatGptCodeExchange? exchangeFn,
}) async {
  final redirectUri = 'http://localhost:$_iosCallbackPort/auth/callback';
  final verifier = generateChatGptPkceVerifier();
  final state = generateChatGptState();
  final code = await pushWebView(
    context,
    buildChatGptAuthorizeUrl(
      redirectUri: redirectUri,
      codeChallenge: generateChatGptPkceChallenge(verifier),
      state: state,
    ),
    state,
  );
  if (code == null) return null; // user cancelled / timed out
  try {
    return await (exchangeFn ?? exchangeChatGptAuthorizationCode)(
      code: code,
      redirectUri: redirectUri,
      codeVerifier: verifier,
    );
  } on Object catch (error) {
    if (context.mounted) {
      _refuse(context, 'ChatGPT sign-in failed at the token exchange: $error');
    }
    return null;
  }
}

/// The production WebView hop: pushes [ChatGptOAuthWebViewPage], which pops
/// with the intercepted authorization code (null on cancel/timeout).
Future<String?> _pushChatGptOAuthWebView(
  BuildContext context,
  Uri authorizeUrl,
  String expectedState,
) => Navigator.of(context).push<String?>(
  MaterialPageRoute(
    builder: (_) => ChatGptOAuthWebViewPage(
      authorizeUrl: authorizeUrl.toString(),
      expectedState: expectedState,
    ),
  ),
);

/// Reuses the signed-in account's entry (re-auth refreshes it in place)
/// or adds a de-duplicated one, remembers the session key, and persists
/// the entry-scoped secure copy.
Future<CustomProvider> _saveCredentials(
  ProviderRegistry registry,
  KeychainStore keychain,
  SessionKeysStore? sessionKeys,
  ChatGptOAuthCredentials credentials,
  String encoded,
) async {
  // The entry name IS the signed-in account's email. Re-auth: an entry
  // for THIS account (email + endpoint) already exists — keep its name so
  // the flow refreshes it in place. Without an email claim the account
  // identity is unknown — a name match is never treated as re-auth.
  // Otherwise a new account gets a de-duplicated name (-2…), so two
  // accounts never share one entry.
  final email = _chatGptEmail(credentials.idToken);
  final identity = email ?? 'ChatGPT';
  final provider =
      _existingEntry(registry, email, identity) ??
      await registry.add(
        name: _uniqueEntryName(registry, identity),
        baseUrl: chatGptCodexBaseUrl,
        // The bundled Codex default — the same entry codex-rs surfaces as
        // recommended (chatGptCodexDefaultModel is derived, not const).
        modelId: chatGptCodexDefaultModel,
      );

  // Session key for the running app (Keychain-backed when available).
  registry.rememberKey(provider.id, encoded);
  await _persistEntryKey(
    keychain,
    sessionKeys,
    chatgptEntryKeyName(provider.name),
    encoded,
  );
  return provider;
}

/// The registry entry for THIS account (email + endpoint). Without an
/// email claim the account identity is unknown — a name match is never
/// treated as re-auth.
CustomProvider? _existingEntry(
  ProviderRegistry registry,
  String? email,
  String identity,
) => email == null
    ? null
    : registry.providers
          .where((p) => p.name == identity && p.baseUrl == chatGptCodexBaseUrl)
          .firstOrNull;

/// A name no other ChatGPT entry uses (`-2`, `-3`, … suffixes), so two
/// accounts never share one entry.
String _uniqueEntryName(ProviderRegistry registry, String identity) {
  var name = identity;
  var suffix = 2;
  while (registry.providers.any(
    (p) => p.name == name && p.baseUrl == chatGptCodexBaseUrl,
  )) {
    name = '$identity-${suffix++}';
  }
  return name;
}

/// Keychain first (the entry-scoped CLI contract); the saved-keys store
/// as the portable fallback.
Future<void> _persistEntryKey(
  KeychainStore keychain,
  SessionKeysStore? sessionKeys,
  String keyName,
  String encoded,
) async {
  var persisted = false;
  if (await keychain.isAvailable()) {
    persisted = await keychain.set(keyName, encoded);
  }
  if (!persisted) {
    await sessionKeys?.set(keyName, encoded);
  }
}

/// Hands the restored credentials to the running service (when there is
/// one) and persists the last connection.
Future<void> _connect(
  AgentService? service,
  LastConnectionStore lastConnectionStore,
  AgentConfig config,
) async {
  if (service != null) await service.reconfigure(config);
  await lastConnectionStore.saveFromConfig(config);
}

/// Secure-store name of a ChatGPT entry's OAuth credentials blob:
/// `FA_KEY_CHATGPT_COM_<SANITIZED_ENTRY_NAME>`. Byte-identical with the
/// CLI's `CustomProviderRegistry.keyNameFor(chatGptCodexBaseUrl,
/// providerName: entryName)` (same sanitizer: uppercase, `[^A-Z0-9]+` →
/// `_`, trim edge underscores) so both surfaces read the same Keychain
/// entry and a refresh-token rotation stays inside the account's slot.
String chatgptEntryKeyName(String entryName) {
  const host = 'CHATGPT_COM'; // chatgpt.com, from chatGptCodexBaseUrl
  final sanitized = entryName
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return sanitized.isEmpty || sanitized == host
      ? 'FA_KEY_$host'
      : 'FA_KEY_${host}_$sanitized';
}

/// The `email` claim of the OAuth id_token JWT payload, or null when the
/// token carries none (the fallback name keeps the flow usable).
String? _chatGptEmail(String idToken) {
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  final String payload;
  try {
    payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  try {
    final claims = jsonDecode(payload);
    final email = claims is Map<String, Object?> ? claims['email'] : null;
    return email is String && email.isNotEmpty ? email : null;
  } on FormatException {
    return null;
  }
}
