import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show MemoryExecutionEnv;
import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:flutter_agent_harness/src/model_roles/models_config.dart';
import 'package:flutter_agent_harness/src/tools/generate_image.dart'
    show MediaException;
import 'package:flutter_agent_harness/src/tools/generate_video.dart';
import 'package:flutter_agent_harness/src/tools/media_reference_images.dart';
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

  group('resolveVideoGenerationEndpoint', () {
    test('null models config resolves to no endpoint', () async {
      expect(await resolveVideoGenerationEndpoint(null), isNull);
    });

    test('no videoGeneration slot override resolves to no endpoint', () async {
      final config = ModelsConfig();
      expect(await resolveVideoGenerationEndpoint(config), isNull);
    });

    test('slot override without a key name reuses the main key same-host',
        () async {
      final config = ModelsConfig(
        slots: {
          'videoGeneration': MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
          ),
        },
      );
      // gh-1844 review: aligned with the image resolver — same-host
      // reuse of the main connection's key.
      final endpoint = await resolveVideoGenerationEndpoint(
        config,
        mainBaseUrl: 'https://api.minimax.io/v1',
        mainApiKey: 'main-key',
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.baseUrl, 'https://api.minimax.io/v1');
      expect(endpoint.modelId, 'MiniMax-H3');
      expect(endpoint.apiKey, 'main-key');
    });

    test('slot override without a key name on another host throws an '
        'actionable error', () async {
      final config = ModelsConfig(
        slots: {
          'videoGeneration': MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
          ),
        },
      );
      // gh-1844 review: no silent empty-Authorization call — the resolver
      // fails named and actionable, like the imageGeneration slot.
      expect(
        resolveVideoGenerationEndpoint(
          config,
          mainBaseUrl: 'https://api.other.example/v1',
          mainApiKey: 'main-key',
        ),
        throwsA(
          isA<MediaException>().having(
            (e) => e.toString(),
            'message',
            contains('videoGeneration slot has no resolvable API key'),
          ),
        ),
      );
    });

    test('slot override with apiKeyName resolves the key via the seam',
        () async {
      final config = ModelsConfig(
        slots: {
          'videoGeneration': MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
            apiKeyName: 'MINIMAX_API_KEY',
          ),
        },
      );
      final endpoint = await resolveVideoGenerationEndpoint(
        config,
        resolveKey: (name) async => name == 'MINIMAX_API_KEY' ? 'sk-test' : null,
      );
      expect(endpoint!.apiKey, 'sk-test');
    });

    test('missing key resolution falls back to same-host reuse, else '
        'throws', () async {
      final config = ModelsConfig(
        slots: {
          'videoGeneration': MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
            apiKeyName: 'MINIMAX_API_KEY',
          ),
        },
      );
      // Image-resolver parity: a NAMED key wins — when it does not
      // resolve there is no silent fallback (not even same-host), the
      // resolver throws the named, actionable error instead of sending
      // an empty Authorization header.
      expect(
        resolveVideoGenerationEndpoint(
          config,
          mainBaseUrl: 'https://api.minimax.io/v1',
          mainApiKey: 'main-key',
          resolveKey: (name) async => null,
        ),
        throwsA(
          isA<MediaException>().having(
            (e) => e.toString(),
            'message',
            contains('(named "MINIMAX_API_KEY")'),
          ),
        ),
      );
    });
  });

  group('resolveVideoGenerationEndpoint useMainConnection (gh-1844)', () {
    test('opt-in serves the slot from the main connection', () async {
      final config = ModelsConfig(
        slots: {
          'videoGeneration': MediaSlotModelConfig(useMainConnection: true),
        },
      );
      final endpoint = await resolveVideoGenerationEndpoint(
        config,
        mainBaseUrl: 'https://main.example/v1',
        mainModelId: 'main-model',
        mainApiKey: 'main-key',
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.baseUrl, 'https://main.example/v1');
      expect(endpoint.modelId, 'main-model');
      expect(endpoint.apiKey, 'main-key');
    });

    test('opt-in with an empty main connection resolves to no endpoint', () async {
      final config = ModelsConfig(
        slots: {
          'videoGeneration': MediaSlotModelConfig(useMainConnection: true),
        },
      );
      expect(await resolveVideoGenerationEndpoint(config), isNull);
    });
  });

  group('OpenRouterVideoDialect (gh-1844)', () {
    final dialect = OpenRouterVideoDialect();
    const endpoint = VideoEndpoint(
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'google/veo-3.1-generate-preview',
      apiKey: 'or-key',
    );

    test('matches openrouter.ai endpoints only', () {
      expect(dialect.matches(endpoint), isTrue);
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

    test('poll budget matches OpenRouter job durations (review, gh-1844)',
        () {
      // The official docs: jobs run 30 s to several minutes, poll at a
      // ~30 s interval. The MiniMax ~2-minute window must not transfer.
      expect(OpenRouterVideoDialect.defaultMaxPolls, greaterThanOrEqualTo(30));
      final first = OpenRouterVideoDialect.defaultPollDelay(0);
      final last = OpenRouterVideoDialect.defaultPollDelay(1000);
      expect(first.inSeconds, greaterThanOrEqualTo(15));
      expect(first.inSeconds, lessThanOrEqualTo(30));
      expect(last.inSeconds, lessThanOrEqualTo(30));
    });

    test('a job that never completes exhausts the poll window', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      var polls = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path == '/api/v1/videos') {
          return http.Response(
            '{"id": "job-9", "status": "queued", '
            '"polling_url": "https://openrouter.ai/api/v1/videos/job-9"}',
            202,
          );
        }
        if (request.method == 'GET' && path == '/api/v1/videos/job-9') {
          polls++;
          return http.Response('{"id": "job-9", "status": "pending"}', 200);
        }
        return http.Response('not found', 404);
      });

      // Inject a tiny window so the exhaustion path is testable without
      // real minutes of backoff.
      final tiny = OpenRouterVideoDialect(
        maxPolls: 4,
        pollDelay: (_) => Duration.zero,
      );
      expect(
        tiny.generate(
          env: env,
          endpoint: endpoint,
          prompt: 'a cat',
          client: client,
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.toString(),
            'message',
            contains('did not finish within the polling window'),
          ),
        ),
      );
      expect(polls, 4);
    });
    test('declares reference-image support', () {
      expect(dialect.supportsReferenceImages, isTrue);
    });

    test('submit/poll/download flow saves the mp4', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final bytes = Uint8List.fromList([5, 6, 7]);
      final hits = <String>[];
      final client = MockClient((request) async {
        hits.add('${request.method} ${request.url}');
        final path = request.url.path;
        if (request.method == 'POST' && path == '/api/v1/videos') {
          return http.Response(
            '{"id": "job-1", "status": "queued", '
            '"polling_url": "https://openrouter.ai/api/v1/videos/job-1"}',
            202,
          );
        }
        if (request.method == 'GET' && path == '/api/v1/videos/job-1') {
          return http.Response(
            '{"id": "job-1", "status": "completed", '
            '"unsigned_urls": ["/api/v1/videos/job-1/content"]}',
            200,
          );
        }
        if (path == '/api/v1/videos/job-1/content') {
          return http.Response.bytes(bytes, 200);
        }
        return http.Response('not found', 404);
      });

      final result = await generateVideoBytes(
        env: env,
        endpoint: endpoint,
        prompt: 'a cat',
        httpClient: client,
      );
      expect(result.bytes, bytes);
      expect(result.path, endsWith('.mp4'));
      expect(
        hits.any(
          (h) => h.startsWith('POST') && h.contains('/api/v1/videos'),
        ),
        isTrue,
        reason: 'OpenRouter endpoints must reach the /videos job API: $hits',
      );
    });

    test('reference videos ride input_references', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final bytes = Uint8List.fromList([9]);
      String? submitBody;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path == '/api/v1/videos') {
          submitBody = request.body;
          return http.Response(
            '{"id": "job-2", "status": "queued", '
            '"polling_url": "https://openrouter.ai/api/v1/videos/job-2"}',
            202,
          );
        }
        if (request.method == 'GET' && path == '/api/v1/videos/job-2') {
          return http.Response(
            '{"id": "job-2", "status": "completed", '
            '"unsigned_urls": ["/api/v1/videos/job-2/content"]}',
            200,
          );
        }
        if (path == '/api/v1/videos/job-2/content') {
          return http.Response.bytes(bytes, 200);
        }
        return http.Response('not found', 404);
      });

      await generateVideoBytes(
        env: env,
        endpoint: endpoint,
        prompt: 'animate this scene',
        images: const [MediaImageBase64('CAk=')],
        declaredInputModalities: const ['image', 'text'],
        httpClient: client,
      );

      final body = jsonDecode(submitBody!) as Map<String, dynamic>;
      final refs =
          (body['input_references'] as List).cast<Map<String, dynamic>>();
      expect(refs, hasLength(1));
      expect(refs[0]['type'], 'image_url');
      final imageUrl =
          (refs[0]['image_url'] as Map<String, dynamic>)['url'] as String;
      expect(imageUrl, startsWith('data:image/'));
      expect(imageUrl, endsWith('CAk='));
    });
  });

  group('generate_video reference videos (gh-1844)', () {
    const minimaxEndpoint = VideoEndpoint(
      baseUrl: 'https://api.minimax.io/v1',
      modelId: 'MiniMax-H3',
      apiKey: 'k',
    );

    test('MiniMax endpoint rejects reference videos before any call', () {
      final env = MemoryExecutionEnv(cwd: '/work');
      expect(
        generateVideoBytes(
          env: env,
          endpoint: minimaxEndpoint,
          prompt: 'animate this',
          images: const [MediaImageBase64('AAAA')],
          httpClient: MockClient(
            (request) async => http.Response('unexpected call', 500),
          ),
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.toString(),
            'message',
            contains(
              'reference images are only supported by the OpenRouter',
            ),
          ),
        ),
      );
    });

    test('declared text-only modalities reject reference videos', () {
      final env = MemoryExecutionEnv(cwd: '/work');
      expect(
        generateVideoBytes(
          env: env,
          endpoint: const VideoEndpoint(
            baseUrl: 'https://openrouter.ai/api/v1',
            modelId: 'google/veo-3.1-generate-preview',
            apiKey: 'or-key',
          ),
          prompt: 'animate this',
          images: const [MediaImageBase64('AAAA')],
          declaredInputModalities: const ['text'],
          httpClient: MockClient(
            (request) async => http.Response('unexpected call', 500),
          ),
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.toString(),
            'message',
            contains('does not accept image input'),
          ),
        ),
      );
    });
  });
}
