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
/// ```
library;

import 'package:http/http.dart' as http;

import '../tools/transcribe_audio.dart';
import 'plugin.dart';

/// Built-in plugin name used in `.fah/packages.yaml` and CLI `--plugin`.
const _pluginName = 'transcribe_audio';

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
    final apiKey = config['apiKey'] as String?;
    if (apiKey == null) {
      // Not configured: skip registration silently.
      return;
    }
    final transcribeConfig = TranscribeAudioConfig(
      modelId: config['model'] as String? ?? 'whisper-1',
      apiKey: apiKey,
      baseUrl: config['baseUrl'] as String?,
      language: config['language'] as String?,
      httpClient: httpClient,
    );
    context.registerTool(transcribeAudioTool(context.env, transcribeConfig));
  }
}
