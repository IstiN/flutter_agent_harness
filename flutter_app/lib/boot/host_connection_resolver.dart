// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The host-session resolver (issue #2391): turns a product profile's
/// `hostConnection` section plus the host page's bridged key into the
/// app's working connection.
///
/// Contract highlights:
/// - The bridged key lives in PROCESS MEMORY ONLY ([ProviderRegistry
///   .rememberSessionKey]) — never providers.json, never a secure store,
///   never any Fa-owned namespace; it is re-read from the bridge on every
///   boot.
/// - The registry entry is a single non-secret `host` row
///   (`provenance: host`, `kind: host-session`), upserted idempotently;
///   the profile is its single source of truth (a stale persisted copy is
///   corrected, and removing the section removes the entry).
/// - Profile model-role and media-slot defaults are DEFAULTS: they fill
///   only selections the user has not made; a saved role or slot override
///   always wins. Undeclared slots stay unconfigured (the gh-1844 rule —
///   nothing is inherited implicitly).
/// - No bridge key (absent, empty, whitespace) resolves to NO session —
///   the app behaves exactly like today. No popup, no connect flow, no
///   error.
library;

import 'package:fa/boot/host_session_bridge.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The resolved host session: the registry row, the memory-only key, and
/// the profile section it came from. Held by [BootStores] and consumed by
/// the boot decision (no provider gate, session ready immediately).
final class HostSessionState {
  const HostSessionState({
    required this.provider,
    required this.bridgedKey,
    required this.connection,
  });

  /// The upserted `host` registry row (non-secret definition).
  final CustomProvider provider;

  /// The bridged key, memory-only for this session.
  final String bridgedKey;

  /// The validated profile section.
  final HostConnectionConfig connection;

  /// The boot [AgentConfig] for the product's default model (used when
  /// nothing else is restorable — the user's saved chat model always wins).
  AgentConfig get bootConfig => configFor(connection.defaultModel);

  /// The [AgentConfig] for [modelId] on the host entry (the persisted
  /// connection's chosen model re-attached to the bridged key).
  AgentConfig configFor(String modelId) => AgentConfig(
    providerKind: 'openai-completions',
    modelId: modelId,
    baseUrl: provider.baseUrl,
    apiKey: bridgedKey,
    supportsImages: false,
  );
}

/// Resolves the host session from [productConfig] and [bridge]. Returns
/// null — after removing any stale host entry the profile no longer
/// declares — when the section is absent or the bridge is empty.
Future<HostSessionState?> resolveHostSession({
  required FaProductConfig productConfig,
  required ProviderRegistry registry,
  required TaskModelsStore taskModels,
  required MediaModelsStore mediaModels,
  HostSessionBridge? bridge,
}) async {
  final section = productConfig.hostConnection;
  if (section == null) {
    await _removeStaleHostEntry(registry);
    return null;
  }
  final rawKey = (bridge ?? platformHostSessionBridge).read(
    section.sessionBridge.key,
  );
  final bridgedKey = rawKey?.trim() ?? '';
  if (bridgedKey.isEmpty) {
    // "No session" (E12): no entry is created, no defaults applied, no
    // error — the stock provider step remains the visitor's path.
    return null;
  }
  final provider = await registry.upsert(
    CustomProvider(
      id: 'host',
      name: section.name,
      baseUrl: section.baseUrl.toString(),
      modelId: section.defaultModel,
      provenance: 'host',
      kind: 'host-session',
    ),
  );
  // The bridged key rides the session-memory map only (issue #2391).
  registry.rememberSessionKey('host', bridgedKey);
  await _applyRoleDefaults(section, taskModels);
  await _applyMediaSlotDefaults(section, mediaModels);
  return HostSessionState(
    provider: provider,
    bridgedKey: bridgedKey,
    connection: section,
  );
}

/// Applies the profile's role defaults to the app-managed roles the user
/// has not configured. The app store carries `smol` and `subagent`
/// (Settings → Task models); other profile roles stay profile metadata for
/// later slices — the harness falls them through the main connection.
Future<void> _applyRoleDefaults(
  HostConnectionConfig section,
  TaskModelsStore taskModels,
) async {
  for (final entry in section.modelRoles.entries) {
    if (!TaskRole.all.contains(entry.key)) continue;
    if (taskModels.overrideFor(entry.key) != null) continue;
    await taskModels.setOverride(
      entry.key,
      TaskRoleConfig(
        providerKind: 'openai-completions',
        baseUrl: section.baseUrl.toString(),
        modelId: entry.value,
      ),
    );
  }
}

/// Applies the profile's declared media-slot defaults to the slots the
/// user has not overridden. The key reaches the media tools through the
/// override's named-key seam ([ProviderRegistry.keyValueForName]) — the
/// same session-memory entry the chat connection uses, so no separate
/// credential exists. Undeclared slots stay unconfigured (gh-1844).
Future<void> _applyMediaSlotDefaults(
  HostConnectionConfig section,
  MediaModelsStore mediaModels,
) async {
  final baseUrl = section.baseUrl.toString();
  final keyName = ProviderRegistry.keyNameFor(baseUrl);
  for (final entry in section.mediaSlots.entries) {
    if (mediaModels.overrideFor(entry.key) != null) continue;
    await mediaModels.setOverride(
      entry.key,
      MediaSlotOverride(
        providerKind: 'openai-completions',
        baseUrl: baseUrl,
        modelId: entry.value.model,
        apiKeyName: keyName,
        providerId: 'host',
      ),
    );
  }
}

/// The profile is the single source of truth for host entries: an entry
/// with provenance `host` that the current profile no longer declares is
/// removed (AC4 / E4).
Future<void> _removeStaleHostEntry(ProviderRegistry registry) async {
  final stale = [
    for (final provider in registry.providers)
      if (provider.provenance == 'host' || provider.id == 'host') provider,
  ];
  for (final provider in stale) {
    await registry.remove(provider.id);
  }
}
