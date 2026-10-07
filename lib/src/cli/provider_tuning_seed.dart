/// Boot seeding of the per-provider stall-recovery tuning table (issue
/// #1398): every provider registry entry that declares
/// `connectTimeoutMs`/`streamIdleTimeoutMs` registers into
/// [providerTuningRegistry], keyed by its `baseUrl` — the wire seams
/// (`sendWatchedProviderRequest` connect watchdog, `createSseIterator`
/// idle watchdog) resolve per request URL.
///
/// Resolution order (one, documented): **provider entry > the global
/// `providerTimeouts:` section > the built-in defaults**, per field.
/// Config reload re-runs the seeder (E4: the NEXT request recomputes; an
/// in-flight request already resolved its values). Queue `ref` entries
/// need no special handling — they materialize the referenced custom
/// provider's `baseUrl`, so the URL-keyed lookup finds the entry.
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
void seedProviderTuning({
  List<CustomProviderEntry>? customProviders,
  Map<String, CustomModelDefinition>? customModels,
  List<ModelRef>? roleRefs,
  List<ProviderQueueEntry>? queueEntries,
}) {
  final custom = customProviders ?? const [];
  for (final entry in custom) {
    if (entry.connectTimeout == null && entry.streamIdleTimeout == null) {
      continue;
    }
    providerTuningRegistry.register(
      name: entry.name,
      baseUrl: entry.baseUrl,
      connect: entry.connectTimeout,
      streamIdle: entry.streamIdleTimeout,
    );
  }
  final models = customModels ?? const {};
  for (final e in models.entries) {
    if (e.value.connectTimeout == null && e.value.streamIdleTimeout == null) {
      continue;
    }
    providerTuningRegistry.register(
      name: 'models.custom.${e.key}',
      baseUrl: e.value.baseUrl,
      connect: e.value.connectTimeout,
      streamIdle: e.value.streamIdleTimeout,
    );
  }
  for (final ref in roleRefs ?? const <ModelRef>[]) {
    if (ref.baseUrl == null) continue;
    if (ref.connectTimeout == null && ref.streamIdleTimeout == null) continue;
    providerTuningRegistry.register(
      name: 'role:${ref.label}',
      baseUrl: ref.baseUrl!,
      connect: ref.connectTimeout,
      streamIdle: ref.streamIdleTimeout,
    );
  }
  for (final entry in queueEntries ?? const <ProviderQueueEntry>[]) {
    if (entry.baseUrl == null) continue;
    if (entry.connectTimeout == null && entry.streamIdleTimeout == null) {
      continue;
    }
    providerTuningRegistry.register(
      name: 'queue:${entry.label}',
      baseUrl: entry.baseUrl!,
      connect: entry.connectTimeout,
      streamIdle: entry.streamIdleTimeout,
    );
  }
}

/// The boot notice lines for the seeded entries (one per entry, rendered
/// next to the model line): `provider tuning glm-relay (https://…/v1):
/// connect 180s (default), idle 1.5s (provider:glm-relay)`. Empty when no
/// entries registered — the silent REG path.
List<String> providerTuningBootNotices() => [
  for (final entry in providerTuningRegistry.entries)
    'provider tuning ${entry.name} (${entry.baseUrl}): '
        '${describeProviderTimeouts(resolveProviderTimeouts(name: entry.name))}',
];
