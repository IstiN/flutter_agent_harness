/// Boot seeding of the per-provider stall-recovery tuning table (issue
/// #1398): every provider registry entry that declares
/// `connectTimeoutMs`/`streamIdleTimeoutMs` registers into
/// [providerTuningRegistry], keyed by its `baseUrl` — the wire seams
/// (`sendWatchedProviderRequest` connect watchdog, `createSseIterator`
/// idle watchdog) resolve per request URL.
///
/// Resolution order (one, documented): **provider entry > the global
/// `providerTimeouts:` section > the built-in defaults**, per field.
///
/// Lifecycle (boot-scoped, review r2): the production seeder runs at
/// BOOT only — the config pass in `bin/fah_runapp.dart` and, later, the
/// queue pass (queue entries must be in the table before
/// [providerTuningBootNotices] is captured, or they never print). A
/// mid-session config edit does NOT re-seed by itself: E4's
/// "recompute for the NEXT request" applies when a host re-runs
/// [seedProviderTuning] — pass `reset: true` so entries REMOVED from the
/// config also leave the table (without the reset, `register` only
/// replaces/adds rows and a deleted entry would persist forever).
/// Queue `ref` entries need no special handling — they materialize the
/// referenced custom provider's `baseUrl`, so the URL-keyed lookup finds
/// the entry.
library;

import '../model_roles/models_config.dart';
import '../model_roles/providers_queue.dart';
import '../model_roles/roles_config.dart';
import '../providers/provider_tuning.dart';
import 'custom_providers.dart';

/// Registers every tuning-bearing registry entry into
/// [providerTuningRegistry]. All parameters optional; entries without
/// overrides never reach the table (the AC6 fast path: no entries → the
/// wire seams keep today's exact values).
///
/// [reset] clears the table FIRST — the full-reload form (E4): boot's two
/// passes run without it (the queue pass must ADD to the config pass),
/// while a host applying a fresh config snapshot resets so removed
/// entries cannot outlive their config.
///
/// Table-driven on purpose (the CRAP ratchet): each config surface maps
/// through its own tiny [_customProviderTuning]/[_customModelTuning]/
/// [_roleRefTuning]/[_queueEntryTuning] adapter, and the loop lives once
/// inside [ProviderTuningRegistry.registerAll].
void seedProviderTuning({
  List<CustomProviderEntry>? customProviders,
  Map<String, CustomModelDefinition>? customModels,
  List<ModelRef>? roleRefs,
  List<ProviderQueueEntry>? queueEntries,
  bool reset = false,
}) {
  if (reset) providerTuningRegistry.clear();
  providerTuningRegistry.registerAll(
    [
      ...?customProviders?.map(_customProviderTuning),
      ...?customModels?.entries.map(_customModelTuning),
      ...?roleRefs?.map(_roleRefTuning),
      ...?queueEntries?.map(_queueEntryTuning),
    ].nonNulls,
  );
}

ProviderTuningEntry _customProviderTuning(CustomProviderEntry entry) =>
    ProviderTuningEntry(
      name: entry.name,
      baseUrl: entry.baseUrl,
      connect: entry.connectTimeout,
      streamIdle: entry.streamIdleTimeout,
    );

ProviderTuningEntry _customModelTuning(
  MapEntry<String, CustomModelDefinition> entry,
) => ProviderTuningEntry(
  name: 'models.custom.${entry.key}',
  baseUrl: entry.value.baseUrl,
  connect: entry.value.connectTimeout,
  streamIdle: entry.value.streamIdleTimeout,
);

/// Null when the chain entry carries no endpoint — nothing to key on.
ProviderTuningEntry? _roleRefTuning(ModelRef ref) => ref.baseUrl == null
    ? null
    : ProviderTuningEntry(
        name: 'role:${ref.label}',
        baseUrl: ref.baseUrl!,
        connect: ref.connectTimeout,
        streamIdle: ref.streamIdleTimeout,
      );

/// Null when the queue entry carries no endpoint — nothing to key on.
ProviderTuningEntry? _queueEntryTuning(ProviderQueueEntry entry) =>
    entry.baseUrl == null
    ? null
    : ProviderTuningEntry(
        name: 'queue:${entry.label}',
        baseUrl: entry.baseUrl!,
        connect: entry.connectTimeout,
        streamIdle: entry.streamIdleTimeout,
      );

/// The boot notice lines for the seeded entries (one per entry, rendered
/// next to the model line): `provider tuning glm-relay (https://…/v1):
/// connect 180s (default), idle 1.5s (provider:glm-relay)`. Empty when no
/// entries registered — the silent REG path.
List<String> providerTuningBootNotices() => [
  for (final entry in providerTuningRegistry.entries)
    'provider tuning ${entry.name} (${entry.baseUrl}): '
        '${resolveProviderTimeouts(name: entry.name).describe()}',
];
