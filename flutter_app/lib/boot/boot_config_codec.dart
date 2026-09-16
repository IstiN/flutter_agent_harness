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
  if (connection == null) return null;
  final kind = connection.providerKind;
  // On-device backends re-offer the quick start instead of silently
  // loading multi-GB weights at boot. Every hosted catalog kind
  // (openai-completions, google, anthropic, dial, minimax,
  // chatgpt-codex) restores — a 'google' last connection used to fall
  // into the placeholder home here.
  if (kind == webLlmProviderKind ||
      kind == gemmaProviderKind ||
      kind == transformersJsProviderKind) {
    return null;
  }
  final baseUrl = connection.baseUrl ?? '';
  if (baseUrl.isEmpty) return null;
  CustomProvider? custom;
  if (registry != null) {
    for (final provider in registry.providers) {
      if (provider.baseUrl == baseUrl) {
        custom = provider;
        break;
      }
    }
  }
  var key = custom != null ? registry!.keyFor(custom.id) ?? '' : '';
  if (key.isEmpty && custom != null && kind == 'copilot') {
    // Copilot GitHub tokens are stored entry-scoped (FA_KEY_COPILOT_<NAME>,
    // the CLI contract); the entry name is the registry provider's name.
    key = settingsKeyEnv(
      CustomProviderRegistry.copilotEntryKeyName(custom.name),
      sessionKeysStore,
    );
  }
  if (key.isEmpty) {
    // Hosted catalog kinds resolve their standard key names
    // (GOOGLE_API_KEY, ANTHROPIC_API_KEY, …) from the saved-keys chain.
    // Hosted env names (OPENROUTER_API_KEY, KIMI_API_KEY, ...) resolve
    // only for KNOWN catalog endpoints (issue #327 review MINOR): a
    // custom or unknown base URL must not consume another provider's
    // key. Catalog endpoints keep the kind-first resolution contract.
    final isCatalogEndpoint = providerCatalog.values.any(
      (s) => s.defaultBaseUrl == baseUrl,
    );
    for (final spec in providerCatalog.values) {
      if (spec.kind != kind) continue;
      if (!isCatalogEndpoint) break;
      for (final name in spec.apiKeyEnvNames) {
        key = settingsKeyEnv(name, sessionKeysStore);
        if (key.isNotEmpty) break;
      }
      break;
    }
  }
  // Issue #329: an entry that PERSISTED a key but resolves none on this
  // surface (secure store lost/broken) never boots keyless — a doomed
  // auto-connect would only 401 on the first turn. The setup screen shows
  // instead; selecting the entry in the picker names the problem.
  if (key.isEmpty && custom != null && custom.requiresKey) return null;
  if (key.isEmpty && custom == null) return null;
  final config = AgentConfig(
    providerKind: kind,
    modelId: connection.modelId,
    baseUrl: baseUrl,
    apiKey: key,
    supportsImages: modelIdSuggestsVision(connection.modelId),
  );
  // Issue #327: a connection whose model and auth resolve from
  // DIFFERENT registry rows must not silently 401 with the wrong
  // provider's wording - but (review MAJOR 2) a stale persisted
  // connection must not brick the session either: restore it and let
  // AgentService refuse the REQUEST with the row-naming message. The
  // credential half still refuses the boot (nothing usable to send
  // with).
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
