/// Vision-image inspection tool (`inspect_image`) for [AgentCli].
///
/// Shaped after the pi extension [pi-inspect-image](https://github.com/TanJeeSchuan/pi-inspect-image):
/// a dedicated vision-capable model analyses a local image and returns a text
/// description. Keeping the image payload out of the main chat context means
/// the primary model does not need vision support — only the derived text
/// enters the conversation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../context.dart';
import '../env/execution_env.dart';
import '../event_stream.dart';
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../providers/openai_completions.dart';
import '../types.dart';

/// Configuration for the [inspectImageTool] vision model.
final class InspectImageConfig {
  /// Creates a configuration.
  const InspectImageConfig({
    required this.modelId,
    required this.apiKey,
    this.baseUrl,
    this.maxTokens = 4096,
    this.providerKind = 'openai-completions',
    this.httpClient,
  });

  /// Vision model id, e.g. `gpt-4o` or `openai/gpt-4o`.
  final String modelId;

  /// API key for the vision provider.
  final String apiKey;

  /// Optional base URL. When omitted the provider's default is used
  /// (OpenAI: https://api.openai.com/v1, OpenRouter: https://openrouter.ai/api/v1).
  final String? baseUrl;

  /// Maximum tokens for the vision description.
  final int maxTokens;

  /// Provider adapter kind. Only `openai-completions` is supported today;
  /// this covers OpenAI, OpenRouter, and any OpenAI-compatible endpoint.
  final String providerKind;

  /// Optional HTTP client for testing.
  final http.Client? httpClient;
}

/// Builds the [Model] descriptor used for the vision call.
Model _visionModel(InspectImageConfig config) {
  final baseUrl =
      config.baseUrl ??
      switch (config.providerKind) {
        'openai-completions' => 'https://api.openai.com/v1',
        _ => 'https://api.openai.com/v1',
      };
  return Model(
    id: config.modelId,
    name: config.modelId,
    api: 'openai-completions',
    provider: config.providerKind,
    baseUrl: baseUrl,
    input: const ['text', 'image'],
    contextWindow: 128000,
    maxTokens: config.maxTokens,
  );
}

/// Streams a vision request and returns the final assistant text.
Future<String> _inspectWithVisionModel(
  InspectImageConfig config,
  Uint8List bytes,
  String mimeType,
  String userPrompt,
) async {
  final model = _visionModel(config);
  final image = ImageContent(data: base64Encode(bytes), mimeType: mimeType);
  final context = Context(
    systemPrompt: inspectImageVisionSystemPrompt,
    messages: [
      UserMessage(
        content: [
          TextContent(
            text: userPrompt.isEmpty ? 'Describe this image.' : userPrompt,
          ),
          image,
        ],
        timestamp: DateTime.now(),
      ),
    ],
  );

  final AssistantMessageEventStream stream;
  switch (config.providerKind) {
    case 'openai-completions':
      stream = streamOpenAICompletions(
        model,
        context,
        OpenAICompletionsOptions(
          apiKey: config.apiKey,
          maxTokens: config.maxTokens,
        ),
        config.httpClient,
      );
    default:
      throw StateError(
        'Unsupported inspect_image provider kind: ${config.providerKind}',
      );
  }

  String? text;
  String? error;
  await for (final event in stream) {
    if (event is TextDeltaEvent || event is DoneEvent) {
      final message = event.partial;
      final currentText = message.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      if (currentText.isNotEmpty) text = currentText;
    } else if (event is ErrorEvent) {
      error = event.error.errorMessage ?? 'unknown error';
    }
  }

  if (error != null) {
    throw StateError('Vision model error: $error');
  }
  return text?.trim() ?? '';
}

/// Creates the `inspect_image` tool.
///
/// Parameters:
/// - `path` (string, required): path to the image file.
/// - `prompt` (string, optional): specific question or instructions.
AgentTool inspectImageTool(ExecutionEnv env, InspectImageConfig config) {
  return AgentTool(
    name: 'inspect_image',
    label: 'inspect_image',
    description:
        'Analyze a local image file using a dedicated vision-capable model. '
        'Returns a text description; the image itself does not enter the main '
        'chat context. Supported formats: PNG, JPEG, GIF, WebP, BMP.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the image file (relative or absolute)',
        },
        'prompt': {
          'type': 'string',
          'description': 'Optional specific question or instructions',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String;
      final prompt = (arguments['prompt'] as String?) ?? '';

      final read = await env.readBinaryFile(path);
      if (read.isErr) {
        throw StateError('${read.errorOrNull}');
      }
      final bytes = read.valueOrNull!;
      cancelToken?.throwIfCancelled();

      // Detect MIME type from magic bytes. Only the supported image formats
      // are accepted; the actual vision request will re-encode/rescale if
      // needed on the provider side.
      final mimeType = _detectImageMimeType(bytes);
      if (mimeType == null) {
        throw StateError('Unsupported image format or not an image: $path');
      }

      final description = await _inspectWithVisionModel(
        config,
        bytes,
        mimeType,
        prompt,
      );
      return ToolExecutionResult(content: [TextContent(text: description)]);
    },
  );
}

/// Minimal MIME detection for the image formats the tool claims to support.
String? _detectImageMimeType(Uint8List bytes) {
  if (bytes.length < 8) return null;
  if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'image/png';
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes[0] == 0x52 && bytes[1] == 0x49) return 'image/webp'; // RIFF
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'image/bmp';
  return null;
}
