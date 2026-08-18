// l10n:ignore-file — OAuth flow screens — en-only by design
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    if (dart.library.html) 'package:fa/services/oauth_cli_flow_stubs.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';

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
/// `providerKind: 'chatgpt-codex'` and the encoded credentials as the API key.
///
/// Returns `true` when the flow completed and the service was reconfigured,
/// `false` when the user cancelled.
Future<bool> runChatGptOAuthFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
}) async {
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
  if (!Platform.isMacOS) {
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

  final credentials = await runChatGptOAuthCliFlow(
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
  const name = 'ChatGPT';
  // The bundled Codex default — gpt-5.6-sol, the same entry the
  // original codex-rs surfaces as recommended. (Was hardcoded to the
  // stale 'o4-mini' value.)
  const modelId = chatGptCodexDefaultModel;

  final encoded = credentials.encode();

  final existing = registry.providers
      .where((p) => p.baseUrl == baseUrl)
      .firstOrNull;

  if (existing != null) {
    final updated = CustomProvider(
      id: existing.id,
      name: existing.name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    await registry.update(updated);
    registry.rememberKey(updated.id, encoded);
  } else {
    final provider = await registry.add(
      name: name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    registry.rememberKey(provider.id, encoded);
  }

  // ── Connect ─────────────────────────────────────────────────────────
  final config = AgentConfig(
    providerKind: 'chatgpt-codex',
    modelId: modelId,
    baseUrl: baseUrl,
    apiKey: encoded,
  );
  if (service != null) await service.reconfigure(config);
  await lastConnectionStore.saveFromConfig(config);

  return true;
}
