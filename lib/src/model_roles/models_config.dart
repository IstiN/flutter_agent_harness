/// The `models:` section of `~/.fah/config.yaml`: per-slot media model
/// overrides (the CLI half of the app's media-models feature) plus named
/// custom model definitions `/model <name>` can switch to.
///
/// ```yaml
/// models:
///   slots:                        # media slot overrides (app slot schema)
///     vision:
///       providerKind: openai-completions
///       baseUrl: https://api.openai.com/v1
///       modelId: gpt-4o
///       apiKeyName: OPENAI_API_KEY  # optional; key NAME, never the value
///   custom:                       # named model definitions (/model <name>)
///     fast:
///       provider: openai            # catalog provider name
///       baseUrl: https://api.openai.com/v1
///       model: gpt-4o-mini
///       contextWindow: 128000       # optional (catalog default otherwise)
///       maxTokens: 4096             # optional
///       input: [text, image]        # optional
/// ```
///
/// Parsed strictly like `roles:`/`ttsr:`: any schema error throws
/// [ConfigException] at startup instead of silently dropping the section.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'package:flutter_sandbox/flutter_sandbox.dart';
import 'media_model_slots.dart';
import 'provider_catalog.dart';

/// A named custom model definition (`models.custom.<name>`): a concrete
/// provider/endpoint/model triple with optional token-limit and modality
/// overrides, switchable at runtime with `/model <name>`.
final class CustomModelDefinition {
  /// Creates a custom model definition.
  const CustomModelDefinition({
    required this.provider,
    required this.baseUrl,
    required this.model,
    this.contextWindow,
    this.maxTokens,
    this.input,
  });

  /// Parses one definition from yaml, strictly: [name] is the map key;
  /// `provider` must be a catalog provider name (see [providerCatalog]),
  /// `baseUrl`/`model` non-empty strings, `contextWindow`/`maxTokens`
  /// positive integers, `input` a non-empty list of `text`/`image`.
  factory CustomModelDefinition.fromYaml(String name, Object? node) {
    final where = 'models.custom.$name';
    if (node is! YamlMap) {
      throw ConfigException(
        '$where must be a map with provider, baseUrl, model',
      );
    }
    const knownFields = [
      'provider',
      'baseUrl',
      'model',
      'contextWindow',
      'maxTokens',
      'input',
    ];
    for (final key in node.keys) {
      if (!knownFields.contains(key)) {
        throw ConfigException(
          'unknown field "$key" in $where — expected '
          '${knownFields.join(', ')}',
        );
      }
    }
    String required(String field) {
      final value = node[field];
      if (value is! String || value.trim().isEmpty) {
        throw ConfigException('$where.$field must be a non-empty string');
      }
      return value.trim();
    }

    final provider = required('provider');
    if (catalogProvider(provider) == null) {
      throw ConfigException(
        'unknown provider "$provider" in $where — supported providers: '
        '${enabledProviderNames().join(', ')}',
      );
    }
    int? optionalInt(String field) {
      final value = node[field];
      if (value == null) return null;
      if (value is! int || value <= 0) {
        throw ConfigException('$where.$field must be a positive integer');
      }
      return value;
    }

    final input = switch (node['input']) {
      null => null,
      final YamlList list when list.isNotEmpty => [
        for (final entry in list)
          switch (entry) {
            'text' || 'image' => entry as String,
            _ => throw ConfigException(
              '$where.input entries must be "text" or "image", got: $entry',
            ),
          },
      ],
      final other => throw ConfigException(
        '$where.input must be a non-empty list of "text"/"image", '
        'got: $other',
      ),
    };
    return CustomModelDefinition(
      provider: provider,
      baseUrl: required('baseUrl'),
      model: required('model'),
      contextWindow: optionalInt('contextWindow'),
      maxTokens: optionalInt('maxTokens'),
      input: input,
    );
  }

  /// Catalog provider name (`openrouter`, `openai`, `anthropic`, `google`).
  final String provider;

  /// API base URL.
  final String baseUrl;

  /// Model id sent to the provider.
  final String model;

  /// Total context window in tokens (catalog default when null).
  final int? contextWindow;

  /// Maximum output tokens (catalog default when null).
  final int? maxTokens;

  /// Input modalities (`text`/`image`; catalog default when null).
  final List<String>? input;

  /// Writes the definition as yaml lines at [indent] (string values are
  /// JSON-quoted — valid yaml scalars that round-trip any url/model id).
  void writeYaml(StringBuffer buffer, String indent) {
    buffer
      ..write('${indent}provider: ${jsonEncode(provider)}\n')
      ..write('${indent}baseUrl: ${jsonEncode(baseUrl)}\n')
      ..write('${indent}model: ${jsonEncode(model)}\n');
    if (contextWindow != null) {
      buffer.write('${indent}contextWindow: $contextWindow\n');
    }
    if (maxTokens != null) buffer.write('${indent}maxTokens: $maxTokens\n');
    final modalities = input;
    if (modalities != null) {
      buffer.write('${indent}input: ${jsonEncode(modalities)}\n');
    }
  }

  @override
  String toString() => 'CustomModelDefinition($provider, $baseUrl, $model)';
}

/// The parsed `models:` section: media slot overrides plus named custom
/// model definitions. Mutable like `CustomProviderRegistry` — the REPL
/// (`/models set`/`/models remove`) updates the live instance and the
/// executable persists it with the usual config save.
final class ModelsConfig {
  /// Creates an empty (or pre-populated) models config.
  ModelsConfig({
    Map<String, MediaSlotModelConfig>? slots,
    Map<String, CustomModelDefinition>? custom,
  }) : slots = slots ?? {},
       custom = custom ?? {};

  /// Parses the `models:` yaml node, strictly: the node must be a map with
  /// only `slots`/`custom` keys; slot names must come from
  /// [mediaModelSlotIds]; entry-level rules are in
  /// [MediaSlotModelConfig.fromYaml] and [CustomModelDefinition.fromYaml].
  factory ModelsConfig.fromYaml(Object? node) {
    if (node is! YamlMap) {
      throw ConfigException(
        'models must be a map with slots/custom sections, got: $node',
      );
    }
    for (final key in node.keys) {
      if (key != 'slots' && key != 'custom') {
        throw ConfigException(
          'unknown models section "$key" — expected slots/custom',
        );
      }
    }
    final slots = <String, MediaSlotModelConfig>{};
    switch (node['slots']) {
      case null:
        break;
      case final YamlMap map:
        for (final entry in map.entries) {
          final slot = entry.key;
          if (slot is! String || !mediaModelSlotIds.contains(slot)) {
            throw ConfigException(
              'unknown media slot "$slot" in models.slots — slots: '
              '${mediaModelSlotIds.join(', ')}',
            );
          }
          slots[slot] = MediaSlotModelConfig.fromYaml(entry.value, slot: slot);
        }
      case final other:
        throw ConfigException('models.slots must be a map, got: $other');
    }
    final custom = <String, CustomModelDefinition>{};
    switch (node['custom']) {
      case null:
        break;
      case final YamlMap map:
        for (final entry in map.entries) {
          final name = entry.key;
          if (name is! String || name.trim().isEmpty) {
            throw ConfigException(
              'models.custom names must be non-empty strings, got: $name',
            );
          }
          custom[name] = CustomModelDefinition.fromYaml(name, entry.value);
        }
      case final other:
        throw ConfigException('models.custom must be a map, got: $other');
    }
    return ModelsConfig(slots: slots, custom: custom);
  }

  /// Per-slot media overrides, keyed by [mediaModelSlotIds] name.
  final Map<String, MediaSlotModelConfig> slots;

  /// Named custom model definitions (`/model <name>` targets).
  final Map<String, CustomModelDefinition> custom;

  /// True when neither section carries an entry (the config file then
  /// omits the whole `models:` section on save).
  bool get isEmpty => slots.isEmpty && custom.isEmpty;

  /// Sets (or replaces) the override for [slot], which must be one of
  /// [mediaModelSlotIds].
  void setSlotOverride(String slot, MediaSlotModelConfig override) {
    if (!mediaModelSlotIds.contains(slot)) {
      throw ConfigException(
        'unknown media slot "$slot" — slots: ${mediaModelSlotIds.join(', ')}',
      );
    }
    slots[slot] = override;
  }

  /// Removes the override for [slot]; returns false when none was set.
  bool removeSlotOverride(String slot) => slots.remove(slot) != null;

  /// Serializes the `models:` section (only called when non-empty). Slots
  /// emit in [mediaModelSlotIds] declaration order; custom definitions in
  /// insertion order.
  String toYaml() {
    final buffer = StringBuffer('models:\n');
    if (slots.isNotEmpty) {
      buffer.write('  slots:\n');
      for (final slot in mediaModelSlotIds) {
        final override = slots[slot];
        if (override == null) continue;
        buffer.write('    $slot:\n');
        override.writeYaml(buffer, '      ');
      }
    }
    if (custom.isNotEmpty) {
      buffer.write('  custom:\n');
      for (final entry in custom.entries) {
        buffer.write('    ${jsonEncode(entry.key)}:\n');
        entry.value.writeYaml(buffer, '      ');
      }
    }
    return buffer.toString();
  }
}
