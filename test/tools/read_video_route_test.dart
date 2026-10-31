import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// gh-1985 C1/AC2 — `read` of a video file routes the bytes to a
/// video-capable chat model (VideoContent rides), else to the configured
/// media/vision slot with `[via video model <id>]` attribution, else to
/// the honest configure note. Video calls are size-capped by
/// `images.maxBytesPerRequest` (AC7).

/// A minimal mp4-shaped payload (ftyp box header + padding). The bytes
/// are irrelevant to the routing; the extension carries the decision.
Uint8List _makeFakeMp4({int size = 64}) {
  final box = <int>[
    0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, // size + 'ftyp'
    0x69, 0x73, 0x6F, 0x6D, // 'isom'
    0x00, 0x00, 0x02, 0x00,
  ];
  final bytes = Uint8List(size)
    ..setRange(0, box.length, box);
  for (var i = box.length; i < size; i++) {
    bytes[i] = i & 0x7F;
  }
  return bytes;
}

final videoChatModel = Model(
  id: 'glm-5.3-flash',
  name: 'GLM 5.3 Flash',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  input: const ['text', 'image', 'video'],
  contextWindow: 128000,
  maxTokens: 16384,
);

final plainChatModel = Model(
  id: 'kimi-k3',
  name: 'Kimi k3',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  input: const ['text'],
  contextWindow: 128000,
  maxTokens: 16384,
);

final class _Calls {
  final bodies = <Map<String, dynamic>>[];
  http.Client client(String content) =>
      http_testing.MockClient.streaming((request, bodyStream) async {
        bodies.add(
          jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>,
        );
        final payload = jsonEncode({
          'id': 'c',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'gpt-4o',
          'choices': [
            {
              'index': 0,
              'delta': {
                'role': 'assistant',
                'content': content,
              },
              'finish_reason': null,
            },
          ],
        });
        final done = jsonEncode({
          'id': 'c',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'gpt-4o',
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ],
        });
        return http.StreamedResponse(
          Stream.fromIterable(['data: $payload\n\n', 'data: $done\n\n'])
              .transform(utf8.encoder),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
}

String _textOf(dynamic result) => (result.content as List<ContentBlock>)
    .whereType<TextContent>()
    .map((b) => b.text)
    .join();

void main() {
  late MemoryExecutionEnv env;
  setUp(() => env = MemoryExecutionEnv());

  group('video-capable chat model', () {
    test('read of an mp4 attaches VideoContent (bytes ride to the model)',
        () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final tool = readFileTool(
        env,
        model: () => videoChatModel,
      );
      final result = await tool.execute({'path': '/work/clip.mp4'}, null, null);
      final blocks = result.content;
      final videos = blocks.whereType<VideoContent>().toList();
      expect(videos, hasLength(1));
      expect(videos.single.mimeType, 'video/mp4');
      expect(base64Decode(videos.single.data), _makeFakeMp4());
      final text = _textOf(result);
      expect(text, contains('[Video: /work/clip.mp4'));
    });

    test('a line selector on a video file is refused like on an image',
        () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final tool = readFileTool(env, model: () => videoChatModel);
      await expectLater(
        tool.execute({'path': '/work/clip.mp4:10-20'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('selectors'), contains('video')),
          ),
        ),
      );
    });

    test('an oversized video is NOT attached — note names the size + hint',
        () async {
      await env.writeBinaryFile('/work/big.mp4', _makeFakeMp4(size: 4096));
      final previous = imageRegistryConfig;
      imageRegistryConfig = const ImageRegistryConfig(maxBytesPerRequest: 400);
      try {
        final tool = readFileTool(env, model: () => videoChatModel);
        final result = await tool.execute({'path': '/work/big.mp4'}, null, null);
        final blocks = result.content;
        expect(blocks.whereType<VideoContent>(), isEmpty);
        final text = _textOf(result);
        expect(text, contains('exceeds'));
        expect(text.toLowerCase(), contains('trim'));
      } finally {
        imageRegistryConfig = previous;
      }
    });
  });

  group('non-video chat model + vision slot (the auto-route)', () {
    test('describes the video with attribution and ONE video_url call',
        () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final calls = _Calls();
      final config = InspectImageConfig(
        modelId: 'vmodel-x',
        apiKey: 'k',
        httpClient: calls.client('A cat walks.'),
      );
      final tool = readFileTool(
        env,
        model: () => plainChatModel,
        vision: () async => config,
      );
      final result = await tool.execute({'path': '/work/clip.mp4'}, null, null);
      final text = _textOf(result);
      expect(text, contains('[via video model vmodel-x]'));
      expect(text, contains('A cat walks.'));
      expect(calls.bodies, hasLength(1));
      final parts = ((calls.bodies.single['messages'] as List).last
          as Map)['content'] as List;
      expect(
        parts.any(
          (part) =>
              part is Map<String, dynamic> && part['type'] == 'video_url',
        ),
        isTrue,
        reason: 'the vision call must carry the video bytes',
      );
    });

    test('autoInspect off → the honest note names the configured model',
        () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final config = InspectImageConfig(
        modelId: 'vmodel-x',
        apiKey: 'k',
        httpClient: _Calls().client('x'),
      );
      final tool = readFileTool(
        env,
        model: () => plainChatModel,
        vision: () async => config,
        autoInspect: () => false,
        mediaFileReadNotes: true,
      );
      final result = await tool.execute({'path': '/work/clip.mp4'}, null, null);
      final text = _textOf(result);
      expect(text, contains('vmodel-x'));
      expect(blocks(result), isEmpty, reason: 'no bytes ride');
    });

    test('a slot failure degrades to an honest note (never throws)',
        () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final client = http_testing.MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              'data: {"error":{"message":"boom","type":"invalid_request_error"}}\n\n',
            ),
          ),
          401,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final config = InspectImageConfig(
        modelId: 'vmodel-x',
        apiKey: 'k',
        httpClient: client,
      );
      final tool = readFileTool(
        env,
        model: () => plainChatModel,
        vision: () async => config,
      );
      final result = await tool.execute({'path': '/work/clip.mp4'}, null, null);
      final text = _textOf(result);
      expect(text, contains('failed'));
    });

    test('a mid-flight cancel stays a cancel (CancelledException)',
        () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final source = CancelTokenSource();
      final client = http_testing.MockClient.streaming((request, _) async {
        final chunk =
            'data: {"id":"c","object":"chat.completion.chunk","created":1,'
            '"model":"gpt-4o","choices":[{"index":0,"delta":{"role":'
            '"assistant","content":"partial"},"finish_reason":null}]}\n\n';
        return http.StreamedResponse(
          () async* {
            yield utf8.encode(chunk);
            await source.token.onCancel;
          }(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final config = InspectImageConfig(
        modelId: 'vmodel-x',
        apiKey: 'k',
        httpClient: client,
      );
      final tool = readFileTool(
        env,
        model: () => plainChatModel,
        vision: () async => config,
      );
      final future = tool.execute(
        {'path': '/work/clip.mp4'},
        source.token,
        null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.cancel();
      await expectLater(future, throwsA(isA<CancelledException>()));
    });
  });

  group('non-video chat model + no slot (the honest note)', () {
    test('mediaFileReadNotes → note names the slot/configure path', () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final tool = readFileTool(
        env,
        model: () => plainChatModel,
        mediaFileReadNotes: true,
      );
      final result = await tool.execute({'path': '/work/clip.mp4'}, null, null);
      final text = _textOf(result);
      expect(text, contains('video'));
      expect(
        text.contains('models.slots.vision') ||
            text.contains('video-capable') ||
            text.contains('vision'),
        isTrue,
        reason: 'the note must point at the configuration surface: $text',
      );
      expect(blocks(result), isEmpty);
    });

    test('REG: mediaFileReadNotes off keeps today\'s fall-through', () async {
      await env.writeBinaryFile('/work/clip.mp4', _makeFakeMp4());
      final tool = readFileTool(env, model: () => plainChatModel);
      final result = await tool.execute({'path': '/work/clip.mp4'}, null, null);
      expect(blocks(result), isEmpty,
          reason: 'without notes and without capability nothing new rides');
    });
  });
  group('video mime ↔ extension agreement (gh-2007 thread 2)', () {
    // Every routed extension must ride the MIME its container actually
    // has — the Gemini-side target documents the supported video MIME
    // types (ai.google.dev/gemini-api/docs/video-understanding, mirrored
    // by firebase.google.com/docs/ai-logic/live-api/limits-and-specs):
    // video/mp4, video/mpeg, video/mpg, video/webm, video/quicktime,
    // video/wmv, video/x-flv, video/3gpp (+ x-matroska / x-msvideo ride
    // OpenRouter's video_url passthrough). A `video/mp4` catch-all for a
    // WMV/FLV/3GP container mislabels the payload the same way the image
    // path explicitly avoids.
    const expectedMimes = {
      '.mp4': 'video/mp4',
      '.m4v': 'video/mp4',
      '.mov': 'video/quicktime',
      '.mkv': 'video/x-matroska',
      '.webm': 'video/webm',
      '.avi': 'video/x-msvideo',
      '.mpg': 'video/mpeg',
      '.mpeg': 'video/mpeg',
      '.wmv': 'video/wmv',
      '.flv': 'video/x-flv',
      '.3gp': 'video/3gpp',
    };

    test('every routed extension carries its real container MIME', () async {
      for (final entry in expectedMimes.entries) {
        final path = '/work/clip${entry.key}';
        await env.writeBinaryFile(path, _makeFakeMp4());
        final tool = readFileTool(env, model: () => videoChatModel);
        final result = await tool.execute({'path': path}, null, null);
        final videos = blocks(result);
        expect(videos, hasLength(1), reason: 'extension ${entry.key}');
        expect(
          videos.single.mimeType,
          entry.value,
          reason:
              'extension ${entry.key} must ride its real container MIME '
              '(${entry.value}), not a catch-all',
        );
      }
    });
  });
}

List<VideoContent> blocks(dynamic result) =>
    (result.content as List<ContentBlock>).whereType<VideoContent>().toList();
