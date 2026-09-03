/// Video generation tool (`generate_video`) for [AgentCli].
///
/// A pure-Dart video-generation client that saves the MP4 into the sandbox
/// `generated/` dir. One dialect is supported:
/// - MiniMax `POST {base}/video_generation` (V2, async, `MiniMax-H3`) —
///   detected by the `minimax` baseUrl marker. The endpoint answers a
///   `task_id`; we poll `GET {base}/query/video_generation?task_id=…`
///   until the task succeeds and the video file URL lands, then download.
///
/// Without a MiniMax endpoint the tool refuses the call with a clear
/// diagnostic — the chat endpoint's `/v1/models` never lists video
/// models, so a slot-less pick falls back to the chat endpoint, which
/// can't generate video. Never silently fall back to the chat model.
library;

import 'dart:async';
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

final Random _videoNameRandom = Random.secure();

/// The `generate_video` tool name.
const generateVideoToolName = 'generate_video';

/// Directory (relative to the env root) where generated videos land.
const generatedVideoDir = 'generated';

/// Failure from a video generation call.
final class VideoException implements Exception {
  /// Creates a [VideoException].
  VideoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolves a named secret (the slot override's `apiKeyName`) to its value;
/// returns null when the name is unknown.
typedef VideoKeyResolver = Future<String?> Function(String name);

/// The resolved endpoint for the `videoGeneration` slot, ready for a
/// request.
final class VideoEndpoint {
  /// Creates an endpoint descriptor.
  const VideoEndpoint({
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
  });

  /// Base URL the per-modality path is appended to.
  final String baseUrl;

  /// Model id sent in the request body (`MiniMax-H3`).
  final String modelId;

  /// The resolved API key (empty = no usable credential).
  final String apiKey;
}

/// Resolves the `videoGeneration` slot endpoint for the CLI.
///
/// Mirrors the app's `MediaModelsStore.resolve`: a
/// `models.slots.videoGeneration` override wins; without one the slot
/// is treated as UNCONFIGURED (the main connection is not a fallback —
/// its `/v1/models` never lists video models and the chat endpoint
/// can't generate video).
Future<VideoEndpoint?> resolveVideoGenerationEndpoint(
  ModelsConfig? modelsConfig, {
  VideoKeyResolver? resolveKey,
}) async {
  final override = modelsConfig?.slots['videoGeneration'];
  if (override == null) return null;
  final key = override.apiKeyName == null
      ? ''
      : (await resolveKey?.call(override.apiKeyName!)) ?? '';
  return VideoEndpoint(
    baseUrl: override.baseUrl,
    modelId: override.modelId,
    apiKey: key,
  );
}

/// One video-generation dialect (its own URL shape, body schema, and
/// response handling). Adding a provider = one new class + one entry in
/// [videoGenerationDialects]; the dispatcher below never changes.
abstract final class VideoDialect {
  /// Whether this dialect handles [endpoint].
  bool matches(VideoEndpoint endpoint);

  /// Generates a video on the given endpoint. The implementation
  /// handles any async polling the provider requires and returns the
  /// downloaded MP4 bytes plus the saved path.
  Future<({String path, Uint8List bytes, String detail})> generate({
    required ExecutionEnv env,
    required VideoEndpoint endpoint,
    required String prompt,
    String? size,
    String? quality,
    required http.Client client,
    Future<void> Function()? onPollProgress,
  });
}

/// Registered video dialects, in precedence order — the MOST SPECIFIC
/// matcher first: both MiniMax dialects share the `minimax` baseUrl
/// marker, so the H3 dialect would swallow Hailuo endpoints if listed
/// first.
final List<VideoDialect> videoGenerationDialects = [
  HailuoVideoDialect(), // Hailuo 2.3 async task (V1 endpoint)
  MiniMaxVideoDialect(), // MiniMax H3 async task (V2, default)
];

/// MiniMax video generation (`POST {base}/video_generation`, async,
/// model `MiniMax-H3`). The endpoint returns a `task_id`; we poll
/// `GET {base}/query/video_generation?task_id=…` until it succeeds,
/// then download the returned `file_url`.
final class MiniMaxVideoDialect extends VideoDialect {
  @override
  bool matches(VideoEndpoint endpoint) => endpoint.baseUrl.contains('minimax');

  /// Maps an OpenAI-style `size` ("1920x1080") to a MiniMax `resolution`
  /// ("2K") and `ratio` ("16:9"). Falls back to 2K 16:9 for unknown sizes.
  /// Public for tests.
  ({String resolution, String ratio}) sizeFor(String? size) {
    if (size == null) return (resolution: '2K', ratio: '16:9');
    final parts = size.toLowerCase().split('x');
    if (parts.length == 2) {
      final w = int.tryParse(parts[0]);
      final h = int.tryParse(parts[1]);
      if (w != null && h != null && w > 0 && h > 0) {
        final resolution = w >= 1920 ? '2K' : '1080P';
        final gcd = _gcd(w, h);
        return (resolution: resolution, ratio: '${w ~/ gcd}:${h ~/ gcd}');
      }
    }
    return (resolution: '2K', ratio: '16:9');
  }

  @override
  Future<({String path, Uint8List bytes, String detail})> generate({
    required ExecutionEnv env,
    required VideoEndpoint endpoint,
    required String prompt,
    String? size,
    String? quality,
    required http.Client client,
    Future<void> Function()? onPollProgress,
  }) async {
    final base = _trimSlash(endpoint.baseUrl);
    final (resolution: resolution, ratio: ratio) = sizeFor(size);
    final headers = _minimaxHeaders(endpoint);
    final taskId = await _createTask(
      client,
      base,
      headers,
      endpoint.modelId,
      prompt,
      resolution,
      ratio,
    );
    final fileUrl = await _pollForFileUrl(
      client,
      base,
      headers,
      taskId,
      onPollProgress,
    );
    final bytes = await _downloadVideo(client, fileUrl);
    final path = await _save(env, 'videos', 'mp4', bytes);
    return (path: path, bytes: bytes, detail: 'saved to $path');
  }

  String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  Map<String, String> _minimaxHeaders(VideoEndpoint endpoint) => {
    'Content-Type': 'application/json',
    if (endpoint.apiKey.isNotEmpty)
      'Authorization': 'Bearer ${endpoint.apiKey}',
  };

  Future<String> _createTask(
    http.Client client,
    String base,
    Map<String, String> headers,
    String model,
    String prompt,
    String resolution,
    String ratio,
  ) async {
    final create = await client.post(
      Uri.parse('$base/v2/video_generation'),
      headers: headers,
      body: jsonEncode({
        'model': model,
        'content': [
          {'type': 'text', 'text': prompt},
        ],
        'resolution': resolution,
        'ratio': ratio,
        'duration': 5,
      }),
    );
    if (create.statusCode != 200) {
      throw VideoException(
        'video generation failed: HTTP ${create.statusCode}: ${create.body}',
      );
    }
    final created = jsonDecode(create.body) as Map<String, dynamic>;
    final taskId = created['task_id'] as String?;
    if (taskId == null) {
      throw VideoException(
        'video generation: MiniMax response missing task_id: ${create.body}',
      );
    }
    return taskId;
  }

  Future<String> _pollForFileUrl(
    http.Client client,
    String base,
    Map<String, String> headers,
    String taskId,
    Future<void> Function()? onProgress,
  ) async {
    const maxPolls = 20;
    for (var i = 0; i < maxPolls; i++) {
      final data = await _pollOnce(client, base, headers, taskId);
      final status = data['status'] as String?;
      if (status == 'Success') return _fileUrlFrom(data, taskId);
      _throwIfFailed(data, status, taskId);
      _throwIfCancelled(status, taskId);
      await onProgress?.call();
      // Back off linearly: 3s, 4s, 5s, …, capped at 10s. 20 polls
      // ≈ 2 minutes worst case.
      final delaySeconds = (3 + i).clamp(3, 10);
      await Future<void>.delayed(Duration(seconds: delaySeconds));
    }
    throw VideoException(
      'video task $taskId did not finish within the polling window',
    );
  }

  String _fileUrlFrom(Map<String, dynamic> data, String taskId) {
    final fileUrl = data['file_url'] as String?;
    if (fileUrl == null) {
      throw VideoException(
        'video generation: MiniMax task $taskId succeeded without '
        'file_url: ${jsonEncode(data)}',
      );
    }
    return fileUrl;
  }

  void _throwIfFailed(
    Map<String, dynamic> data,
    String? status,
    String taskId,
  ) {
    if (status == 'Failed') {
      throw VideoException('video task $taskId failed: ${jsonEncode(data)}');
    }
  }

  void _throwIfCancelled(String? status, String taskId) {
    if (status == 'Cancelled') {
      throw VideoException('video task $taskId was cancelled');
    }
  }

  Future<Map<String, dynamic>> _pollOnce(
    http.Client client,
    String base,
    Map<String, String> headers,
    String taskId,
  ) async {
    final response = await client.get(
      Uri.parse('$base/v2/query/video_generation?task_id=$taskId'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw VideoException(
        'video task query failed: HTTP ${response.statusCode}: '
        '${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Uint8List> _downloadVideo(http.Client client, String fileUrl) async {
    final video = await client.get(Uri.parse(fileUrl));
    if (video.statusCode != 200) {
      throw VideoException(
        'video download failed: HTTP ${video.statusCode} for $fileUrl',
      );
    }
    return video.bodyBytes;
  }
}

/// Hailuo 2.3 video generation (`POST {base}/v1/video_generation`, async,
/// model `MiniMax-Hailuo-2.3`). The endpoint returns a `task_id`; we poll
/// `GET {base}/v1/query/video_generation?task_id=…` until it succeeds,
/// then download the returned `file_url`.
final class HailuoVideoDialect extends VideoDialect {
  @override
  bool matches(VideoEndpoint endpoint) =>
      endpoint.baseUrl.contains('minimax') &&
      endpoint.modelId.contains('Hailuo');

  /// Maps an OpenAI-style `size` ("1920x1080") to a Hailuo `resolution`
  /// ("1080P") and `duration` (6s). Falls back to 1080P for unknown sizes.
  /// Public for tests.
  ({String resolution, int duration}) sizeFor(String? size) {
    if (size == null) return (resolution: '1080P', duration: 6);
    final parts = size.toLowerCase().split('x');
    if (parts.length == 2) {
      final w = int.tryParse(parts[0]);
      final h = int.tryParse(parts[1]);
      if (w != null && h != null && w > 0 && h > 0) {
        final resolution = w >= 1920 ? '1080P' : '768P';
        return (resolution: resolution, duration: 6);
      }
    }
    return (resolution: '1080P', duration: 6);
  }

  @override
  Future<({String path, Uint8List bytes, String detail})> generate({
    required ExecutionEnv env,
    required VideoEndpoint endpoint,
    required String prompt,
    String? size,
    String? quality,
    required http.Client client,
    Future<void> Function()? onPollProgress,
  }) async {
    final base = _trimSlash(endpoint.baseUrl);
    final (resolution: resolution, duration: duration) = sizeFor(size);
    final headers = _hailuoHeaders(endpoint);
    final taskId = await _createTask(
      client,
      base,
      headers,
      endpoint.modelId,
      prompt,
      resolution,
      duration,
    );
    final fileUrl = await _pollForFileUrl(
      client,
      base,
      headers,
      taskId,
      onPollProgress,
    );
    final bytes = await _downloadVideo(client, fileUrl);
    final path = await _save(env, 'videos', 'mp4', bytes);
    return (path: path, bytes: bytes, detail: 'saved to $path');
  }

  String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  Map<String, String> _hailuoHeaders(VideoEndpoint endpoint) => {
    'Content-Type': 'application/json',
    if (endpoint.apiKey.isNotEmpty)
      'Authorization': 'Bearer ${endpoint.apiKey}',
  };

  Future<String> _createTask(
    http.Client client,
    String base,
    Map<String, String> headers,
    String model,
    String prompt,
    String resolution,
    int duration,
  ) async {
    final create = await client.post(
      Uri.parse('$base/v1/video_generation'),
      headers: headers,
      body: jsonEncode({
        'model': model,
        'prompt': prompt,
        'resolution': resolution,
        'duration': duration,
        'prompt_optimizer': true,
      }),
    );
    if (create.statusCode != 200) {
      throw VideoException(
        'video generation failed: HTTP ${create.statusCode}: ${create.body}',
      );
    }
    final created = jsonDecode(create.body) as Map<String, dynamic>;
    final taskId = created['task_id'] as String?;
    if (taskId == null) {
      throw VideoException(
        'video generation: Hailuo response missing task_id: ${create.body}',
      );
    }
    return taskId;
  }

  Future<String> _pollForFileUrl(
    http.Client client,
    String base,
    Map<String, String> headers,
    String taskId,
    Future<void> Function()? onProgress,
  ) async {
    const maxPolls = 20;
    for (var i = 0; i < maxPolls; i++) {
      final data = await _pollOnce(client, base, headers, taskId);
      final status = data['status'] as String?;
      if (status == 'Success') {
        final fileId = data['file_id'] as String?;
        if (fileId == null) {
          throw VideoException(
            'video generation: Hailuo task $taskId succeeded without '
            'file_id: ${jsonEncode(data)}',
          );
        }
        return _downloadUrlFrom(client, base, headers, fileId);
      }
      _throwIfFailed(data, status, taskId);
      await onProgress?.call();
      final delaySeconds = (3 + i).clamp(3, 10);
      await Future<void>.delayed(Duration(seconds: delaySeconds));
    }
    throw VideoException(
      'video task $taskId did not finish within the polling window',
    );
  }

  Future<String> _downloadUrlFrom(
    http.Client client,
    String base,
    Map<String, String> headers,
    String fileId,
  ) async {
    final retrieve = await client.get(
      Uri.parse('$base/v1/files/retrieve?file_id=$fileId'),
      headers: headers,
    );
    if (retrieve.statusCode != 200) {
      throw VideoException(
        'video file retrieve failed: HTTP ${retrieve.statusCode}: '
        '${retrieve.body}',
      );
    }
    final body = jsonDecode(retrieve.body) as Map<String, dynamic>;
    final file = body['file'] as Map<String, dynamic>?;
    final url = file?['download_url'] as String?;
    if (url == null) {
      throw VideoException(
        'video file retrieve: missing download_url for file_id=$fileId: '
        '${retrieve.body}',
      );
    }
    return url;
  }

  void _throwIfFailed(
    Map<String, dynamic> data,
    String? status,
    String taskId,
  ) {
    if (status == 'Fail') {
      throw VideoException('video task $taskId failed: ${jsonEncode(data)}');
    }
  }

  Future<Map<String, dynamic>> _pollOnce(
    http.Client client,
    String base,
    Map<String, String> headers,
    String taskId,
  ) async {
    final response = await client.get(
      Uri.parse('$base/v1/query/video_generation?task_id=$taskId'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw VideoException(
        'video task query failed: HTTP ${response.statusCode}: '
        '${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Uint8List> _downloadVideo(http.Client client, String fileUrl) async {
    final video = await client.get(Uri.parse(fileUrl));
    if (video.statusCode != 200) {
      throw VideoException(
        'video download failed: HTTP ${video.statusCode} for $fileUrl',
      );
    }
    return video.bodyBytes;
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

Future<String> _save(
  ExecutionEnv env,
  String prefix,
  String ext,
  Uint8List bytes,
) async {
  final dir = generatedVideoDir;
  final created = await env.createDir(dir, recursive: true);
  if (created.isErr) {
    throw VideoException('failed to create $dir: ${created.errorOrNull}');
  }
  final unique =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      _videoNameRandom.nextInt(1 << 32).toRadixString(36);
  final name =
      '${prefix}_${DateTime.now().millisecondsSinceEpoch}_$unique.$ext';
  final rel = '$dir/$name';
  final written = await env.writeBinaryFile(rel, bytes);
  if (written.isErr) {
    throw VideoException('failed to write $rel: ${written.errorOrNull}');
  }
  return rel;
}

/// Generates a video on the `videoGeneration` endpoint and saves the MP4
/// into [generatedVideoDir]. Dispatches to the first dialect in
/// [videoGenerationDialects] whose `matches(endpoint)` returns true.
Future<({String path, Uint8List bytes, String detail})> generateVideoBytes({
  required ExecutionEnv env,
  required VideoEndpoint endpoint,
  required String prompt,
  String? size,
  String? quality,
  http.Client? httpClient,
  Future<void> Function()? onPollProgress,
}) async {
  final client = httpClient ?? http.Client();
  try {
    for (final dialect in videoGenerationDialects) {
      if (dialect.matches(endpoint)) {
        return await dialect.generate(
          env: env,
          endpoint: endpoint,
          prompt: prompt,
          size: size,
          quality: quality,
          client: client,
          onPollProgress: onPollProgress,
        );
      }
    }
    throw VideoException('video generation: no matching dialect');
  } finally {
    client.close();
  }
}

/// Builds the `generate_video` [AgentTool] for the CLI. The endpoint is
/// resolved lazily per call so a `/models set videoGeneration …` switch
/// is picked up without a restart.
AgentTool generateVideoTool({
  required ExecutionEnv env,
  required ModelsConfig? modelsConfig,
  required String Function() mainBaseUrl,
  required String Function() mainModelId,
  required String Function() mainApiKey,
  VideoKeyResolver? resolveKey,
  http.Client? httpClient,
}) {
  return AgentTool(
    name: generateVideoToolName,
    label: generateVideoToolName,
    tier: ApprovalTier.write,
    description:
        'Generates a video from a text prompt. Returns a path to the saved '
        'MP4 file. Arguments: prompt (required), size (optional, e.g. '
        '"1920x1080"), quality (optional).',
    parameters: const {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'text prompt describing the video to generate',
        },
        'size': {'type': 'string', 'description': 'video size, e.g. 1920x1080'},
        'quality': {
          'type': 'string',
          'description': 'video quality, e.g. standard or high',
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
        throw VideoException('prompt is required');
      }
      final endpoint = await resolveVideoGenerationEndpoint(
        modelsConfig,
        resolveKey: resolveKey,
      );
      cancelToken?.throwIfCancelled();
      if (endpoint == null) {
        throw VideoException(
          'no endpoint configured for slot videoGeneration; set one in '
          'models.slots.videoGeneration (~/.fah/config.yaml). The chat '
          'endpoint cannot generate video — you must pick a video '
          'provider (e.g. MiniMax MiniMax-H3).',
        );
      }
      final file = await generateVideoBytes(
        env: env,
        endpoint: endpoint,
        prompt: prompt,
        size: size,
        quality: quality,
        httpClient: httpClient,
        onPollProgress: () async {
          // Surface progress to the UI — the polling can take up to
          // ~2 minutes for MiniMax, without a heartbeat the user sees
          // nothing.
          onUpdate?.call(
            ToolExecutionResult(
              content: [TextContent(text: 'video generation: polling task...')],
            ),
          );
        },
      );
      cancelToken?.throwIfCancelled();
      return ToolExecutionResult(
        content: [
          TextContent(text: 'saved video to ${file.path} (${file.detail})'),
        ],
      );
    },
  );
}
