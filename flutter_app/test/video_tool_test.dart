// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/video_service.dart';
import 'package:fa/services/video_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Configurable fake [VideoApi] — the host-side tests never touch the real
/// method channel.
final class FakeVideoApi implements VideoApi {
  bool available = true;
  final extractCalls = <({String path, int count})>[];
  List<VideoFrame> frames = [
    (bytes: Uint8List.fromList([1, 1, 1]), positionMs: 0),
    (bytes: Uint8List.fromList([2, 2, 2]), positionMs: 5000),
  ];

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<List<VideoFrame>> extractFrames({
    required String path,
    required int count,
  }) async {
    extractCalls.add((path: path, count: count));
    return frames;
  }
}

/// Captures the request and serves a fixed chat-completions reply — the
/// vision endpoint tests never touch the network.
final class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.statusCode, this.body);

  final int statusCode;
  final String body;
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (request is http.Request) {
      bodies.add(request.body);
    } else {
      bodies.add(await request.finalize().bytesToString());
    }
    return http.StreamedResponse(Stream.value(utf8.encode(body)), statusCode);
  }
}

const _chatReply =
    '{"choices": [{"message": {"content": " A cat plays the piano. "}}]}';

MediaGateway _gateway(
  MemoryExecutionEnv env,
  MediaModelsStore store, {
  String providerKind = 'openai-completions',
  String modelId = 'gpt-4o',
}) => MediaGateway(
  env: env,
  fallback: () => MediaFallback(
    providerKind: providerKind,
    baseUrl: 'https://api.test/v1',
    modelId: modelId,
    apiKey: 'sk-main',
  ),
  store: store,
);

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('videoFramesCount', () {
    test('clamps to 1..12 with a default of 6', () {
      expect(videoFramesCount(null), defaultVideoFrames);
      expect(videoFramesCount(99), maxVideoFrames);
      expect(videoFramesCount(0), 1);
      expect(videoFramesCount(-3), 1);
      expect(videoFramesCount(4), 4);
    });
  });

  group('readVideoTool', () {
    test('is a read-tier tool', () {
      final env = MemoryExecutionEnv();
      final reader = VideoReader(
        video: FakeVideoApi(),
        gateway: _gateway(env, MediaModelsStore.inMemory()),
        httpClient: _FakeHttpClient(200, _chatReply),
      );
      final tool = readVideoTool(env, reader);
      expect(tool.name, readVideoToolName);
      expect(tool.tier, ApprovalTier.read);
    });

    test('sends timeline-labeled frames to the vision model and returns its '
        'description', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
      final video = FakeVideoApi();
      final client = _FakeHttpClient(200, _chatReply);
      final tool = readVideoTool(
        env,
        VideoReader(
          video: video,
          gateway: _gateway(env, MediaModelsStore.inMemory()),
          httpClient: client,
        ),
      );

      final result = await tool.execute(
        const {'path': 'clip.mp4', 'question': 'What animal appears?'},
        null,
        null,
      );

      expect(_textOf(result), 'A cat plays the piano.');
      // Default frame count reached the extractor.
      expect(video.extractCalls.single.count, defaultVideoFrames);
      final request = client.requests.single;
      expect(request.url.toString(), 'https://api.test/v1/chat/completions');
      expect(request.headers['authorization'], 'Bearer sk-main');
      final body = jsonDecode(client.bodies.single) as Map<String, dynamic>;
      expect(body['model'], 'gpt-4o');
      final content =
          ((body['messages'] as List).first as Map)['content'] as List;
      final prompt = (content.first as Map)['text'] as String;
      expect(prompt, contains('frame 1 at 0:00'));
      expect(prompt, contains('frame 2 at 0:05'));
      expect(prompt, contains('What animal appears?'));
      final images = content.whereType<Map>().where(
        (part) => part['type'] == 'image_url',
      );
      expect(images, hasLength(2));
      expect(
        (images.first['image_url'] as Map)['url'],
        'data:image/jpeg;base64,${base64Encode([1, 1, 1])}',
      );
    });

    test('clamps the frames argument before extraction', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
      final video = FakeVideoApi();
      final tool = readVideoTool(
        env,
        VideoReader(
          video: video,
          gateway: _gateway(env, MediaModelsStore.inMemory()),
          httpClient: _FakeHttpClient(200, _chatReply),
        ),
      );

      await tool.execute(const {'path': 'clip.mp4', 'frames': 99}, null, null);
      await tool.execute(const {'path': 'clip.mp4', 'frames': 0}, null, null);

      expect(video.extractCalls.map((c) => c.count), [maxVideoFrames, 1]);
    });

    test('missing file answers with an actionable error and never calls the '
        'endpoint', () async {
      final env = MemoryExecutionEnv();
      final video = FakeVideoApi();
      final client = _FakeHttpClient(200, _chatReply);
      final tool = readVideoTool(
        env,
        VideoReader(
          video: video,
          gateway: _gateway(env, MediaModelsStore.inMemory()),
          httpClient: client,
        ),
      );

      final result = await tool.execute(const {'path': 'nope.mp4'}, null, null);

      expect(_textOf(result), contains('no such file: nope.mp4'));
      expect(video.extractCalls, isEmpty);
      expect(client.requests, isEmpty);
    });

    test('a text-only main model yields an actionable vision error', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
      final client = _FakeHttpClient(200, _chatReply);
      final tool = readVideoTool(
        env,
        VideoReader(
          video: FakeVideoApi(),
          gateway: _gateway(
            env,
            MediaModelsStore.inMemory(),
            modelId: 'gpt-3.5-turbo',
          ),
          httpClient: client,
        ),
      );

      final result = await tool.execute(const {'path': 'clip.mp4'}, null, null);

      final text = _textOf(result);
      expect(text, contains('"gpt-3.5-turbo" does not accept images'));
      expect(text, contains('"vision" slot'));
      expect(client.requests, isEmpty);
    });

    test(
      'the explicit supports-images flag overrides the id heuristic',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
        final client = _FakeHttpClient(200, _chatReply);
        final tool = readVideoTool(
          env,
          VideoReader(
            video: FakeVideoApi(),
            gateway: _gateway(
              env,
              MediaModelsStore.inMemory(),
              modelId: 'custom-text-id',
            ),
            mainSupportsImages: () => true,
            httpClient: client,
          ),
        );

        final result = await tool.execute(
          const {'path': 'clip.mp4'},
          null,
          null,
        );

        expect(_textOf(result), 'A cat plays the piano.');
        expect(client.requests, hasLength(1));
      },
    );

    test('a configured vision slot override is used and trusted', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.vision,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://vision.example.com/v1',
          modelId: 'some-vision-model',
        ),
      );
      final client = _FakeHttpClient(200, _chatReply);
      final tool = readVideoTool(
        env,
        VideoReader(
          video: FakeVideoApi(),
          // The fallback model is deliberately text-only: the override must
          // win without the supports-images gate applying.
          gateway: _gateway(env, store, modelId: 'gpt-3.5-turbo'),
          httpClient: client,
        ),
      );

      final result = await tool.execute(const {'path': 'clip.mp4'}, null, null);

      expect(_textOf(result), 'A cat plays the piano.');
      expect(
        client.requests.single.url.toString(),
        'https://vision.example.com/v1/chat/completions',
      );
      final body = jsonDecode(client.bodies.single) as Map<String, dynamic>;
      expect(body['model'], 'some-vision-model');
    });

    test(
      'no usable endpoint (non-OpenAI fallback, no slot) is actionable',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
        final tool = readVideoTool(
          env,
          VideoReader(
            video: FakeVideoApi(),
            gateway: _gateway(
              env,
              MediaModelsStore.inMemory(),
              providerKind: 'anthropic',
            ),
            httpClient: _FakeHttpClient(200, _chatReply),
          ),
        );

        final result = await tool.execute(
          const {'path': 'clip.mp4'},
          null,
          null,
        );

        expect(_textOf(result), contains('No vision endpoint is configured'));
      },
    );

    test('unsupported platform answers with a clean note', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
      final video = FakeVideoApi()..available = false;
      final tool = readVideoTool(
        env,
        VideoReader(
          video: video,
          gateway: _gateway(env, MediaModelsStore.inMemory()),
          httpClient: _FakeHttpClient(200, _chatReply),
        ),
      );

      final result = await tool.execute(const {'path': 'clip.mp4'}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(video.extractCalls, isEmpty);
    });

    test('an unextractable video answers with a readable-video hint', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('clip.mp4', Uint8List.fromList([9]));
      final video = FakeVideoApi()..frames = [];
      final tool = readVideoTool(
        env,
        VideoReader(
          video: video,
          gateway: _gateway(env, MediaModelsStore.inMemory()),
          httpClient: _FakeHttpClient(200, _chatReply),
        ),
      );

      final result = await tool.execute(const {'path': 'clip.mp4'}, null, null);

      expect(_textOf(result), contains('No frames could be extracted'));
    });
  });
}
