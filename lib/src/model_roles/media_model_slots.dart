/// Per-modality media model slots — the schema shared between the Flutter
/// app and the CLI.
///
/// The app persists slot overrides as `media_models.json` (see
/// `flutter_app/lib/services/media_models_store.dart`); the CLI persists
/// them in the `models:` section of `~/.fah/config.yaml` (see
/// [ModelsConfig](models_config.dart)). Both read and write the same slot
/// names and per-slot fields, so those live here exactly once:
///
/// - [mediaModelSlotIds] — the slot names, in declaration order.
/// - [mediaSlotOverrideFields] — the per-slot override fields.
/// - [MediaSlotModelConfig] — one slot override, with strict yaml parsing
///   for the CLI config (the app store keeps its own tolerant JSON form).
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Every known media slot name, in declaration order.
///
/// Exact app slot names (`MediaSlot.all` in
/// `flutter_app/lib/services/media_models_store.dart` derives from this
/// list): `imageGeneration`, `audioTts`, `musicGeneration`,
/// `videoGeneration`, `vision`, `transcription`.
const mediaModelSlotIds = [
  'imageGeneration',
  'audioTts',
  'musicGeneration',
  'videoGeneration',
  'vision',
  'transcription',
];

/// The fields one media slot override carries (same names in the app's
/// `media_models.json` and the CLI's `models:` yaml section).
///
/// `apiKeyName` is the NAME of an env/secure-store entry holding the API
/// key, never the key itself — key values are never written to config.
const mediaSlotOverrideFields = [
  'providerKind',
  'baseUrl',
  'modelId',
  'apiKeyName',
];

/// One media slot override in the CLI's `models:` config section: where ONE
/// media modality is served when the main connection should not handle it.
///
/// Mirrors the app's `MediaSlotOverride` field-for-field; the media tools
/// speak the OpenAI-compatible wire format, so usable overrides carry
/// `providerKind: openai-completions`.
final class MediaSlotModelConfig {
  /// Creates a slot override. All three required fields should be non-empty
  /// for the override to be usable (enforced by [fromYaml]).
  const MediaSlotModelConfig({
    required this.providerKind,
    required this.baseUrl,
    required this.modelId,
    this.apiKeyName,
  });

  /// Parses one slot entry from yaml, strictly: unknown fields, missing
  /// required strings, and empty values throw [ConfigException] (a bad
  /// `models:` section must surface, never silently vanish).
  factory MediaSlotModelConfig.fromYaml(Object? node, {required String slot}) {
    if (node is! YamlMap) {
      throw ConfigException(
        'models.slots.$slot must be a map with fields '
        '${mediaSlotOverrideFields.join(', ')}',
      );
    }
    for (final key in node.keys) {
      if (!mediaSlotOverrideFields.contains(key)) {
        throw ConfigException(
          'unknown field "$key" in models.slots.$slot — expected '
          '${mediaSlotOverrideFields.join(', ')}',
        );
      }
    }
    String required(String field) {
      final value = node[field];
      if (value is! String || value.trim().isEmpty) {
        throw ConfigException(
          'models.slots.$slot.$field must be a non-empty string',
        );
      }
      return value.trim();
    }

    final apiKeyName = node['apiKeyName'];
    if (apiKeyName != null &&
        (apiKeyName is! String || apiKeyName.trim().isEmpty)) {
      throw ConfigException(
        'models.slots.$slot.apiKeyName must be a non-empty string',
      );
    }
    return MediaSlotModelConfig(
      providerKind: required('providerKind'),
      baseUrl: required('baseUrl'),
      modelId: required('modelId'),
      apiKeyName: (apiKeyName as String?)?.trim(),
    );
  }

  /// Provider adapter kind (`openai-completions` for usable media
  /// endpoints).
  final String providerKind;

  /// OpenAI-compatible base URL the per-modality path is appended to.
  final String baseUrl;

  /// Model id passed to the endpoint (e.g. `gpt-image-1`, `tts-1`).
  final String modelId;

  /// Name of the env/secure-store entry holding the API key for this
  /// endpoint; null reuses the main connection's key.
  final String? apiKeyName;

  /// Writes the override as yaml lines at [indent] (string values are
  /// JSON-quoted — valid yaml scalars that round-trip any url/model id).
  void writeYaml(StringBuffer buffer, String indent) {
    buffer
      ..write('${indent}providerKind: ${jsonEncode(providerKind)}\n')
      ..write('${indent}baseUrl: ${jsonEncode(baseUrl)}\n')
      ..write('${indent}modelId: ${jsonEncode(modelId)}\n');
    final keyName = apiKeyName;
    if (keyName != null) {
      buffer.write('${indent}apiKeyName: ${jsonEncode(keyName)}\n');
    }
  }

  @override
  String toString() =>
      'MediaSlotModelConfig($providerKind, $baseUrl, '
      '$modelId${apiKeyName == null ? '' : ', key: $apiKeyName'})';
}
