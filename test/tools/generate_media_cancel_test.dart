import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/tools/generate_image.dart';
import 'package:flutter_agent_harness/src/tools/generate_video.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Issue #1923 AC2/AC4: media generation honors cancellation checkpoints.
/// A cancelled run token rejects with [CancelledException] (no new HTTP
/// after the cancel point); a fired soft-yield token stops the video poll
/// loop and hands back honestly — the remote task keeps rendering, never
/// restarted, and its file will not auto-arrive.
void main() {
  group('generate_image cancellation', () {
    const endpoint = MediaEndpoint(
      baseUrl: 'https://api.example.com/v1',
      modelId: 'img-1',
      apiKey: 'k',
    );

    test(
      'a token cancelled before generate rejects with no HTTP call',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          return http.Response('{"data":[{"b64_json":"AAAA"}]}', 200);
        });
        final source = CancelTokenSource()..cancel('user abort');

        await expectLater(
          generateImageBytes(
            env: MemoryExecutionEnv(cwd: '/work'),
            endpoint: endpoint,
            prompt: 'a cat',
            httpClient: client,
            cancelToken: source.token,
          ),
          throwsA(isA<CancelledException>()),
        );
        expect(calls, 0, reason: 'the cancel guard precedes any HTTP');
      },
    );

    test('an uncancelled token does not disturb the happy path', () async {
      final client = MockClient((request) async {
        return http.Response('{"data":[{"b64_json":"AAAA"}]}', 200);
      });
      final source = CancelTokenSource();

      final result = await generateImageBytes(
        env: MemoryExecutionEnv(cwd: '/work'),
        endpoint: endpoint,
        prompt: 'a cat',
        httpClient: client,
        cancelToken: source.token,
      );

      expect(result.path, startsWith('generated/'));
      expect(result.bytes, isNotEmpty);
    });
  });

  group('generate_video cancellation', () {
    const h3Endpoint = VideoEndpoint(
      baseUrl: 'https://api.minimax.io',
      modelId: 'MiniMax-H3',
      apiKey: 'k',
    );

    test(
      'a token cancelled before generate rejects with no HTTP call',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          return http.Response('{"task_id": "t1"}', 200);
        });
        final source = CancelTokenSource()..cancel('user abort');

        await expectLater(
          generateVideoBytes(
            env: MemoryExecutionEnv(cwd: '/work'),
            endpoint: h3Endpoint,
            prompt: 'a cat',
            httpClient: client,
            cancelToken: source.token,
          ),
          throwsA(isA<CancelledException>()),
        );
        expect(calls, 0, reason: 'the cancel guard precedes any HTTP');
      },
    );

    test(
      'a cancel landing mid-poll aborts the loop with CancelledException',
      () async {
        final source = CancelTokenSource();
        var polls = 0;
        final client = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' &&
              path.endsWith('/v2/video_generation')) {
            return http.Response('{"task_id": "t-mid"}', 200);
          }
          if (path.contains('/v2/query/video_generation')) {
            polls++;
            // The run goes away while the first poll is in flight.
            source.cancel('user abort');
            return http.Response('{"status": "Queueing"}', 200);
          }
          return http.Response('not found', 404);
        });

        await expectLater(
          generateVideoBytes(
            env: MemoryExecutionEnv(cwd: '/work'),
            endpoint: h3Endpoint,
            prompt: 'a cat',
            httpClient: client,
            cancelToken: source.token,
          ),
          throwsA(isA<CancelledException>()),
        );
        expect(polls, 1, reason: 'the loop stops at the next checkpoint');
      },
    );

    test('a pre-fired yield token hands the poll back after the submit, '
        'without polling', () async {
      final hits = <String>[];
      final client = MockClient((request) async {
        hits.add('${request.method} ${request.url.path}');
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/v2/video_generation')) {
          return http.Response('{"task_id": "t-yield"}', 200);
        }
        return http.Response('{"status": "Queueing"}', 200);
      });
      final yieldSource = CancelTokenSource()..cancel();

      await expectLater(
        generateVideoBytes(
          env: MemoryExecutionEnv(cwd: '/work'),
          endpoint: h3Endpoint,
          prompt: 'a cat',
          httpClient: client,
          yieldToken: yieldSource.token,
        ),
        throwsA(
          isA<VideoYieldHandback>().having(
            (e) => e.taskId,
            'taskId',
            't-yield',
          ),
        ),
      );
      expect(
        hits,
        ['POST /v2/video_generation'],
        reason:
            'the submit ran, no poll did — the render keeps going '
            'remotely',
      );
    });

    test(
      'the tool result carries the anchor sentence and the task id',
      () async {
        final client = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' &&
              path.endsWith('/v1/video_generation')) {
            return http.Response('{"task_id": "t-anchored"}', 200);
          }
          return http.Response('{"status": "Queueing"}', 200);
        });
        final tool = generateVideoTool(
          env: MemoryExecutionEnv(cwd: '/work'),
          modelsConfig: ModelsConfig(
            slots: {
              'videoGeneration': MediaSlotModelConfig(
                providerKind: 'openai-completions',
                baseUrl: 'https://api.minimax.io/v1',
                modelId: 'MiniMax-Hailuo-2.3',
                apiKeyName: 'VIDEO_KEY',
              ),
            },
          ),
          mainBaseUrl: () => 'https://main.example/v1',
          mainModelId: () => 'main-model',
          mainApiKey: () => 'main-key',
          resolveKey: (name) async => name == 'VIDEO_KEY' ? 'k' : null,
          httpClient: client,
        );
        final yieldSource = CancelTokenSource()..cancel();

        // The tool reads the soft-yield token from its zone, so run the
        // execute the way the loop does — inside the phase zone.
        final result = await runZoned(
          () => tool.execute({'prompt': 'a cat'}, null, null),
          zoneValues: {yieldTokenZoneKey: yieldSource.token},
        );

        final text = result.content
            .whereType<TextContent>()
            .map((block) => block.text)
            .join();
        expect(
          text,
          startsWith(stuckBackgroundHandbackSentence),
          reason: 'the loop classifies hand-backs by this prefix',
        );
        expect(text, contains('t-anchored'));
        expect(text, contains('FRESH render'));
      },
    );

    test('video completes normally when no tokens fire', () async {
      final bytes = <int>[1, 2, 3, 4];
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/v1/video_generation')) {
          return http.Response('{"task_id": "t-ok"}', 200);
        }
        if (path.contains('/v1/query/video_generation')) {
          return http.Response('{"status": "Success", "file_id": "f1"}', 200);
        }
        if (path.contains('/v1/files/retrieve')) {
          return http.Response(
            '{"file": {"download_url": "https://cdn.example/v.mp4"}}',
            200,
          );
        }
        if (request.url.host == 'cdn.example') {
          return http.Response.bytes(bytes, 200);
        }
        return http.Response('not found', 404);
      });

      final result = await generateVideoBytes(
        env: MemoryExecutionEnv(cwd: '/work'),
        endpoint: const VideoEndpoint(
          baseUrl: 'https://api.minimax.io/v1',
          modelId: 'MiniMax-Hailuo-2.3',
          apiKey: 'k',
        ),
        prompt: 'a cat',
        httpClient: client,
        cancelToken: CancelTokenSource().token,
      );

      expect(result.bytes, bytes);
      expect(result.path, startsWith('generated/'));
      expect(result.path, endsWith('.mp4'));
    });
  });
}
