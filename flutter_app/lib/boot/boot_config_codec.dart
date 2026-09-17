// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The restorable-boot-config codec (issue #483): decodes the persisted
/// [LastConnection] back into the [AgentConfig] the boot auto-connect runs
/// with, or null when the setup screen should show instead.
///
/// Pure decoding logic — no widget, store-loading, or plugin-channel code —
/// so the round-trip property (encode via `LastConnection.fromConfig`,
/// decode here) is unit-testable without booting the app.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/relay/ext_runtime.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/settings_env.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Rebuilds the last connection's [AgentConfig] for the boot auto-connect,
/// or null when the setup screen should show instead: nothing configured,
/// an on-device connection (those re-offer the quick start instead of
/// silently loading multi-GB weights at boot), or a hosted connection
/// whose key is gone. Every hosted catalog kind restores
/// (`openai-completions`, `google`, `anthropic`, `dial`, `minimax`,
/// `chatgpt-codex`, `copilot`). Key order: the matching custom provider's
/// (Keychain-backed) registry key, then — for Copilot, whose tokens live
/// entry-scoped — `FA_KEY_COPILOT_<NAME>` from the saved-keys chain, then
/// the catalog kind's standard env names (`GOOGLE_API_KEY`, …), then the
/// legacy hosted key; keyless custom endpoints (llama.cpp/Ollama) connect
/// without a key.
AgentConfig? restorableBootConfig({
  required LastConnection? connection,
  required ProviderRegistry? registry,
  required SessionKeysStore? sessionKeysStore,
}) {
  final baseUrl = connection?.baseUrl ?? '';
  if (connection == null ||
      baseUrl.isEmpty ||
      _isOnDeviceKind(connection.providerKind)) {
    return null;
  }
  final custom = _matchCustomProvider(registry, baseUrl);
  return _restore(connection, registry, custom, sessionKeysStore);
}

/// The on-device backends re-offer the quick start instead of silently
/// loading multi-GB weights at boot. Every hosted catalog kind
/// (openai-completions, google, anthropic, dial, minimax,
/// chatgpt-codex) restores.
bool _isOnDeviceKind(String kind) =>
    kind == webLlmProviderKind ||
    kind == gemmaProviderKind ||
    kind == transformersJsProviderKind;

/// The registry provider with the exact same base URL, if any.
CustomProvider? _matchCustomProvider(
  ProviderRegistry? registry,
  String baseUrl,
) {
  if (registry == null) return null;
  for (final provider in registry.providers) {
    if (provider.baseUrl == baseUrl) return provider;
  }
  return null;
}

/// Builds the config for a validated connection, refusing keyless
/// credentials and broken providers (issues #329/#327).
AgentConfig? _restore(
  LastConnection connection,
  ProviderRegistry? registry,
  CustomProvider? custom,
  SessionKeysStore? sessionKeysStore,
) {
  final kind = connection.providerKind;
  final baseUrl = connection.baseUrl ?? '';
  final key = _resolveKey(kind, baseUrl, custom, registry, sessionKeysStore);
  // Issue #329: an entry that PERSISTED a key but resolves none on this
  // surface (secure store lost/broken) never boots keyless — a doomed
  // auto-connect would only 401 on the first turn. The setup screen shows
  // instead; selecting the entry in the picker names the problem.
  if (key.isEmpty && (custom == null || custom.requiresKey)) return null;
  final config = AgentConfig(
    providerKind: kind,
    modelId: connection.modelId,
    baseUrl: baseUrl,
    apiKey: key,
    supportsImages: modelIdSuggestsVision(connection.modelId),
  );
  return _bootOutcome(registry, config);
}

/// Key precedence: the matching custom provider's (Keychain-backed)
/// registry key, then — for Copilot, whose tokens live entry-scoped —
/// `FA_KEY_COPILOT_<NAME>` from the saved-keys chain, then the catalog
/// kind's standard env names (`GOOGLE_API_KEY`, …).
String _resolveKey(
  String kind,
  String baseUrl,
  CustomProvider? custom,
  ProviderRegistry? registry,
  SessionKeysStore? sessionKeysStore,
) {
  var key = custom == null ? '' : registry!.keyFor(custom.id) ?? '';
  if (key.isEmpty) key = _copilotEntryKey(kind, custom, sessionKeysStore);
  if (key.isEmpty) key = _catalogEnvKey(kind, baseUrl, sessionKeysStore);
  return key;
}

/// Copilot GitHub tokens are stored entry-scoped (`FA_KEY_COPILOT_<NAME>`,
/// the CLI contract); the entry name is the registry provider's name.
String _copilotEntryKey(
  String kind,
  CustomProvider? custom,
  SessionKeysStore? sessionKeysStore,
) {
  if (kind != 'copilot' || custom == null) return '';
  return settingsKeyEnv(
    CustomProviderRegistry.copilotEntryKeyName(custom.name),
    sessionKeysStore,
  );
}

/// Hosted catalog kinds resolve their standard key names
/// (GOOGLE_API_KEY, ANTHROPIC_API_KEY, …) from the saved-keys chain.
/// Hosted env names (OPENROUTER_API_KEY, KIMI_API_KEY, ...) resolve
/// only for KNOWN catalog endpoints (issue #327 review MINOR): a
/// custom or unknown base URL must not consume another provider's
/// key. Catalog endpoints keep the kind-first resolution contract.
String _catalogEnvKey(
  String kind,
  String baseUrl,
  SessionKeysStore? sessionKeysStore,
) {
  final spec = _catalogSpecFor(kind, baseUrl);
  if (spec == null) return '';
  for (final name in spec.apiKeyEnvNames) {
    final key = settingsKeyEnv(name, sessionKeysStore);
    if (key.isNotEmpty) return key;
  }
  return '';
}

/// The first catalog spec of [kind] whose endpoint serves [baseUrl].
ProviderSpec? _catalogSpecFor(String kind, String baseUrl) {
  if (!providerCatalog.values.any((spec) => spec.defaultBaseUrl == baseUrl)) {
    return null;
  }
  for (final spec in providerCatalog.values) {
    if (spec.kind == kind) return spec;
  }
  return null;
}

/// Degraded restore vs honest refusal for a built config (issue #327):
/// a connection whose model and auth resolve from DIFFERENT registry
/// rows must not silently 401 with the wrong provider's wording - but
/// a stale persisted connection must not brick the session either:
/// restore it and let AgentService refuse the REQUEST with the
/// row-naming message. The credential half still refuses the boot
/// (nothing usable to send with).
AgentConfig? _bootOutcome(ProviderRegistry? registry, AgentConfig config) {
  final mismatch = modelRowMismatch(registry, config);
  if (mismatch != null) {
    debugPrint('[Fa] boot: degraded connection restored — $mismatch');
    return config;
  }
  final problem = providerConnectionProblem(
    registry,
    config,
    extensionHost: isExtensionHost(),
  );
  if (problem != null) {
    debugPrint('[Fa] boot: refusing broken connection — $problem');
    return null;
  }
  return config;
}
