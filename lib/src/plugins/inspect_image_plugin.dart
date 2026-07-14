/// Built-in `inspect_image` plugin for `fah`.
///
/// Registers the [inspectImageTool] when configured with a vision model.
/// Configure via `.fah/packages.yaml`:
///
/// ```yaml
/// inspect_image:
///   model: gpt-4o
///   apiKey: ${VISION_API_KEY}   # or literal key
///   baseUrl: https://api.openai.com/v1   # optional
///   maxTokens: 4096                      # optional
/// ```
library;

import 'package:http/http.dart' as http;

import '../tools/inspect_image.dart';
import 'plugin.dart';

/// Built-in plugin name used in `.fah/packages.yaml` and CLI `--plugin`.
const _pluginName = 'inspect_image';

/// Plugin that contributes the `inspect_image` tool.
final class InspectImagePlugin implements FahPlugin {
  /// Creates the plugin with an optional HTTP client for testing.
  const InspectImagePlugin({this.httpClient});

  /// Optional HTTP client override (tests).
  final http.Client? httpClient;

  @override
  String get name => _pluginName;

  @override
  void register(PluginContext context) {
    final config = context.config;
    final modelId = config['model'] as String?;
    final apiKey = config['apiKey'] as String?;
    if (modelId == null || apiKey == null) {
      // Not configured: skip registration silently.
      return;
    }
    final baseUrl = config['baseUrl'] as String?;
    final maxTokens = (config['maxTokens'] as num?)?.toInt() ?? 4096;
    final visionConfig = InspectImageConfig(
      modelId: modelId,
      apiKey: apiKey,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
      httpClient: httpClient,
    );
    context.registerTool(inspectImageTool(context.env, visionConfig));
  }
}
