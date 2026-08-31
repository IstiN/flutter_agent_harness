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

/// Runs the full ChatGPT OAuth flow:
///
/// **macOS** — a local callback server (`ChatGptOAuthLocalCallbackServer`) is
/// started, the system browser is opened so the user authenticates with their
/// ChatGPT account, and the redirect to `http://127.0.0.1:<port>/auth/callback`
/// is caught by the server. This mirrors the CLI flow.
///
/// **iOS** — a local server is not viable. The flow shows an honest "not yet
/// available" message until a proper in-app WebView flow is built.
///
/// After OAuth completes, the credentials are saved as a custom provider with
/// `providerKind: 'chatgpt-codex'` and the encoded credentials as the API
/// key. The entry name comes from the OAuth account's email, so several
/// ChatGPT accounts coexist as separate entries, each with its own
/// entry-scoped key slot (the CLI contract).
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
}) async {
  final sessionKeys = sessionKeysStore ?? SessionKeysScope.maybeOf(context);
  final keychain = keychainStore ?? const KeychainStore();
  if (kIsWeb) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ChatGPT sign-in needs the desktop app (a localhost callback '
            'server). Use OpenAI with an API key in the web build.',
          ),
        ),
      );
    }
    return false;
  }
  if (!(platformSupportedFn?.call() ?? Platform.isMacOS)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ChatGPT sign-in is not yet available on iOS. '
            'Use OpenAI with an API key instead.',
          ),
        ),
      );
    }
    return false;
  }

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Opening browser for ChatGPT sign-in…'),
      duration: Duration(seconds: 3),
    ),
  );

  final credentials = chatGptOAuthFlowFn != null
      ? await chatGptOAuthFlowFn()
      : await runChatGptOAuthCliFlow(
          onStatus: (msg) => debugPrint('[ChatGPT OAuth] $msg'),
          openBrowserFn: (url) async {
            return url_launcher.launchUrl(
              Uri.parse(url),
              mode: url_launcher.LaunchMode.externalApplication,
            );
          },
        );
  if (credentials == null) return false;
  if (!context.mounted) return false;

  // ── Save provider + key ─────────────────────────────────────────────
  const baseUrl = chatGptCodexBaseUrl;
  final encoded = credentials.encode();

  // The entry name IS the account slot (like `copilot-<login>`): it is
  // derived from the OAuth account's email so a second ChatGPT account
  // lands in its own entry instead of overwriting the first one's
  // credentials.
  final name = _chatGptEntryName(credentials, registry);

  // Re-auth updates only the matching entry (matched by entry name +
  // endpoint) and keeps its model choice; a different account creates a
  // new entry. Multiple accounts are first-class, like the CLI.
  final existing = registry.providers
      .where((p) => p.name == name && p.baseUrl == baseUrl)
      .firstOrNull;
  final provider =
      existing ??
      await registry.add(
        name: name,
        baseUrl: baseUrl,
        // The bundled Codex default — the same entry codex-rs surfaces as
        // recommended (chatGptCodexDefaultModel is derived, not const).
        modelId: chatGptCodexDefaultModel,
      );

  // Session key for the running app (Keychain-backed when available).
  registry.rememberKey(provider.id, encoded);
  // Entry-scoped secure persistence (the CLI contract): Keychain first,
  // saved-keys store as the portable fallback.
  final keyName = chatgptEntryKeyName(name);
  var persisted = false;
  if (await keychain.isAvailable()) {
    persisted = await keychain.set(keyName, encoded);
  }
  if (!persisted) {
    await sessionKeys?.set(keyName, encoded);
  }

  // ── Connect ─────────────────────────────────────────────────────────
  final config = AgentConfig(
    providerKind: 'chatgpt-codex',
    modelId: provider.modelId,
    baseUrl: baseUrl,
    apiKey: encoded,
  );
  if (service != null) await service.reconfigure(config);
  await lastConnectionStore.saveFromConfig(config);

  return true;
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

/// The registry entry name for the signed-in ChatGPT account: the email
/// claim of the OAuth id_token (the account identity, like
/// `copilot-<login>`), de-duplicated with `-2`… so two accounts never
/// share one entry.
String _chatGptEntryName(
  ChatGptOAuthCredentials credentials,
  ProviderRegistry registry,
) {
  final email = _chatGptEmail(credentials.idToken) ?? 'ChatGPT';
  var name = email;
  var suffix = 2;
  while (registry.providers.any(
    (p) => p.name == name && p.baseUrl == chatGptCodexBaseUrl,
  )) {
    name = '$email-${suffix++}';
  }
  return name;
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
