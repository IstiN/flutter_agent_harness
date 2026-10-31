/// Vision-image inspection tool (`inspect_image`) for [AgentCli].
///
/// Shaped after the pi extension [pi-inspect-image](https://github.com/TanJeeSchuan/pi-inspect-image):
/// a dedicated vision-capable model analyses a local image and returns a text
/// description. Keeping the image payload out of the main chat context means
/// the primary model does not need vision support — only the derived text
/// enters the conversation.
///
/// gh-1985 C2/C3: the tool takes `paths` (1–8 images) alongside the original
/// single `path`. A model that accepts image parts rides the ARRAY in one
/// call (per-image description, or `compare` framing when a question is
/// given); a single-image-only model (or an explicit `stitch: true`) gets a
/// PROGRAMMATIC STITCH instead — the images tile into one labeled composite
/// (`inspect_image_stitch.dart`) and the result note maps tiles back to
/// paths. Every call honors the shared resize ladder by default
/// (`image_pipeline.dart`); `resize: "original"` keeps the original bytes
/// for that call, best-effort within the per-request byte budget.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' show ImageFormat;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../agent/image_registry.dart' show imageRegistryConfig;
import '../approval/approval.dart';
import '../cancel_token.dart' show CancelToken;
import '../context.dart';
import '../env/execution_env.dart';
import '../event_stream.dart';
import '../exceptions.dart' show ToolValidationException;
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../providers/copilot.dart';
import '../providers/copilot_oauth.dart';
import '../providers/openai_completions.dart';
import '../providers/provider_common.dart' show textOnlyImageDropNotice;
import '../types.dart';
import 'image_pipeline.dart';
import 'inspect_image_stitch.dart';

/// The named refusal for the Codex kind (gh-760): the Responses adapter
/// has no vision wire. One constant so the two refuse sites (default
/// endpoint pick and the explicit-baseUrl stream route) cannot drift.
StateError _codexVisionRefusal() => StateError(
  'inspect_image: provider kind "chatgpt-codex" (ChatGPT Codex) has no '
  'vision adapter — configure inspect_image with an openai-completions '
  'or copilot vision model',
);

/// The multi-image cap: `paths` accepts at most this many files per call
/// (the stitch layout caps at the same number).
const inspectImageMaxPaths = stitchMaxTiles;

/// Default number of image parts one vision-model call may carry — the
/// array-routing threshold (gh-1985 C2). OpenAI-compatible vision endpoints
/// accept multiple `image_url` parts; hosts serving a single-image-only
/// model set `maxImagesPerCall: 1` and get the programmatic stitch.
const inspectImageDefaultMaxImagesPerCall = 8;

/// Configuration for the [inspectImageTool] vision model.
final class InspectImageConfig {
  /// Creates a configuration.
  const InspectImageConfig({
    required this.modelId,
    required this.apiKey,
    this.baseUrl,
    this.maxTokens = 4096,
    this.providerKind = 'openai-completions',
    this.maxImagesPerCall = inspectImageDefaultMaxImagesPerCall,
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

  /// How many image parts the model+provider accept in ONE call
  /// (gh-1985 C2 routing). Calls with more images (or `stitch: true`) take
  /// the programmatic stitch path instead of the array.
  final int maxImagesPerCall;

  /// Optional HTTP client for testing.
  final http.Client? httpClient;
}

/// Builds the [Model] descriptor used for the vision call. [inputs] are
/// the declared input modalities — the downgrade pre-pass consults them,
/// so a video describe declares `video` (gh-1985 C1).
Model _visionModel(InspectImageConfig config, {List<String>? inputs}) {
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
    input: inputs ?? const ['text', 'image'],
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

/// One vision-model request over prepared media [blocks] (the prompt text
/// first, then the image/video parts), streamed through [config]'s provider
/// kind. Returns the final assistant text. The shared request shape behind
/// the `inspect_image` tool, the read image auto-route (gh-1984 AC2) and
/// the read video route (gh-1985 C1) — all three describe media through the
/// SAME request path.
///
/// [modelInputs] are the input modalities the request's model descriptor
/// declares; the provider downgrade pre-pass strips any block outside them
/// (so a video describe declares `video` or the bytes never reach the
/// wire). Defaults to the image-describe pair.
///
/// [cancelToken] aborts the stream mid-flight (AC6); [onUsage] receives
/// the response's usage so hosts can surface the spend in /cost. Throws
/// on a stream error — callers degrade to their own failure notes.
Future<String> describeMediaWithVisionModel(
  InspectImageConfig config,
  List<ContentBlock> blocks,
  String userPrompt, {
  List<String> modelInputs = const ['text', 'image'],
  CancelToken? cancelToken,
  void Function(Usage usage)? onUsage,
}) async {
  cancelToken?.throwIfCancelled();
  final model = _visionModel(config, inputs: modelInputs);
  final context = Context(
    systemPrompt: inspectImageVisionSystemPrompt,
    messages: [
      UserMessage(
        content: [
          TextContent(
            text: userPrompt.isEmpty ? 'Describe this image.' : userPrompt,
          ),
          ...blocks,
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
}) => describeMediaWithVisionModel(
  config,
  [ImageContent(data: base64Encode(bytes), mimeType: mimeType)],
  userPrompt,
  cancelToken: cancelToken,
  onUsage: onUsage,
);

/// One vision-model request over video [bytes] (gh-1985 C1 — the read
/// route for a video file through the configured media/vision slot). The
/// openai-completions adapter shapes the block as `video_url`; google
/// endpoints inline it. Throws on a stream error — callers degrade to
/// their own honest notes.
Future<String> describeVideoWithVisionModel(
  InspectImageConfig config,
  Uint8List bytes,
  String mimeType,
  String userPrompt, {
  CancelToken? cancelToken,
  void Function(Usage usage)? onUsage,
}) => describeMediaWithVisionModel(
  config,
  [VideoContent(data: base64Encode(bytes), mimeType: mimeType)],
  userPrompt,
  modelInputs: const ['text', 'image', 'video'],
  cancelToken: cancelToken,
  onUsage: onUsage,
);

/// Creates the `inspect_image` tool.
///
/// Parameters:
/// - `path` (string): path to ONE image file (the single-image form).
/// - `paths` (string array, 1–8; a single-element array rides the single-image form): paths to several image files. Exactly one
///   of `path`/`paths` must be given.
/// - `prompt` (string, optional): specific question or instructions. With
///   several `paths` and a question the request takes the compare framing.
/// - `stitch` (boolean, optional): force the programmatic stitch (one
///   composite image, tiles labeled A/B/C…) even when the model accepts
///   arrays — deterministic tile layout for coordinate/compare questions.
/// - `resize` (string, optional): `"original"` keeps the original bytes for
///   this call (best-effort within the per-request byte budget — an
///   over-budget original downscales minimally and the note names the
///   applied size). Default: the configured resize ladder.
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
        'Analyze local image file(s) using a dedicated vision-capable model. '
        'Returns a text description; the image(s) do not enter the main chat '
        'context. Supported formats: PNG, JPEG, GIF, WebP, BMP.\n'
        'Pass exactly ONE of:\n'
        '- `path` — a single image file; or\n'
        '- `paths` — an array of 1-$inspectImageMaxPaths image files '
        '(a single-element array is the single-image form). '
        'Array-capable models receive all images in one call (per-image '
        'description, or a comparison when `prompt` asks one). Models that '
        'take a single image get the images programmatically stitched into '
        'one composite with tiles labeled A/B/C… (top-left corner); the '
        'result note maps the letters back to the source paths.\n'
        '`stitch: true` forces the stitched-composite route even on '
        'array-capable models — deterministic tile layout for precise '
        'coordinate/compare questions ("compare tile positions A and C"), '
        'consistent crops, and a cheaper single-image payload. It needs at '
        'least 2 paths.\n'
        'Resize: by default the configured resize ladder applies '
        '(max-size downscale, format conversion, per-request byte budget). '
        '`resize: "original"` keeps the original bytes for this call, '
        'best-effort: an original over the byte budget downscales minimally '
        'and the result note names the applied size. `resize` does not '
        'apply to the stitched composite — a stitch call always re-encodes '
        'its tiles, so byte fidelity only holds on the array/single route.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the image file (relative or absolute). '
              'Exactly one of path/paths.',
        },
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Paths to 1-$inspectImageMaxPaths image files to '
              'inspect together (array models get every image; single-image '
              'models get a stitched composite with tiles labeled A/B/C…). '
              'Exactly one of path/paths.',
        },
        'prompt': {
          'type': 'string',
          'description': 'Optional specific question or instructions',
        },
        'stitch': {
          'type': 'boolean',
          'description': 'Force the stitched-composite route even when the '
              'model accepts image arrays (needs ≥2 paths). Deterministic '
              'tile layout for coordinate/compare questions.',
        },
        'resize': {
          'type': 'string',
          'enum': ['original'],
          'description': '"original" keeps the original bytes for this call '
              'within the per-request byte budget (an over-budget original '
              'downscales minimally; the note names the applied size). '
              'Default: the configured resize ladder.',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final (:paths, :requestedCount) = _resolveInspectPaths(arguments);
      final prompt = (arguments['prompt'] as String?) ?? '';
      final stitchRequested = (arguments['stitch'] as bool?) ?? false;
      final keepOriginal = (arguments['resize'] as String?) == 'original';
      if (stitchRequested && paths.length < 2) {
        throw const ToolValidationException(
          'inspect_image',
          'stitch: true needs at least 2 paths (it tiles a multi-image '
          'composite). Pass `paths` with 2-$inspectImageMaxPaths images, or '
          'drop `stitch` to inspect a single image.',
        );
      }

      final media = await _prepareInspectMedia(
        env,
        paths,
        requestedCount,
        cancelToken,
        keepOriginal: keepOriginal,
      );
      if (stitchRequested || media.images.length > config.maxImagesPerCall) {
        return _stitchedInspectResult(
          config,
          media,
          prompt,
          cancelToken: cancelToken,
          onUsage: onUsage,
        );
      }
      if (media.images.length == 1) {
        // Single-image form — the gh-1984 shape: one call, one image part.
        final description = await describeMediaWithVisionModel(
          config,
          media.images,
          prompt,
          cancelToken: cancelToken,
          onUsage: onUsage,
        );
        return ToolExecutionResult(
          content: [TextContent(text: media.preparedNote + description)],
        );
      }
      // Array routing (AC3): ONE model call carrying every image part; a
      // question rides the compare framing, no question the per-image one.
      final userPrompt = prompt.isEmpty
          ? _perImagePrompt(media.sourcePaths)
          : _comparePrompt(media.sourcePaths, prompt);
      final description = await describeMediaWithVisionModel(
        config,
        media.images,
        userPrompt,
        cancelToken: cancelToken,
        onUsage: onUsage,
      );
      return ToolExecutionResult(
        content: [TextContent(text: media.preparedNote + description)],
      );
    },
  );
}

/// The resolved argument shape: exactly one of `path`/`paths`, capped at
/// [inspectImageMaxPaths] (`requestedCount` carries the pre-cap count for
/// the cap notice). A violation throws the schema-error type.
({List<String> paths, int requestedCount}) _resolveInspectPaths(
  Map<String, dynamic> arguments,
) {
  final path = arguments['path'] as String?;
  final paths = arguments['paths'];
  if (path != null && paths != null) {
    throw const ToolValidationException(
      'inspect_image',
      'Pass exactly one of `path` (single image) or `paths` (array of '
      '1-$inspectImageMaxPaths images) — not both.',
    );
  }
  if (path != null && path.isNotEmpty) {
    return (paths: [path], requestedCount: 1);
  }
  if (paths is List && paths.isNotEmpty) {
    // gh-2007 review thread 5: every element must be a path STRING — junk
    // members are refused explicitly (the schema-error style of the
    // path+paths / empty-array checks above), never silently filtered out.
    final allStrings = paths.every((element) => element is String);
    if (!allStrings) {
      throw const ToolValidationException(
        'inspect_image',
        '`paths` must be an array of image path strings — every element '
        'must be a string.',
      );
    }
    final list = paths.cast<String>().toList();
    return (
      paths: list.sublist(0, list.length.clamp(0, inspectImageMaxPaths)),
      requestedCount: list.length,
    );
  }
  throw const ToolValidationException(
    'inspect_image',
    'inspect_image needs `path` (a single image file) or `paths` (an array '
    'of 1-$inspectImageMaxPaths image files). A single-element `paths` rides '
    'the single-image form.',
  );
}

/// The per-image prompt for an array call with no question (gh-1985 C2:
/// "per-image description" semantics — the model knows the ride order).
String _perImagePrompt(List<String> paths) {
  final buffer = StringBuffer(
    'Describe each image separately, in the order they are attached '
    '(label each description with the file name):\n',
  );
  for (var i = 0; i < paths.length; i++) {
    buffer.writeln('${i + 1}. ${paths[i]}');
  }
  return buffer.toString().trim();
}

/// The compare prompt for an array call with a question (gh-1985 C2:
/// "`compare` framing when several paths + a question are given").
String _comparePrompt(List<String> paths, String prompt) {
  final buffer = StringBuffer(
    'Compare the ${paths.length} attached images and answer the question. '
    'They ride in this order:\n',
  );
  for (var i = 0; i < paths.length; i++) {
    buffer.writeln('${i + 1}. ${paths[i]}');
  }
  buffer.write('\nQuestion: $prompt');
  return buffer.toString();
}

/// The stitched route (gh-1985 C2/AC4/AC5b): tile the prepared images into
/// the labeled composite, then ONE model call with the single composite
/// image; the result text carries the tile→path map note.
Future<ToolExecutionResult> _stitchedInspectResult(
  InspectImageConfig config,
  _PreparedMedia media,
  String prompt, {
  required CancelToken? cancelToken,
  required void Function(Usage usage)? onUsage,
}) async {
  final sourcePaths = media.sourcePaths;
  final userPrompt = StringBuffer(
    'The attached image is a stitched composite of ${sourcePaths.length} '
    'source images. Each tile is labeled with its letter (A, B, C, …) in '
    'the tile\'s top-left corner. The tiles ride in this order:\n',
  );
  for (var i = 0; i < sourcePaths.length; i++) {
    userPrompt.writeln('${stitchTileLabels[i]} = ${sourcePaths[i]}');
  }
  userPrompt.write(
    prompt.isEmpty
        ? 'Describe each tile, citing its letter.'
        : 'Answer the question, citing tile letters.\nQuestion: $prompt',
  );
  final tiles = [
    for (final image in media.images)
      decodeImageOriented(base64Decode(image.data)),
  ];
  final compositeBytes = stitchTiles(tiles);
  // The composite rides the budget ladder like any single image (a huge
  // stitch shrinks before the call).
  final budget = imageRegistryConfig.maxBytesPerRequest;
  final payload = base64Length(compositeBytes) >= budget
      ? processImage(compositeBytes, ImageFormat.png, maxBase64Bytes: budget)
      : null;
  final String base64;
  final String mimeType;
  if (payload != null) {
    base64 = payload.base64;
    mimeType = payload.mimeType;
  } else {
    base64 = base64Encode(compositeBytes);
    mimeType = 'image/png';
  }
  final description = await describeMediaWithVisionModel(
    config,
    [ImageContent(data: base64, mimeType: mimeType)],
    userPrompt.toString(),
    cancelToken: cancelToken,
    onUsage: onUsage,
  );
  return ToolExecutionResult(
    content: [
      TextContent(
        text:
            '${media.preparedNote}${stitchTileMapNote(sourcePaths)}\n'
            '$description',
      ),
    ],
  );
}

/// Reads + prepares the media payloads for one `inspect_image` call:
/// per-image resize (the settings ladder by default, keep-original on
/// request), then the per-request byte budget over the set (AC7 — over
/// budget the trailing images drop, never the first, and the drop fires
/// the drop-notice seam + a result note).
Future<_PreparedMedia> _prepareInspectMedia(
  ExecutionEnv env,
  List<String> paths,
  int requestedCount,
  CancelToken? cancelToken, {
  required bool keepOriginal,
}) async {
  final images = <ImageContent>[];
  final notes = <String>[];
  var base64Total = 0;
  var dropped = 0;
  final budget = imageRegistryConfig.maxBytesPerRequest;
  for (final path in paths) {
    final processed = await _readAndProcessInspectImage(
      env,
      path,
      cancelToken,
      keepOriginal: keepOriginal,
      budget: budget,
    );
    final payloadLength = processed.base64.length;
    if (base64Total + payloadLength > budget && images.isNotEmpty) {
      // The per-request byte budget binds: drop the trailing image(s) —
      // never the first (the call must stay answerable).
      dropped++;
      continue;
    }
    base64Total += payloadLength;
    images.add(
      ImageContent(data: processed.base64, mimeType: processed.mimeType),
    );
    if (keepOriginal && processed.resized) {
      notes.add(
        '[${_fileName(path)}: resized to ${processed.outputWidth}x'
        '${processed.outputHeight} — the original exceeds '
        'images.maxBytesPerRequest ($budget bytes).]',
      );
    }
  }
  if (dropped > 0) {
    textOnlyImageDropNotice?.call(dropped);
    notes.add(
      '[$dropped image(s) omitted: the batch exceeds '
      'images.maxBytesPerRequest ($budget bytes).]',
    );
  }
  if (requestedCount > inspectImageMaxPaths) {
    notes.insert(0, _cappedPathsNote(requestedCount));
  }
  if (images.isEmpty) {
    throw StateError(
      'inspect_image: every image exceeded images.maxBytesPerRequest '
      '($budget bytes) — lower the budget or shrink the files',
    );
  }
  return _PreparedMedia(
    images: images,
    sourcePaths: paths.sublist(0, images.length),
    preparedNote: notes.isEmpty ? '' : '${notes.join('\n')}\n',
    droppedCount: dropped,
  );
}

/// Reads + decodes + processes ONE inspect path: the read and format
/// checks throw (the caller's schema-error style — "Unsupported image
/// format" names the path); [keepOriginal] picks the decode pipeline
/// ([keepOriginalImage] vs [processImage]). The caller owns the AC7
/// budget math over the returned payload.
Future<InlineImageResult> _readAndProcessInspectImage(
  ExecutionEnv env,
  String path,
  CancelToken? cancelToken, {
  required bool keepOriginal,
  required int budget,
}) async {
  final read = await env.readBinaryFile(path);
  if (read.isErr) {
    throw StateError('${read.errorOrNull}');
  }
  final bytes = read.valueOrNull!;
  cancelToken?.throwIfCancelled();
  final format = detectImageFormat(bytes);
  if (format == null || !supportedImageFormats.contains(format)) {
    throw StateError('Unsupported image format or not an image: $path');
  }
  return keepOriginal
      ? keepOriginalImage(bytes, format, maxBase64Bytes: budget)
      : processImage(bytes, format, maxBase64Bytes: budget);
}

/// The cap notice for an 8+ paths call.
String _cappedPathsNote(int requestedCount) =>
    '[$requestedCount paths requested — capped at $inspectImageMaxPaths '
    '(the per-call limit).]';

/// The file-name part of a resize note (the note names WHICH image shrank).
String _fileName(String path) {
  final slash = path.replaceAll('\\', '/').lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// The prepared media of one call: the image parts in ride order, the
/// source paths they map to, and any notes the preparation added.
final class _PreparedMedia {
  const _PreparedMedia({
    required this.images,
    required this.sourcePaths,
    required this.preparedNote,
    required this.droppedCount,
  });

  /// The image parts riding the call (array or single composite).
  final List<ImageContent> images;

  /// The source paths of the PREPARED images, ride order — index i maps to
  /// [stitchTileLabels][i] in the stitch route and to list item i+1 in the
  /// array prompts.
  final List<String> sourcePaths;

  /// Notes prepended to the result text (cap notice, resize notes, budget
  /// drops) — empty string when none.
  final String preparedNote;

  /// Images dropped by the per-request byte budget.
  final int droppedCount;
}
