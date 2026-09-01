// l10n:ignore-file — OAuth flow screens — en-only by design
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa_llm/fa_llm.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show CustomProviderRegistry, fetchModelsForEndpoint;
import 'package:fa_ui/fa_ui.dart'
    show CopilotConnectCallbacks, CopilotConnectResult, showCopilotConnectSheet;

/// Runs the full GitHub Copilot connect flow: the device-flow sheet (real
/// fa_llm wiring unless [callbacks] is injected — the device flow needs no
/// callback server, so it works on every platform including iOS), then
/// registry entry + key persistence + reconfigure:
///
/// 1. The GitHub token is stored entry-scoped (`FA_KEY_COPILOT_<NAME>`) in
///    the Keychain when available, else the saved-keys store.
/// 2. A [CustomProvider] named `copilot-<login>` is added — or, when an
///    entry with the same name and endpoint already exists (re-auth), only
///    that entry's key is refreshed (its model choice is kept).
/// 3. The service reconfigures with `providerKind: 'copilot'` and the
///    connection becomes the last connection (boot restore).
///
/// Returns `true` when the flow completed and the service was reconfigured,
/// `false` when the user cancelled or the platform cannot run it.
Future<bool> runCopilotConnectFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  CopilotConnectCallbacks? callbacks,
}) async {
  final sessionKeys = sessionKeysStore ?? SessionKeysScope.maybeOf(context);
  final keychain = keychainStore ?? const KeychainStore();
  if (kIsWeb) {
    // github.com serves no CORS headers; the browser build cannot run the
    // device flow — say so instead of failing mid-sheet.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'GitHub Copilot sign-in is not available on web — use the '
            'desktop or mobile app.',
          ),
        ),
      );
    }
    return false;
  }

  final resolved =
      callbacks ??
      CopilotConnectCallbacks(
        requestDeviceCode: requestCopilotDeviceCode,
        pollAccessToken: (deviceCode) =>
            pollCopilotAccessToken(deviceCode: deviceCode.deviceCode),
        fetchLogin: (token) => fetchGithubLogin(githubToken: token),
        // The connect sheet's model step: the live /models of the resolved
        // endpoint (the Copilot token exchange runs inside the dialect) —
        // no default model exists.
        fetchModels: (token, baseUrl) async =>
            (await fetchModelsForEndpoint(
              baseUrl,
              apiKey: token,
              provider: 'copilot',
            )).$1,
      );

  CopilotConnectResult? result;
  await showCopilotConnectSheet(
    context: context,
    callbacks: resolved,
    onResult: (r) => result = r,
  );
  final connect = result;
  if (connect == null) return false;

  final baseUrl = copilotBaseUrl(
    accountType: connect.accountType,
    baseUrlOverride: connect.baseUrlOverride,
  );

  // Re-auth updates only that entry (matched by entry name + endpoint);
  // a new login/plan creates a new entry. Multiple accounts are
  // first-class, like the CLI.
  final existing = registry.providers
      .where((p) => p.name == connect.entryName && p.baseUrl == baseUrl)
      .firstOrNull;
  final provider =
      existing ??
      await registry.add(
        name: connect.entryName,
        baseUrl: baseUrl,
        modelId: connect.modelId,
      );

  // Session key for the running app (Keychain-backed when available).
  registry.rememberKey(provider.id, connect.githubToken);
  // Entry-scoped secure persistence (the CLI contract): Keychain first,
  // saved-keys store as the portable fallback.
  final keyName = CustomProviderRegistry.copilotEntryKeyName(connect.entryName);
  var persisted = false;
  if (await keychain.isAvailable()) {
    persisted = await keychain.set(keyName, connect.githubToken);
  }
  if (!persisted) {
    await sessionKeys?.set(keyName, connect.githubToken);
  }

  final config = AgentConfig(
    providerKind: 'copilot',
    modelId: provider.modelId,
    baseUrl: baseUrl,
    apiKey: connect.githubToken,
  );
  if (service != null) await service.reconfigure(config);
  await lastConnectionStore.saveFromConfig(config);

  return true;
}
