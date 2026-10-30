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
import '../approval/approval.dart';
import '../cancel_token.dart' show CancelToken;
import '../context.dart';
import '../env/execution_env.dart';
import '../event_stream.dart';
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../providers/copilot.dart';
import '../providers/copilot_oauth.dart';
import '../providers/openai_completions.dart';
import '../types.dart';

/// The named refusal for the Codex kind (gh-760): the Responses adapter
/// has no vision wire. One constant so the two refuse sites (default
/// endpoint pick and the explicit-baseUrl stream route) cannot drift.
StateError _codexVisionRefusal() => StateError(
  'inspect_image: provider kind "chatgpt-codex" (ChatGPT Codex) has no '
  'vision adapter — configure inspect_image with an openai-completions '
  'or copilot vision model',
);

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
  /// (OpenAI: https://api.openai.com/v1, Copilot:
  /// https://api.githubcopilot.com).
  final String? baseUrl;

  /// Maximum tokens for the vision description.
  final int maxTokens;

  /// Provider adapter kind. `openai-completions` (OpenAI, OpenRouter, and
  /// any OpenAI-compatible endpoint) and `copilot` (GitHub token exchanged
  /// for the short-lived Copilot API token via [streamCopilot]) are
  /// supported today.
  final String providerKind;

  /// Optional HTTP client for testing.
  final http.Client? httpClient;
}

/// Builds the [Model] descriptor used for the vision call.
Model _visionModel(InspectImageConfig config) {
  final baseUrl =
      config.baseUrl ??
      switch (config.providerKind) {
        'copilot' => copilotIndividualBaseUrl,
        // gh-760: the Codex Responses adapter has no vision wire — refuse
        // with a named error instead of silently misrouting the call to
        // api.openai.com via the catch-all below.
        'chatgpt-codex' => throw _codexVisionRefusal(),
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

/// Streams the vision request for [config]'s provider kind. Copilot rides
/// the same SSE completions wire through [streamCopilot] (token exchange +
/// mandatory Copilot headers); every other supported kind speaks plain
/// openai-completions.
AssistantMessageEventStream _streamVisionResponse(
  InspectImageConfig config,
  Model model,
  Context context,
) {
  switch (config.providerKind) {
    case 'openai-completions':
      return streamOpenAICompletions(
        model,
        context,
        OpenAICompletionsOptions(
          apiKey: config.apiKey,
          maxTokens: config.maxTokens,
        ),
        config.httpClient,
      );
    case 'copilot':
      return streamCopilot(
        model,
        context,
        CopilotOptions(githubToken: config.apiKey),
        config.httpClient,
      );
    case 'chatgpt-codex':
      // Named refusal (gh-760): the Codex Responses adapter has no vision
      // wire; reaching the old `default` here meant the call had already
      // been misrouted to api.openai.com by _visionModel.
      throw _codexVisionRefusal();
    default:
      throw StateError(
        'Unsupported inspect_image provider kind: ${config.providerKind}',
      );
  }
}

/// The vision call's outcome: the final text plus the response usage when
/// the provider reported it (the auto-route forwards it to /cost).
typedef _VisionOutcome = ({String text, Usage? usage});

/// Collects the final assistant text out of a vision event stream; throws
/// on a stream error and aborts on [cancelToken] (gh-1984 AC6).
Future<_VisionOutcome> _collectVisionText(
  AssistantMessageEventStream stream,
  CancelToken? cancelToken,
) async {
  String? text;
  String? error;
  Usage? usage;
  await for (final event in stream) {
    cancelToken?.throwIfCancelled();
    if (event is TextDeltaEvent || event is DoneEvent) {
      final message = event.partial;
      final currentText = message.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      if (currentText.isNotEmpty) text = currentText;
      final messageUsage = message.usage;
      if (messageUsage.totalTokens > 0) {
        usage = messageUsage;
      }
    } else if (event is ErrorEvent) {
      error = event.error.errorMessage ?? 'unknown error';
    }
  }

  if (error != null) {
    throw StateError('Vision model error: $error');
  }
  return (text: text?.trim() ?? '', usage: usage);
}

/// One vision-model request over [bytes]: the system prompt + the image +
/// [userPrompt], streamed through [config]'s provider kind. Returns the
/// final assistant text. Shared by the `inspect_image` tool and the read
/// auto-route (gh-1984 AC2) so both describe images through the SAME
/// request shape.
///
/// [cancelToken] aborts the stream mid-flight (AC6); [onUsage] receives
/// the response's usage so hosts can surface the spend in /cost. Throws
/// on a stream error — callers degrade to their own failure notes.
Future<String> describeImageWithVisionModel(
  InspectImageConfig config,
  Uint8List bytes,
  String mimeType,
  String userPrompt, {
  CancelToken? cancelToken,
  void Function(Usage usage)? onUsage,
}) async {
  cancelToken?.throwIfCancelled();
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

  final stream = _streamVisionResponse(config, model, context);
  final result = await _collectVisionText(stream, cancelToken);
  if (result.usage != null) onUsage?.call(result.usage!);
  return result.text;
}

/// Creates the `inspect_image` tool.
///
/// Parameters:
/// - `path` (string, required): path to the image file.
/// - `prompt` (string, optional): specific question or instructions.
///
/// [onUsage] receives the vision call's response usage (gh-1984 review
/// thread 7) so the tool's spend is as visible in /cost as the read
/// auto-route's; hosts without a sink leave it unset (untracked).
AgentTool inspectImageTool(
  ExecutionEnv env,
  InspectImageConfig config, {
  void Function(Usage usage)? onUsage,
}) {
  return AgentTool(
    name: 'inspect_image',
    label: 'inspect_image',
    tier: ApprovalTier.read,
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

      // The shared vision helper direct (gh-1984 review thread 7): the
      // cancel token aborts a hung vision stream MID-FLIGHT (not only the
      // pre-call checkpoints), and the tool's spend rides onUsage like the
      // auto-route's. The pass-through wrapper that dropped both is gone.
      final description = await describeImageWithVisionModel(
        config,
        bytes,
        mimeType,
        prompt,
        cancelToken: cancelToken,
        onUsage: onUsage,
      );
      return ToolExecutionResult(content: [TextContent(text: description)]);
    },
  );
}

/// Magic-byte signatures of the image formats the tool claims to support,
/// checked in order.
const _imageMagicSignatures = [
  ('image/png', <int>[0x89, 0x50]),
  ('image/jpeg', <int>[0xFF, 0xD8]),
  ('image/gif', <int>[0x47, 0x49, 0x46]),
  ('image/webp', <int>[0x52, 0x49]), // RIFF
  ('image/bmp', <int>[0x42, 0x4D]),
];

/// Whether [bytes] starts with the [magic] signature.
bool _matchesMagicBytes(Uint8List bytes, List<int> magic) {
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

/// Minimal MIME detection for the image formats the tool claims to support.
String? _detectImageMimeType(Uint8List bytes) {
  if (bytes.length < 8) return null;
  for (final (mimeType, magic) in _imageMagicSignatures) {
    if (_matchesMagicBytes(bytes, magic)) return mimeType;
  }
  return null;
}
