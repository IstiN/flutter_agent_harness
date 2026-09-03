/// Image generation tool (`generate_image`) for [AgentCli].
///
/// A pure-Dart image-generation client that saves the PNG into the sandbox
/// `generated/` dir. Two dialects are supported:
/// - OpenAI-compatible `POST {base}/images/generations` (`size`,
///   `data[0].b64_json`/`url`) — the default for every endpoint.
/// - MiniMax `POST {base}/image_generation` (`aspect_ratio`, `image-01`,
///   `response_format: base64`, `data.image_base64[]`) — detected by the
///   `minimax` baseUrl marker.
///
/// The image bytes never enter the main chat context — the saved path and a
/// base64-staged [ImageContent] are returned. Web-safe.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'package:flutter_sandbox/flutter_sandbox.dart';
import '../model_roles/models_config.dart';
import '../types.dart';

final Random _mediaNameRandom = Random.secure();

/// The `generate_image` tool name.
const generateImageToolName = 'generate_image';

/// Directory (relative to the env root) where generated files land.
const generatedMediaDir = 'generated';

/// Failure from a media generation call.
final class MediaException implements Exception {
  /// Creates a [MediaException].
  MediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolves a named secret (the slot override's `apiKeyName`) to its value;
/// returns null when the name is unknown.
typedef MediaKeyResolver = Future<String?> Function(String name);

/// The resolved endpoint for a media slot, ready for a request.
final class MediaEndpoint {
  /// Creates an endpoint descriptor.
  const MediaEndpoint({
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
  });

  /// Base URL the per-modality path is appended to.
  final String baseUrl;

  /// Model id sent in the request body.
  final String modelId;

  /// The resolved API key (empty = no usable credential).
  final String apiKey;
}

/// Resolves the `imageGeneration` slot endpoint for the CLI.
///
/// Mirrors the app's `MediaModelsStore.resolve`: a `models.slots.imageGeneration`
/// override wins; otherwise the main connection's endpoint is used. The slot's
/// `apiKeyName` (or the main key) is resolved via [resolveKey].
Future<MediaEndpoint?> resolveImageGenerationEndpoint(
  ModelsConfig? modelsConfig, {
  required String mainBaseUrl,
  required String mainModelId,
  required String mainApiKey,
  MediaKeyResolver? resolveKey,
}) async {
  final override = modelsConfig?.slots['imageGeneration'];
  if (override == null) {
    // No override: fall back to the main connection.
    if (mainBaseUrl.isNotEmpty && mainModelId.isNotEmpty) {
      return MediaEndpoint(
        baseUrl: mainBaseUrl,
        modelId: mainModelId,
        apiKey: mainApiKey,
      );
    }
    return null;
  }
  final key = override.apiKeyName == null
      ? mainApiKey
      : (await resolveKey?.call(override.apiKeyName!)) ?? mainApiKey;
  return MediaEndpoint(
    baseUrl: override.baseUrl,
    modelId: override.modelId,
    apiKey: key,
  );
}

/// One image-generation dialect (its own URL shape, body schema, and
/// response parsing). Adding a provider = one new class + one entry in
/// [imageGenerationDialects]; the dispatcher below never changes.
abstract final class ImageDialect {
  /// Whether this dialect handles [endpoint].
  bool matches(MediaEndpoint endpoint);

  /// Generates an image on the given endpoint.
  Future<({String path, Uint8List bytes, String detail})> generate({
    required ExecutionEnv env,
    required MediaEndpoint endpoint,
    required String prompt,
    String? size,
    String? quality,
    required http.Client client,
  });
}

/// Registered image dialects, in precedence order.
final List<ImageDialect> imageGenerationDialects = [
  MiniMaxImageDialect(),
  OpenAiImageDialect(), // default fallback — must stay last
];

/// OpenAI-compatible image generation (`POST {base}/images/generations`,
/// `size`, `data[0].b64_json`/`url`).
final class OpenAiImageDialect extends ImageDialect {
  @override
  bool matches(MediaEndpoint endpoint) => true; // fallback

  @override
  Future<({String path, Uint8List bytes, String detail})> generate({
    required ExecutionEnv env,
    required MediaEndpoint endpoint,
    required String prompt,
    String? size,
    String? quality,
    required http.Client client,
  }) async {
    final response = await client.post(
      Uri.parse('${endpoint.baseUrl}/images/generations'),
      headers: {
        'Content-Type': 'application/json',
        if (endpoint.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${endpoint.apiKey}',
      },
      body: jsonEncode({
        'model': endpoint.modelId,
        'prompt': prompt,
        'size': ?size,
        'quality': ?quality,
      }),
    );
    if (response.statusCode != 200) {
      throw MediaException(
        'image generation failed: HTTP ${response.statusCode}: '
        '${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final b64 = data['data']?[0]?['b64_json'];
    if (b64 is String) {
      final bytes = base64Decode(b64);
      final path = await _save(env, 'images', 'png', bytes);
      return (path: path, bytes: bytes, detail: 'saved to $path');
    }
    final url = data['data']?[0]?['url'];
    if (url is String) {
      final bytes = await _download(url, client);
      final path = await _save(env, 'images', 'png', bytes);
      return (path: path, bytes: bytes, detail: 'saved to $path');
    }
    throw MediaException('image generation: no image in response');
  }
}

/// MiniMax image generation (`POST {base}/image_generation`,
/// `model: image-01`, `aspect_ratio`, `response_format: base64`).
final class MiniMaxImageDialect extends ImageDialect {
  @override
  bool matches(MediaEndpoint endpoint) => endpoint.baseUrl.contains('minimax');

  /// Maps an OpenAI-style `size` ("1024x1024") to a MiniMax `aspect_ratio`
  /// ("1:1"). Falls back to `1:1` for unknown sizes.
  String _aspectRatio(String? size) {
    if (size == null) return '1:1';
    final parts = size.toLowerCase().split('x');
    if (parts.length == 2) {
      final w = int.tryParse(parts[0]);
      final h = int.tryParse(parts[1]);
      if (w != null && h != null) {
        final gcd = _gcd(w, h);
        return '${w ~/ gcd}:${h ~/ gcd}';
      }
    }
    return '1:1';
  }

  @override
  Future<({String path, Uint8List bytes, String detail})> generate({
    required ExecutionEnv env,
    required MediaEndpoint endpoint,
    required String prompt,
    String? size,
    String? quality,
    required http.Client client,
  }) async {
    final base = endpoint.baseUrl.endsWith('/')
        ? endpoint.baseUrl.substring(0, endpoint.baseUrl.length - 1)
        : endpoint.baseUrl;
    final response = await client.post(
      Uri.parse('$base/image_generation'),
      headers: {
        'Content-Type': 'application/json',
        if (endpoint.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${endpoint.apiKey}',
      },
      body: jsonEncode({
        'model': 'image-01',
        'prompt': prompt,
        'aspect_ratio': _aspectRatio(size),
        'response_format': 'base64',
      }),
    );
    if (response.statusCode != 200) {
      throw MediaException(
        'image generation failed: HTTP ${response.statusCode}: '
        '${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final images = data['data']?['image_base64'];
    if (images is List && images.isNotEmpty && images.first is String) {
      final bytes = base64Decode(images.first as String);
      final path = await _save(env, 'images', 'png', bytes);
      return (path: path, bytes: bytes, detail: 'saved to $path');
    }
    throw MediaException('image generation: no image in MiniMax response');
  }
}

int _gcd(int a, int b) {
  var x = a;
  var y = b;
  while (y != 0) {
    final t = x % y;
    x = y;
    y = t;
  }
  return x;
}

/// Generates an image on the `imageGeneration` endpoint and saves the PNG
/// into [generatedMediaDir]. Returns the saved path, bytes, and detail.
///
/// Dispatches to the first dialect in [imageGenerationDialects] whose
/// `matches(endpoint)` returns true (MiniMax, then OpenAI-compatible).
Future<({String path, Uint8List bytes, String detail})> generateImageBytes({
  required ExecutionEnv env,
  required MediaEndpoint endpoint,
  required String prompt,
  String? size,
  String? quality,
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    for (final dialect in imageGenerationDialects) {
      if (dialect.matches(endpoint)) {
        return await dialect.generate(
          env: env,
          endpoint: endpoint,
          prompt: prompt,
          size: size,
          quality: quality,
          client: client,
        );
      }
    }
    throw MediaException('image generation: no matching dialect');
  } finally {
    client.close();
  }
}

Future<String> _save(
  ExecutionEnv env,
  String prefix,
  String ext,
  Uint8List bytes,
) async {
  final dir = generatedMediaDir;
  final created = await env.createDir(dir, recursive: true);
  if (created.isErr) {
    throw MediaException('failed to create $dir: ${created.errorOrNull}');
  }
  // Milliseconds alone collide when two calls land in the same batch (or
  // two fa processes generate at once) — one would overwrite the other.
  final unique =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      _mediaNameRandom.nextInt(1 << 32).toRadixString(36);
  final name =
      '${prefix}_${DateTime.now().millisecondsSinceEpoch}_$unique.$ext';
  final rel = '$dir/$name';
  final written = await env.writeBinaryFile(rel, bytes);
  if (written.isErr) {
    throw MediaException('failed to write $rel: ${written.errorOrNull}');
  }
  return rel;
}

Future<Uint8List> _download(String url, http.Client client) async {
  final response = await client.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw MediaException('failed to download image: ${response.statusCode}');
  }
  return response.bodyBytes;
}

/// Builds the `generate_image` [AgentTool] for the CLI. The endpoint is
/// resolved lazily per call so a `/models set imageGeneration ...` switch is
/// picked up without a restart.
AgentTool generateImageTool({
  required ExecutionEnv env,
  required ModelsConfig? modelsConfig,
  required String Function() mainBaseUrl,
  required String Function() mainModelId,
  required String Function() mainApiKey,
  MediaKeyResolver? resolveKey,
  http.Client? httpClient,
}) {
  return AgentTool(
    name: generateImageToolName,
    label: generateImageToolName,
    tier: ApprovalTier.write,
    description:
        'Generates an image from a text prompt. Returns a path to the saved '
        'image file. Arguments: prompt (required), size (optional, e.g. '
        '"1024x1024"), quality (optional).',
    parameters: const {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'text prompt describing the image to generate',
        },
        'size': {'type': 'string', 'description': 'image size, e.g. 1024x1024'},
        'quality': {
          'type': 'string',
          'description': 'image quality, e.g. standard or high',
        },
      },
      'required': ['prompt'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final prompt = arguments['prompt'] as String? ?? '';
      final size = arguments['size'] as String?;
      final quality = arguments['quality'] as String?;
      if (prompt.trim().isEmpty) {
        throw MediaException('prompt is required');
      }
      final endpoint = await resolveImageGenerationEndpoint(
        modelsConfig,
        mainBaseUrl: mainBaseUrl(),
        mainModelId: mainModelId(),
        mainApiKey: mainApiKey(),
        resolveKey: resolveKey,
      );
      cancelToken?.throwIfCancelled();
      if (endpoint == null) {
        throw MediaException(
          'no endpoint configured for slot imageGeneration; set one in '
          'models.slots.imageGeneration (~/.fah/config.yaml)',
        );
      }
      final file = await generateImageBytes(
        env: env,
        endpoint: endpoint,
        prompt: prompt,
        size: size,
        quality: quality,
        httpClient: httpClient,
      );
      cancelToken?.throwIfCancelled();
      return ToolExecutionResult(
        content: [
          TextContent(text: 'saved image to ${file.path} (${file.detail})'),
          ImageContent(data: base64Encode(file.bytes), mimeType: 'image/png'),
        ],
      );
    },
  );
}
