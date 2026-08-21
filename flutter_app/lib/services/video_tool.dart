// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/video_service.dart';

/// Name of the agent tool that reads a video through a vision model.
const readVideoToolName = 'read_video';

/// Video understanding against the vision endpoint configured in
/// [MediaModelsStore] (the `vision` slot, falling back to the app's main
/// connection when its model accepts images — see
/// [modelIdSuggestsVision]).
///
/// Shared by the agent's `read_video` tool and the
/// `jsr.fa.media.readVideo` JS bridge so both resolve endpoints identically
/// (the same per-call [MediaGateway.endpointFor] resolution the media
/// generation calls use). Frames come from [video] (the `fah/video` channel
/// on macOS/iOS); the frames themselves never enter the chat context — only
/// the model's description does. All failures surface as [StateError] with
/// an actionable, user-readable message.
final class VideoReader {
  /// Creates a reader over [video] (frame extraction) and [_gateway]
  /// (endpoint resolution). [_mainSupportsImages] decides whether the MAIN
  /// connection's model accepts images when the `vision` slot has no
  /// override (defaults to the [modelIdSuggestsVision] heuristic); slot
  /// overrides are trusted as configured. [_httpClient] is injectable for
  /// tests.
  const VideoReader({
    required this.video,
    required this._gateway,
    this._mainSupportsImages,
    this._httpClient,
  });

  /// The frame-extraction backend.
  final VideoApi video;

  final MediaGateway _gateway;
  final bool Function()? _mainSupportsImages;
  final http.Client? _httpClient;

  /// Extracts [frames] (already clamped via [videoFramesCount]) evenly
  /// spaced frames from the video at the host [path] and asks the vision
  /// model to describe it, optionally steering the answer with [question].
  /// Returns the model's description.
  Future<String> describe({
    required String path,
    int frames = defaultVideoFrames,
    String? question,
  }) async {
    if (!await video.isAvailable) {
      throw StateError(
        'Video reading is not supported on this platform (it needs the '
        'macOS or iOS app).',
      );
    }
    final extracted = await video.extractFrames(path: path, count: frames);
    if (extracted.isEmpty) {
      throw StateError(
        'No frames could be extracted from $path — is it a readable video '
        'file?',
      );
    }
    final endpoint = await _requireVisionEndpoint();

    final labels = [
      for (var i = 0; i < extracted.length; i++)
        'frame ${i + 1} at ${_timelineLabel(extracted[i].positionMs)}',
    ];
    final trimmedQuestion = question?.trim() ?? '';
    final prompt =
        'These ${extracted.length} frames were extracted from one video, '
        'evenly spaced and in chronological order (${labels.join(', ')}). '
        '${trimmedQuestion.isEmpty ? 'Describe what happens in the video, in timeline order, referencing the frame timestamps.' : 'Answer this question about the video, referencing the frame timestamps where relevant: $trimmedQuestion'}';
    final body = <String, Object?>{
      'model': endpoint.modelId,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            for (final frame in extracted)
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64Encode(frame.bytes)}',
                },
              },
          ],
        },
      ],
    };

    final client = _httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse('${endpoint.baseUrl}/chat/completions'),
        headers: {
          'authorization': 'Bearer ${endpoint.apiKey}',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
    } finally {
      if (_httpClient == null) client.close();
    }
    if (response.statusCode != 200) {
      throw StateError(
        'Video reading failed (HTTP ${response.statusCode}): '
        '${response.body.trim()}',
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final choices = decoded['choices'];
        if (choices is List &&
            choices.isNotEmpty &&
            choices.first is Map &&
            (choices.first as Map)['message'] is Map) {
          final content = ((choices.first as Map)['message'] as Map)['content'];
          if (content is String && content.trim().isNotEmpty) {
            return content.trim();
          }
        }
      }
    } on FormatException {
      // fall through
    }
    throw StateError('Video reading returned an unexpected response.');
  }

  /// The `vision` slot endpoint: the override when configured (trusted as
  /// configured), otherwise the main connection — gated on image support so
  /// a text-only chat model never gets a blind image request.
  Future<MediaEndpoint> _requireVisionEndpoint() async {
    final endpoint = await _gateway.endpointFor(MediaSlot.vision);
    if (endpoint == null) {
      throw StateError(
        'No vision endpoint is configured. Either connect an '
        'OpenAI-compatible vision-capable provider in the Fa settings, or '
        'add a "vision" slot to ${MediaModelsStore.fileName} '
        '({providerKind, baseUrl, modelId, apiKeyName?}).',
      );
    }
    if (!endpoint.fromOverride) {
      final supports =
          _mainSupportsImages?.call() ??
          modelIdSuggestsVision(endpoint.modelId);
      if (!supports) {
        throw StateError(
          'The connected model "${endpoint.modelId}" does not accept '
          'images. Connect a vision-capable model, or add a "vision" slot '
          'to ${MediaModelsStore.fileName} pointing at one.',
        );
      }
    }
    return endpoint;
  }

  /// `0:00` / `1:23` timeline label for a frame position.
  static String _timelineLabel(int positionMs) {
    final seconds = positionMs ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// Creates the `read_video` tool bound to [env] and [reader].
///
/// Tier read: it only reads a sandbox file and spends a (cheap, bounded)
/// vision request. [path] is resolved inside the sandbox ([ExecutionEnv]);
/// the frame extractor receives the host path. Texts are LLM-facing and
/// stay literal English.
AgentTool readVideoTool(ExecutionEnv env, VideoReader reader) {
  return AgentTool(
    name: readVideoToolName,
    label: readVideoToolName,
    tier: ApprovalTier.read,
    description:
        'Read a video file: extracts evenly spaced frames (default '
        '$defaultVideoFrames, max $maxVideoFrames) and sends them to the '
        'configured vision model (media_models.json vision slot, or the '
        'connected model when it accepts images), returning its description '
        'of what happens in the video with timeline labels. Use it to '
        'answer questions about screen recordings, clips, and other video '
        'files in the sandbox. Supported on macOS/iOS only.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the video file (relative or absolute)',
        },
        'frames': {
          'type': 'integer',
          'description':
              'How many frames to extract, 1-$maxVideoFrames (default: '
              '$defaultVideoFrames)',
        },
        'question': {
          'type': 'string',
          'description':
              'Optional question about the video (default: a general '
              'description of what happens)',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      try {
        cancelToken?.throwIfCancelled();
        final path = (arguments['path'] ?? '').toString().trim();
        if (path.isEmpty) {
          return ToolExecutionResult.text('Error: path is required');
        }
        final exists = await env.exists(path);
        if (exists.valueOrNull != true) {
          return ToolExecutionResult.text(
            'Error: no such file: $path — check the path (list the sandbox '
            'with your file tools) and try again.',
          );
        }
        // The platform extractor (AVAssetImageGenerator) works on host
        // paths; the sandbox env maps the agent-visible path.
        final hostPath = (await env.absolutePath(path)).valueOrNull ?? path;
        final description = await reader.describe(
          path: hostPath,
          frames: videoFramesCount(arguments['frames'] as num?),
          question: arguments['question']?.toString(),
        );
        return ToolExecutionResult.text(description);
      } on Object catch (error) {
        return ToolExecutionResult.text(
          'Error: ${error is StateError ? error.message : error}',
        );
      }
    },
  );
}
