import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show MemoryExecutionEnv;
import 'package:flutter_agent_harness/src/tools/generate_video.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('MiniMaxVideoDialect.sizeFor', () {
    final dialect = MiniMaxVideoDialect();

    test('null size defaults to 2K 16:9', () {
      final result = dialect.sizeFor(null);
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('empty size defaults to 2K 16:9', () {
      final result = dialect.sizeFor('');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('1920x1080 maps to 2K 16:9', () {
      final result = dialect.sizeFor('1920x1080');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('1280x720 maps to 1080P 16:9', () {
      final result = dialect.sizeFor('1280x720');
      expect(result.resolution, '1080P');
      expect(result.ratio, '16:9');
    });

    test('1024x1024 maps to 1080P 1:1', () {
      final result = dialect.sizeFor('1024x1024');
      expect(result.resolution, '1080P');
      expect(result.ratio, '1:1');
    });

    test('invalid format falls back to 2K 16:9', () {
      final result = dialect.sizeFor('large');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('single dimension falls back to 2K 16:9', () {
      final result = dialect.sizeFor('1920');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('zero width falls back to 2K 16:9', () {
      final result = dialect.sizeFor('0x1080');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('negative height falls back to 2K 16:9', () {
      final result = dialect.sizeFor('1920x-1080');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });
  });

  group('MiniMaxVideoDialect.matches', () {
    final dialect = MiniMaxVideoDialect();

    test('matches minimax baseUrl', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
            apiKey: 'k',
          ),
        ),
        isTrue,
      );
    });

    test('does not match openai baseUrl', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'x',
            apiKey: 'k',
          ),
        ),
        isFalse,
      );
    });
  });

  group('HailuoVideoDialect.sizeFor', () {
    final dialect = HailuoVideoDialect();

    test('null size defaults to 1080P 6s', () {
      final result = dialect.sizeFor(null);
      expect(result.resolution, '1080P');
      expect(result.duration, 6);
    });

    test('1920x1080 maps to 1080P', () {
      expect(dialect.sizeFor('1920x1080').resolution, '1080P');
    });

    test('1280x720 maps to 768P', () {
      expect(dialect.sizeFor('1280x720').resolution, '768P');
    });

    test('invalid format falls back to 1080P', () {
      expect(dialect.sizeFor('large').resolution, '1080P');
    });

    test('single dimension falls back to 1080P', () {
      expect(dialect.sizeFor('1920').resolution, '1080P');
    });

    test('zero width falls back to 1080P', () {
      expect(dialect.sizeFor('0x1080').resolution, '1080P');
    });
  });

  group('HailuoVideoDialect.matches', () {
    final dialect = HailuoVideoDialect();

    test('matches minimax baseUrl with a Hailuo model', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-Hailuo-2.3',
            apiKey: 'k',
          ),
        ),
        isTrue,
      );
    });

    test('does not match the H3 chat-family model', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
            apiKey: 'k',
          ),
        ),
        isFalse,
      );
    });

    test('does not match a non-minimax baseUrl', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'MiniMax-Hailuo-2.3',
            apiKey: 'k',
          ),
        ),
        isFalse,
      );
    });
  });

  group('video dialect dispatch and flows', () {
    const hailuoEndpoint = VideoEndpoint(
      baseUrl: 'https://api.minimax.io/v1',
      modelId: 'MiniMax-Hailuo-2.3',
      apiKey: 'k',
    );
    const h3Endpoint = VideoEndpoint(
      baseUrl: 'https://api.minimax.io',
      modelId: 'MiniMax-H3',
      apiKey: 'k',
    );

    MockClient hailuoClient(List<int> videoBytes, {List<String>? hits}) {
      void hit(http.BaseRequest r) => hits?.add('${r.method} ${r.url.path}');
      return MockClient((request) async {
        hit(request);
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/v1/video_generation')) {
          return http.Response('{"task_id": "t1"}', 200);
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
          return http.Response.bytes(videoBytes, 200);
        }
        return http.Response('not found', 404);
      });
    }

    test(
      'Hailuo endpoint dispatches to the V1 flow and saves the mp4',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        final hits = <String>[];
        final result = await generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'a cat',
          httpClient: hailuoClient(bytes, hits: hits),
        );
        expect(result.bytes, bytes);
        expect(result.path, startsWith('generated/'));
        expect(result.path, endsWith('.mp4'));
        // The V1 contract was used — the H3 dialect would have posted to
        // /v2/video_generation instead.
        expect(
          hits.any((h) => h.contains('/v1/video_generation')),
          isTrue,
          reason: 'Hailuo endpoints must reach the Hailuo dialect: $hits',
        );
      },
    );

    test('H3 endpoint still dispatches to the MiniMax V2 flow', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final bytes = Uint8List.fromList([9, 9]);
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/v2/video_generation')) {
          return http.Response('{"task_id": "t2"}', 200);
        }
        if (path.contains('/v2/query/video_generation')) {
          return http.Response(
            '{"status": "Success", "file_url": "https://cdn.example/h3.mp4"}',
            200,
          );
        }
        if (request.url.host == 'cdn.example') {
          return http.Response.bytes(bytes, 200);
        }
        return http.Response('not found', 404);
      });
      final result = await generateVideoBytes(
        env: env,
        endpoint: h3Endpoint,
        prompt: 'a dog',
        httpClient: client,
      );
      expect(result.bytes, bytes);
    });

    test('Hailuo task failure surfaces a VideoException', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          return http.Response('{"task_id": "t1"}', 200);
        }
        if (path.contains('/v1/query/video_generation')) {
          return http.Response('{"status": "Fail", "error": "boom"}', 200);
        }
        return http.Response('not found', 404);
      });
      await expectLater(
        generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'x',
          httpClient: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.message,
            'message',
            contains('failed'),
          ),
        ),
      );
    });

    test('Hailuo success without file_id surfaces a VideoException', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          return http.Response('{"task_id": "t1"}', 200);
        }
        if (path.contains('/v1/query/video_generation')) {
          return http.Response('{"status": "Success"}', 200);
        }
        return http.Response('not found', 404);
      });
      await expectLater(
        generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'x',
          httpClient: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.message,
            'message',
            contains('file_id'),
          ),
        ),
      );
    });

    test('Hailuo create non-200 surfaces the HTTP status', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final client = MockClient(
        (request) async => http.Response('login fail', 401),
      );
      await expectLater(
        generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'x',
          httpClient: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 401'),
          ),
        ),
      );
    });

    test('Hailuo create without task_id surfaces a VideoException', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final client = MockClient(
        (request) async => http.Response('{"unexpected": true}', 200),
      );
      await expectLater(
        generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'x',
          httpClient: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.message,
            'message',
            contains('task_id'),
          ),
        ),
      );
    });

    test('Hailuo retrieve failure surfaces the HTTP status', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          return http.Response('{"task_id": "t1"}', 200);
        }
        if (path.contains('/v1/query/video_generation')) {
          return http.Response('{"status": "Success", "file_id": "f1"}', 200);
        }
        if (path.contains('/v1/files/retrieve')) {
          return http.Response('gone', 410);
        }
        return http.Response('not found', 404);
      });
      await expectLater(
        generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'x',
          httpClient: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 410'),
          ),
        ),
      );
    });

    test(
      'Hailuo retrieve without download_url surfaces a VideoException',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final client = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST') {
            return http.Response('{"task_id": "t1"}', 200);
          }
          if (path.contains('/v1/query/video_generation')) {
            return http.Response('{"status": "Success", "file_id": "f1"}', 200);
          }
          if (path.contains('/v1/files/retrieve')) {
            return http.Response('{"file": {}}', 200);
          }
          return http.Response('not found', 404);
        });
        await expectLater(
          generateVideoBytes(
            env: env,
            endpoint: hailuoEndpoint,
            prompt: 'x',
            httpClient: client,
          ),
          throwsA(
            isA<VideoException>().having(
              (e) => e.message,
              'message',
              contains('download_url'),
            ),
          ),
        );
      },
    );

    test('Hailuo download failure surfaces the HTTP status', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          return http.Response('{"task_id": "t1"}', 200);
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
          return http.Response('nope', 500);
        }
        return http.Response('not found', 404);
      });
      await expectLater(
        generateVideoBytes(
          env: env,
          endpoint: hailuoEndpoint,
          prompt: 'x',
          httpClient: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 500'),
          ),
        ),
      );
    });
  });
}
