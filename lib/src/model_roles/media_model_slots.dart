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
/// `useMainConnection` is the explicit per-slot opt-in to serve the slot
/// from the main connection (default false — without an override the slot
/// is UNCONFIGURED, never silently inherited). `input`/`output` declare
/// the endpoint's modalities for capability checks (e.g. reference images
/// need `input: [text, image]`).
const mediaSlotOverrideFields = [
  'providerKind',
  'baseUrl',
  'modelId',
  'apiKeyName',
  'useMainConnection',
  'input',
  'output',
];

/// One media slot override in the CLI's `models:` config section: where ONE
/// media modality is served when the main connection should not handle it.
///
/// Mirrors the app's `MediaSlotOverride` field-for-field; the media tools
/// speak the OpenAI-compatible wire format, so usable overrides carry
/// `providerKind: openai-completions`.
///
/// gh-1844: with `useMainConnection: true` the slot is served by the main
/// connection EXPLICITLY (its baseUrl, model id, and key) — the user says
/// so per slot; nothing is ever inherited implicitly.
final class MediaSlotModelConfig {
  /// Creates a slot override. [providerKind]/[baseUrl]/[modelId] should be
  /// non-empty for a normal override (enforced by [fromYaml] unless
  /// `useMainConnection` is set); all default to empty for the
  /// main-connection opt-in form.
  const MediaSlotModelConfig({
    this.providerKind = '',
    this.baseUrl = '',
    this.modelId = '',
    this.apiKeyName,
    this.useMainConnection = false,
    this.inputModalities = const [],
    this.outputModalities = const [],
  });

  /// Parses one slot entry from yaml, strictly: unknown fields, missing
  /// required strings, and empty values throw [ConfigException] (a bad
  /// `models:` section must surface, never silently vanish). With
  /// `useMainConnection: true` the endpoint fields are not required (the
  /// main connection supplies them); without it they are, exactly as
  /// before gh-1844.
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
    final useMain = _parseUseMainConnection(node['useMainConnection'], slot);
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
      providerKind: useMain
          ? _optString(node['providerKind'])
          : required('providerKind'),
      baseUrl: useMain ? _optString(node['baseUrl']) : required('baseUrl'),
      modelId: useMain ? _optString(node['modelId']) : required('modelId'),
      apiKeyName: (apiKeyName as String?)?.trim(),
      useMainConnection: useMain,
      inputModalities: _parseModalities(node['input'], slot, 'input'),
      outputModalities: _parseModalities(node['output'], slot, 'output'),
    );
  }

  static String _optString(Object? value) =>
      value is String ? value.trim() : '';

  static bool _parseUseMainConnection(Object? value, String slot) {
    if (value == null) return false;
    if (value is! bool) {
      throw ConfigException(
        'models.slots.$slot.useMainConnection must be a boolean',
      );
    }
    return value;
  }

  static List<String> _parseModalities(
    Object? value,
    String slot,
    String field,
  ) {
    if (value == null) return const [];
    if (value is! YamlList || value.isEmpty) {
      throw ConfigException(
        'models.slots.$slot.$field must be a non-empty list of modality '
        'strings (e.g. [text, image])',
      );
    }
    final result = <String>[];
    for (final entry in value) {
      if (entry is! String || entry.trim().isEmpty) {
        throw ConfigException(
          'models.slots.$slot.$field entries must be non-empty strings',
        );
      }
      result.add(entry.trim());
    }
    return result;
  }

  /// Provider adapter kind (`openai-completions` for usable media
  /// endpoints); empty on the `useMainConnection` opt-in form.
  final String providerKind;

  /// OpenAI-compatible base URL the per-modality path is appended to.
  final String baseUrl;

  /// Model id passed to the endpoint (e.g. `gpt-image-1`, `tts-1`).
  final String modelId;

  /// Name of the env/secure-store entry holding the API key for this
  /// endpoint; null reuses the main connection's key when the override's
  /// baseUrl is on the main connection's host (never across hosts).
  final String? apiKeyName;

  /// Explicit per-slot opt-in (gh-1844): serve this slot from the main
  /// connection. Default false — without an override the slot is
  /// UNCONFIGURED, never silently inherited from the main connection.
  final bool useMainConnection;

  /// Declared input modalities of the endpoint (e.g. `[text, image]`) —
  /// drives capability checks (reference images require `image`). Empty =
  /// undeclared (OpenRouter endpoints may be discovered at call time).
  final List<String> inputModalities;

  /// Declared output modalities of the endpoint (e.g. `[image]`, `[video]`).
  final List<String> outputModalities;

  /// True when this entry is the explicit main-connection opt-in and does
  /// not carry its own endpoint.
  bool get isMainConnectionOptIn => useMainConnection;

  /// Writes the override as yaml lines at [indent] (string values are
  /// JSON-quoted — valid yaml scalars that round-trip any url/model id).
  void writeYaml(StringBuffer buffer, String indent) {
    if (useMainConnection) {
      buffer.write('${indent}useMainConnection: true\n');
      return;
    }
    buffer
      ..write('${indent}providerKind: ${jsonEncode(providerKind)}\n')
      ..write('${indent}baseUrl: ${jsonEncode(baseUrl)}\n')
      ..write('${indent}modelId: ${jsonEncode(modelId)}\n');
    final keyName = apiKeyName;
    if (keyName != null) {
      buffer.write('${indent}apiKeyName: ${jsonEncode(keyName)}\n');
    }
    if (inputModalities.isNotEmpty) {
      buffer.write('${indent}input: ${jsonEncode(inputModalities)}\n');
    }
    if (outputModalities.isNotEmpty) {
      buffer.write('${indent}output: ${jsonEncode(outputModalities)}\n');
    }
  }

  @override
  String toString() =>
      'MediaSlotModelConfig($providerKind, $baseUrl, '
      '$modelId${apiKeyName == null ? '' : ', key: $apiKeyName'})';
}
