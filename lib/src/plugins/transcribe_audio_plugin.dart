/// Built-in `transcribe_audio` plugin for `fah`.
///
/// Registers the [transcribeAudioTool] when configured with a transcription
/// endpoint. Configure via `.fah/packages.yaml`:
///
/// ```yaml
/// transcribe_audio:
///   model: whisper-1           # optional, default whisper-1
///   apiKey: ${TRANSCRIBE_API_KEY}   # or literal key
///   baseUrl: https://api.openai.com/v1   # optional
///   language: en                        # optional
///   responseFormat: verbose             # text|json|verbose (default json)
///   granularities: [segment, word]      # verbose timestamps
///   require: none                       # none|segment|word
///   prompt: artist names, track list    # vocabulary hint
///   output: auto                        # inline|sidecar|auto
///   maxInlineBytes: 20000               # inline budget for auto
///   providerKind: openai                # openai|groq|custom
/// ```
///
/// Unknown keys fail loudly (same strictness as
/// `MediaSlotModelConfig.fromYaml`) — a typo must not silently disable the
/// knob it meant to set.
library;

import 'package:http/http.dart' as http;

import '../tools/transcribe_audio.dart';
import 'plugin.dart';

/// Built-in plugin name used in `.fah/packages.yaml` and CLI `--plugin`.
const _pluginName = 'transcribe_audio';

/// Every yaml key the transcribe_audio section accepts.
const _allowedKeys = {
  'model',
  'apiKey',
  'baseUrl',
  'language',
  'responseFormat',
  'granularities',
  'require',
  'prompt',
  'output',
  'maxInlineBytes',
  'providerKind',
};

TranscriptionResponseFormat _parseResponseFormat(Object? value) {
  if (value is! String) {
    throw ArgumentError(
      'transcribe_audio: responseFormat must be a string '
      '(text|json|verbose), got: $value',
    );
  }
  switch (value) {
    case 'text':
      return TranscriptionResponseFormat.text;
    case 'json':
      return TranscriptionResponseFormat.json;
    case 'verbose':
      return TranscriptionResponseFormat.verbose;
    default:
      throw ArgumentError(
        'transcribe_audio: unknown responseFormat "$value" '
        '(allowed: text, json, verbose)',
      );
  }
}

Set<TranscriptionGranularity> _parseGranularities(Object? value) {
  if (value is! List) {
    throw ArgumentError(
      'transcribe_audio: granularities must be a list '
      '(e.g. [segment, word]), got: $value',
    );
  }
  return {
    for (final entry in value)
      switch (entry) {
        'segment' => TranscriptionGranularity.segment,
        'word' => TranscriptionGranularity.word,
        _ => throw ArgumentError(
          'transcribe_audio: unknown granularity "$entry" '
          '(allowed: segment, word)',
        ),
      },
  };
}

TranscriptionRequirement _parseRequire(Object? value) {
  if (value is! String) {
    throw ArgumentError(
      'transcribe_audio: require must be a string '
      '(none|segment|word), got: $value',
    );
  }
  switch (value) {
    case 'none':
      return TranscriptionRequirement.none;
    case 'segment':
      return TranscriptionRequirement.segment;
    case 'word':
      return TranscriptionRequirement.word;
    default:
      throw ArgumentError(
        'transcribe_audio: unknown require "$value" '
        '(allowed: none, segment, word)',
      );
  }
}

TranscriptionOutputMode _parseOutput(Object? value) {
  if (value is! String) {
    throw ArgumentError(
      'transcribe_audio: output must be a string '
      '(inline|sidecar|auto), got: $value',
    );
  }
  switch (value) {
    case 'inline':
      return TranscriptionOutputMode.inline;
    case 'sidecar':
      return TranscriptionOutputMode.sidecar;
    case 'auto':
      return TranscriptionOutputMode.auto;
    default:
      throw ArgumentError(
        'transcribe_audio: unknown output "$value" '
        '(allowed: inline, sidecar, auto)',
      );
  }
}

TranscriptionProviderKind _parseProviderKind(Object? value) {
  if (value is! String) {
    throw ArgumentError(
      'transcribe_audio: providerKind must be a string '
      '(openai|groq|custom), got: $value',
    );
  }
  switch (value) {
    case 'openai':
      return TranscriptionProviderKind.openai;
    case 'groq':
      return TranscriptionProviderKind.groq;
    case 'custom':
      return TranscriptionProviderKind.custom;
    default:
      throw ArgumentError(
        'transcribe_audio: unknown providerKind "$value" '
        '(allowed: openai, groq, custom)',
      );
  }
}

/// Plugin that contributes the `transcribe_audio` tool.
final class TranscribeAudioPlugin implements FahPlugin {
  /// Creates the plugin with an optional HTTP client for testing.
  const TranscribeAudioPlugin({this.httpClient});

  /// Optional HTTP client override (tests).
  final http.Client? httpClient;

  @override
  String get name => _pluginName;

  @override
  void register(PluginContext context) {
    final config = context.config;
    final unknown = config.keys.toSet().difference(_allowedKeys);
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'transcribe_audio: unknown config key(s) ${unknown.toList()..sort()} '
        '(allowed: ${_allowedKeys.toList()..sort()})',
      );
    }
    final apiKey = config['apiKey'] as String?;
    if (apiKey == null) {
      // Not configured: skip registration silently.
      return;
    }
    final responseFormat = config.containsKey('responseFormat')
        ? _parseResponseFormat(config['responseFormat'])
        : TranscriptionResponseFormat.json;
    final granularities = config.containsKey('granularities')
        ? _parseGranularities(config['granularities'])
        : const <TranscriptionGranularity>{};
    final require = config.containsKey('require')
        ? _parseRequire(config['require'])
        : TranscriptionRequirement.none;
    final maxInlineBytes = config.containsKey('maxInlineBytes')
        ? config['maxInlineBytes'] as int
        : defaultTranscribeMaxInlineBytes;
    final transcribeConfig = TranscribeAudioConfig(
      modelId: config['model'] as String? ?? 'whisper-1',
      apiKey: apiKey,
      baseUrl: config['baseUrl'] as String?,
      language: config['language'] as String?,
      httpClient: httpClient,
      responseFormat: responseFormat,
      granularities: granularities,
      require: require,
      prompt: config['prompt'] as String?,
      output: config.containsKey('output')
          ? _parseOutput(config['output'])
          : TranscriptionOutputMode.inline,
      maxInlineBytes: maxInlineBytes,
      providerKind: config.containsKey('providerKind')
          ? _parseProviderKind(config['providerKind'])
          : null,
    );
    context.registerTool(transcribeAudioTool(context.env, transcribeConfig));
  }
}
