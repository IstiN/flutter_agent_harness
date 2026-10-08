/// The layered model capability resolver (gh-1426): ONE precedence over
/// context window / max output tokens / thinking level for every model fa
/// talks to.
///
/// Layer precedence — the FIRST explicit value wins per field:
///
/// 1. **per-provider+model user override** — `models.overrides.<provider>.
///    <modelId>` in `~/.fah/config.yaml` (kimi-style: survives every
///    catalog refresh; strict [ConfigException] on a bad shape);
/// 2. **role slot** — the `roles:` chain entry's own explicit caps
///    (`contextWindow`/`maxTokens`/`thinkingLevel`, issues #734/#638);
/// 3. **endpoint-published truth** — `contextWindow`/`maxTokens` the
///    endpoint's `/v1/models` payload reported (the picker flows carry
///    them; the resolver folds them where known);
/// 4. **shared catalog** — the remote fa1.dev catalog window, the Claude
///    output-ceiling table (#273), the provider spec defaults;
/// 5. **global clamp** — `agent.contextWindowCap` replaces the window LAST
///    (#729 semantics preserved: clamps down, raises to served truth).
///
/// Thinking precedence: model pin (override) > role slot, then the gate —
/// a pinned rung on a `reasoning:false` model is dropped with a LOUD note
/// (never silently sent; the request proceeds without thinking fields).
///
/// Pure Dart: no IO, no clock, no environment. Hosts install the user
/// override layer via [modelCapabilityOverrides]; the CLI edit flow and
/// the app settings write the same keys the resolver reads.
///
/// Boundary floors (the ticket's UT-1 invariants): an override window may
/// never land below [minOverrideContextWindow] (the compaction reserve —
/// below it the summarizer can never keep up) and an override maxTokens
/// may never land below [minOverrideMaxTokens] (the thinking invariant's
/// answer floor). The yaml parser rejects violations loudly; the resolver
/// floors programmatically-built values as the safety net.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import '../model.dart';
import '../providers/thinking.dart';
import 'provider_catalog.dart';
import 'roles_config.dart' show ModelRef;

/// The compaction reserve ([minAnswerTokens] is the output-side twin):
/// an override context window below it is rejected at parse — the
/// summarizer needs this much headroom to make any compaction progress.
const int minOverrideContextWindow = 16384;

/// The answer floor of the thinking invariant: an override maxTokens below
/// it is rejected at parse — thinking budgets clamp to fit INSIDE
/// max_tokens, and an answer budget under [minAnswerTokens] can never
/// satisfy the invariant.
const int minOverrideMaxTokens = minAnswerTokens;

/// Documented defaults for a (provider, model) NO layer knows — pi's
/// unknown/custom-model defaults (the catalog's own guesses must never
/// strand an unknown model silently at 16384 when the endpoint serves
/// more; overrides address the gap explicitly).
const int unknownModelContextWindow = 128000;
const int unknownModelMaxTokens = 16384;

/// One per-model user override: the fields the user pinned for
/// `<provider>/<modelId>`, all optional — an absent field resolves
/// through the layers below.
final class ModelCapabilityOverride {
  /// Creates an override; every field optional.
  const ModelCapabilityOverride({
    this.contextWindow,
    this.maxTokens,
    this.thinkingLevel,
    this.omitMaxOutputTokens,
  });

  /// Parses one `models.overrides.<provider>.<modelId>` entry, strictly:
  /// only the four known fields, positive integers at/above the floors,
  /// a ladder rung for [thinkingLevel] (`xhigh`/`max` fold to `high`).
  /// Every error names the key (`models.overrides.<provider>.<modelId>`).
  factory ModelCapabilityOverride.fromYaml(
    String provider,
    String modelId,
    Object? node,
  ) {
    final where = 'models.overrides.$provider.$modelId';
    if (node is! YamlMap) {
      throw ConfigException('$where must be a map of capability fields');
    }
    const knownFields = [
      'contextWindow',
      'maxTokens',
      'thinkingLevel',
      'omitMaxOutputTokens',
    ];
    for (final key in node.keys) {
      if (!knownFields.contains(key)) {
        throw ConfigException(
          'unknown field "$key" in $where — expected '
          '${knownFields.join(', ')}',
        );
      }
    }
    int? boundedInt(String field, int floor, String floorWhy) {
      final value = node[field];
      if (value == null) return null;
      if (value is! int) {
        throw ConfigException('$where.$field must be an integer');
      }
      if (value < floor) {
        throw ConfigException(
          '$where.$field must be at least $floor ($floorWhy)',
        );
      }
      return value;
    }

    final thinking = node['thinkingLevel'];
    final thinkingLevel = switch (thinking) {
      null => null,
      String value =>
        normalizeConfigThinkingLevel(value.trim()) ??
        (throw ConfigException(
          '$where.thinkingLevel must be one of '
          '${configThinkingLevels.join(', ')}, got: $value',
        )),
      final other => throw ConfigException(
        '$where.thinkingLevel must be one of '
        '${configThinkingLevels.join(', ')}, got: $other',
      ),
    };
    final omit = node['omitMaxOutputTokens'];
    return ModelCapabilityOverride(
      contextWindow: boundedInt(
        'contextWindow',
        minOverrideContextWindow,
        'the compaction reserve',
      ),
      maxTokens: boundedInt(
        'maxTokens',
        minOverrideMaxTokens,
        'the thinking answer floor',
      ),
      thinkingLevel: thinkingLevel,
      omitMaxOutputTokens: switch (omit) {
        null => null,
        true => true,
        false => false,
        final other => throw ConfigException(
          '$where.omitMaxOutputTokens must be a boolean, got: $other',
        ),
      },
    );
  }

  /// Pinned total context window in tokens.
  final int? contextWindow;

  /// Pinned maximum output tokens.
  final int? maxTokens;

  /// Pinned thinking rung (already normalized to the ladder).
  final String? thinkingLevel;

  /// Whether the endpoint rejects the max-output field outright (the
  /// omp/codex compat lesson): the OpenAI-completions adapter omits it.
  final bool? omitMaxOutputTokens;

  /// True when the entry pins nothing (the config file then omits it).
  bool get isEmpty =>
      contextWindow == null &&
      maxTokens == null &&
      thinkingLevel == null &&
      omitMaxOutputTokens == null;

  /// Serializes to yaml lines at [indent] (round-trips with [fromYaml]).
  void writeYaml(StringBuffer buffer, String indent) {
    if (contextWindow != null) {
      buffer.write('${indent}contextWindow: $contextWindow\n');
    }
    if (maxTokens != null) buffer.write('${indent}maxTokens: $maxTokens\n');
    if (thinkingLevel != null) {
      buffer.write('${indent}thinkingLevel: $thinkingLevel\n');
    }
    if (omitMaxOutputTokens != null) {
      buffer.write('${indent}omitMaxOutputTokens: $omitMaxOutputTokens\n');
    }
  }
}

/// The `models.overrides:` map: `<provider> → <modelId> → override`.
/// Keys are free-form (unknown providers/models are legal — they address
/// catalog futures, E4); the lookup normalizes the provider name and
/// matches the model id verbatim.
final class ModelCapabilityOverrides {
  final Map<String, Map<String, ModelCapabilityOverride>> _byProvider;

  /// Creates an empty (or pre-populated) overrides map.
  ModelCapabilityOverrides({
    Map<String, Map<String, ModelCapabilityOverride>>? entries,
  }) : _byProvider = {
         for (final entry in (entries ?? const {}).entries)
           entry.key: Map.of(entry.value),
       };

  /// Parses the `overrides:` node, strictly: providers and model ids are
  /// non-empty strings, entries are [ModelCapabilityOverride] maps.
  factory ModelCapabilityOverrides.fromYaml(Object? node) {
    if (node == null) return ModelCapabilityOverrides();
    if (node is! YamlMap) {
      throw ConfigException('models.overrides must be a map, got: $node');
    }
    final overrides = ModelCapabilityOverrides();
    for (final providerEntry in node.entries) {
      final provider = providerEntry.key;
      if (provider is! String || provider.trim().isEmpty) {
        throw ConfigException(
          'models.overrides provider names must be non-empty strings, '
          'got: $provider',
        );
      }
      if (providerEntry.value == null) {
        throw ConfigException(
          'models.overrides.$provider must be a map of model ids',
        );
      }
      if (providerEntry.value is! YamlMap) {
        throw ConfigException(
          'models.overrides.$provider must be a map of model ids, got: '
          '${providerEntry.value.runtimeType}',
        );
      }
      for (final modelEntry in (providerEntry.value as YamlMap).entries) {
        final modelId = modelEntry.key;
        if (modelId is! String || modelId.trim().isEmpty) {
          throw ConfigException(
            'models.overrides.$provider model ids must be non-empty '
            'strings, got: $modelId',
          );
        }
        overrides._byProvider.putIfAbsent(
          provider.trim().toLowerCase(),
          () => {},
        )[modelId] = ModelCapabilityOverride.fromYaml(provider, modelId,
            modelEntry.value,);
      }
    }
    return overrides;
  }

  /// True when no override is pinned anywhere.
  bool get isEmpty => _byProvider.isEmpty;

  /// Registers (or replaces) the override for [provider]/[modelId].
  void set(
    String provider,
    String modelId,
    ModelCapabilityOverride override,
  ) {
    _byProvider
        .putIfAbsent(provider.trim().toLowerCase(), () => {})[modelId] =
        override;
  }

  /// Removes the override for [provider]/[modelId]; true when one existed.
  bool remove(String provider, String modelId) =>
      _byProvider[provider.trim().toLowerCase()]?.remove(modelId) ?? false;

  /// The pinned override for [provider]/[modelId], or null. The provider
  /// key is case-insensitive (catalog names are lowercase); the model id
  /// matches verbatim.
  ModelCapabilityOverride? lookup(String provider, String modelId) =>
      _byProvider[provider.trim().toLowerCase()]?[modelId];

  /// Every pinned (provider, modelId, override) triple — the settings
  /// surfaces enumerate these.
  Iterable<({String provider, String modelId, ModelCapabilityOverride caps})>
  get entries => [
    for (final provider in _byProvider.entries)
      for (final model in provider.value.entries)
        (
          provider: provider.key,
          modelId: model.key,
          caps: model.value,
        ),
  ];

  /// Serializes the `overrides:` section body (the per-provider blocks at
  /// the given base indent). Only called when non-empty.
  String toYaml() {
    final buffer = StringBuffer();
    for (final provider in _byProvider.keys) {
      buffer.write('  ${jsonEncode(provider)}:\n');
      for (final model in _byProvider[provider]!.entries) {
        buffer.write('    ${jsonEncode(model.key)}:\n');
        model.value.writeYaml(buffer, '      ');
      }
    }
    return buffer.toString();
  }
}

/// The resolved capability triple plus the compat surfels the adapters
/// consume. Produced by [resolveModelCapabilities]; every consumer (the
/// request build, the ctx meter, compaction thresholds) reads the SAME
/// instance's numbers — one resolver, three consumers (AC2).
final class EffectiveCaps {
  const EffectiveCaps({
    required this.contextWindow,
    required this.maxTokens,
    required this.thinkingLevel,
    required this.maxTokensField,
    required this.omitMaxOutputTokens,
    this.notes = const [],
  });

  /// Effective total context window (the global cap already applied).
  final int contextWindow;

  /// Effective maximum output tokens.
  final int maxTokens;

  /// Effective thinking rung (post-gate; null = no thinking requested).
  final String? thinkingLevel;

  /// The max-output wire field this model family documents
  /// (`max_completion_tokens` / `max_tokens` / `maxOutputTokens`); a
  /// status-surface documentation value — the adapters keep their own
  /// compat detection.
  final String? maxTokensField;

  /// Whether the max-output field must be omitted on the wire (AC7).
  final bool omitMaxOutputTokens;

  /// Loud resolution notes: gate drops (E3), endpoint divergences (E1),
  /// catalog-miss warnings (E4). Hosts render them; the wire never sees
  /// them.
  final List<String> notes;
}

/// The process-wide user override layer. Hosts install the parsed
/// `models.overrides` section once at boot (and re-install after a
/// settings-flow write); null keeps every build path byte-identical to
/// the pre-resolver behavior (REG-1). Same seam shape as
/// `providerFilterEnvOverride` in provider_catalog.dart.
ModelCapabilityOverrides? modelCapabilityOverrides;

/// The layered resolution (gh-1426 AC1). Pure: every layer is an explicit
/// argument, no IO. See the library docs for the precedence contract.
EffectiveCaps resolveModelCapabilities({
  required String provider,
  required String modelId,
  ModelCapabilityOverride? override,
  String? roleThinkingLevel,
  int? roleContextWindow,
  int? roleMaxTokens,
  int? endpointContextWindow,
  int? endpointMaxTokens,
  ProviderSpec? spec,
  int? remoteCatalogContextWindow,
  String? api,
  bool reasoning = true,
  int? contextWindowCap,
}) {
  final notes = <String>[];

  // ── context window: override > role slot > endpoint > remote catalog >
  //    spec > documented unknown default, then the global cap LAST.
  final resolvedWindow =
      override?.contextWindow ??
      roleContextWindow ??
      endpointContextWindow ??
      remoteCatalogContextWindow ??
      spec?.contextWindow ??
      unknownModelContextWindow;
  if (override?.contextWindow != null &&
      endpointContextWindow != null &&
      endpointContextWindow != override!.contextWindow) {
    notes.add(
      'capability override wins over the endpoint report for '
      '$provider/$modelId contextWindow: ${override.contextWindow} '
      '(endpoint reported $endpointContextWindow)',
    );
  }
  // Floor the safety net (parse already rejects small values loudly).
  final flooredWindow = resolvedWindow < minOverrideContextWindow
      ? minOverrideContextWindow
      : resolvedWindow;
  final window = effectiveContextWindow(flooredWindow, contextWindowCap);

  // ── max output tokens: override > role slot > endpoint > Claude
  //    ceiling table > spec > documented unknown default.
  final resolvedMaxTokens =
      override?.maxTokens ??
      roleMaxTokens ??
      endpointMaxTokens ??
      resolveModelMaxOutputTokens(modelId, api: api ?? '') ??
      spec?.maxTokens ??
      unknownModelMaxTokens;
  if (override?.maxTokens != null &&
      endpointMaxTokens != null &&
      endpointMaxTokens != override!.maxTokens) {
    notes.add(
      'capability override wins over the endpoint report for '
      '$provider/$modelId maxTokens: ${override.maxTokens} '
      '(endpoint reported $endpointMaxTokens)',
    );
  }
  final maxTokens = resolvedMaxTokens < minOverrideMaxTokens
      ? minOverrideMaxTokens
      : resolvedMaxTokens;

  // ── thinking: model pin (override) > role slot, then the gate.
  final (thinkingLevel, gateNote) = gateThinkingLevel(
    override?.thinkingLevel ?? roleThinkingLevel,
    reasoning: reasoning,
  );
  if (gateNote != null) notes.add(gateNote);

  // ── E4: an override addressing a model no catalog knows is kept (it
  //    addresses the future), with a surfaced warning.
  if (override != null &&
      spec == null &&
      remoteCatalogContextWindow == null &&
      endpointContextWindow == null) {
    notes.add(
      'capability override for $provider/$modelId has no catalog entry — '
      'documented defaults + the override apply',
    );
  }

  return EffectiveCaps(
    contextWindow: window,
    maxTokens: maxTokens,
    thinkingLevel: thinkingLevel,
    maxTokensField: maxTokensFieldFor(api ?? spec?.api),
    omitMaxOutputTokens: override?.omitMaxOutputTokens ?? false,
    notes: notes,
  );
}

/// The documented max-output wire field for an API dialect (informational;
/// the adapters keep their own compat detection). Unknown dialects get
/// null — nothing to document.
String? maxTokensFieldFor(String? api) => switch (api) {
  'anthropic-messages' => 'max_tokens',
  'google-generative-ai' => 'maxOutputTokens',
  'openai-completions' || 'responses' => 'max_completion_tokens',
  _ => null,
};

/// The thinking gate: a pinned rung on a `reasoning:false` model is
/// dropped WITH a loud note (E3 — the request proceeds without thinking
/// fields; never silently sent). `xhigh`/`max` fold to `high` like
/// everywhere else. Returns `(level, note)`.
(String?, String?) gateThinkingLevel(String? level, {required bool reasoning}) {
  if (level == null) return (null, null);
  final clamped = clampThinkingLevel(level);
  if (!reasoning) {
    return (
      null,
      'thinking level "$clamped" pinned on a non-reasoning model — gated, '
      'the request proceeds without thinking fields',
    );
  }
  return (clamped, null);
}

/// Convenience: the [ModelRef]-shaped role-slot layer (a roles chain
/// entry's own explicit caps), so hosts holding a ref resolve with one
/// call instead of unpacking the three fields.
EffectiveCaps resolveModelRefCapabilities(
  ModelRef ref, {
  ModelCapabilityOverride? override,
  int? endpointContextWindow,
  int? endpointMaxTokens,
  ProviderSpec? spec,
  int? remoteCatalogContextWindow,
  int? contextWindowCap,
  bool? reasoning,
}) {
  return resolveModelCapabilities(
    provider: ref.provider,
    modelId: ref.modelId,
    override: override,
    roleThinkingLevel: ref.thinkingLevel,
    roleContextWindow: ref.contextWindow,
    roleMaxTokens: ref.maxTokens,
    endpointContextWindow: endpointContextWindow,
    endpointMaxTokens: endpointMaxTokens,
    spec: spec,
    remoteCatalogContextWindow: remoteCatalogContextWindow,
    api: spec?.api,
    reasoning: reasoning ?? spec?.reasoning ?? true,
    contextWindowCap: contextWindowCap,
  );
}
