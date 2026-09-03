// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/video_service.dart';
import 'package:fa/services/video_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settle = Duration(milliseconds: 400);

  JsAppInfo app() => JsAppInfo.fromManifest(
    const {'id': 'demo', 'name': 'Demo'},
    bundled: false,
    fallbackId: 'demo',
  );

  const widgetJs = '''
(function() {
  jsr.fa.media.generateImage({prompt: 'a teal robot', size: '1024x1024'})
    .then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__error: '' + error}});
    });
  jsr.render({type: 'text', data: 'x'});
})();
''';

  MediaGateway fakeGateway(MemoryExecutionEnv env, List<http.Request> seen) =>
      MediaGateway(
        env: env,
        fallback: () => const MediaFallback(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.test/v1',
          modelId: 'gpt-5',
          apiKey: 'sk-main',
        ),
        store: MediaModelsStore.inMemory(),
        httpClient: http_testing.MockClient((request) async {
          seen.add(request);
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'b64_json': base64Encode(Uint8List.fromList([1, 2, 3])),
                },
              ],
            }),
            200,
          );
        }),
      );

  testWidgets('fa.media.generateImage is denied without the media permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', widgetJs);
      final seen = <http.Request>[];

      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        mediaGateway: fakeGateway(env, seen),
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        final result = jsonEncode(denied.exportedState?['result']);
        expect(result, contains('__error'));
        expect(result, contains('media permission'));
        expect(seen, isEmpty); // the endpoint was never called
      } finally {
        await denied.dispose();
      }
    });
  });

  testWidgets('fa.media.generateImage with the permission reaches the '
      'endpoint and returns the sandbox path', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', widgetJs);
      final seen = <http.Request>[];

      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(media: true),
        mediaGateway: fakeGateway(env, seen),
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(seen, hasLength(1));
        expect(
          seen.single.url.toString(),
          'https://api.test/v1/images/generations',
        );
        final result = granted.exportedState?['result'] as Map;
        final path = result['path'].toString();
        expect(path, startsWith('generated/image-'));
        expect(path, endsWith('.png'));
        expect(result['bytes'], 3);
        // The generated file really landed in the app's sandbox.
        expect((await env.readBinaryFile(path)).valueOrNull, [1, 2, 3]);
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.media.speak and fa.media.generateMusic route through the '
      'same gate', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.media.speak({text: 'hi'}).then(function(result) {
    jsr.exportState({speak: result});
  }, function(error) {
    jsr.exportState({speak: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');
      final seen = <http.Request>[];

      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        mediaGateway: fakeGateway(env, seen),
      );
      try {
        await denied.start();
        // Poll: the JS bridge round-trip has no fixed completion time.
        for (var i = 0; i < 20 && denied.exportedState == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          jsonEncode(denied.exportedState?['speak']),
          contains('media permission'),
        );
      } finally {
        await denied.dispose();
      }
    });
  });

  testWidgets('fa.media.generateVideo with the permission polls the job and '
      'resolves with the sandbox path of the saved mp4', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.media.generateVideo({prompt: 'a teal robot dances', seconds: 8})
    .then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__error: '' + error}});
    });
  jsr.render({type: 'text', data: 'x'});
})();
''');
      final seen = <http.Request>[];
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.videoGeneration,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://video.test/v1',
          modelId: 'bytedance/seedance-1-5-pro',
          apiKeyName: 'VIDEO_KEY',
        ),
      );
      final gateway = MediaGateway(
        env: env,
        fallback: () => const MediaFallback(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.test/v1',
          modelId: 'gpt-5',
          apiKey: 'sk-main',
        ),
        store: store,
        resolveKey: (name) async => name == 'VIDEO_KEY' ? 'sk-video' : null,
        httpClient: http_testing.MockClient((request) async {
          seen.add(request);
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({'id': 'job-1', 'status': 'pending'}),
              202,
            );
          }
          if (request.url.host == 'cdn.test') {
            return http.Response.bytes(Uint8List.fromList([7, 7]), 200);
          }
          return http.Response(
            jsonEncode({
              'id': 'job-1',
              'status': 'completed',
              'unsigned_urls': ['https://cdn.test/clip.mp4'],
            }),
            200,
          );
        }),
        videoPollInterval: const Duration(milliseconds: 5),
      );

      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(media: true),
        mediaGateway: gateway,
      );
      try {
        await granted.start();
        // Poll: the bridge round-trip + job poll have no fixed completion time.
        for (var i = 0; i < 50 && granted.exportedState == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(seen.first.url.toString(), 'https://video.test/v1/videos');
        final result = granted.exportedState?['result'] as Map;
        final path = result['path'].toString();
        expect(path, startsWith('generated/video-'));
        expect(path, endsWith('.mp4'));
        expect(result['bytes'], 2);
        // The generated file really landed in the app's sandbox.
        expect((await env.readBinaryFile(path)).valueOrNull, [7, 7]);
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.media with the permission but no session gateway answers '
      'with an actionable error', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', widgetJs);

      final noGateway = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(media: true),
      );
      try {
        await noGateway.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(noGateway.exportedState?['result']),
          contains('not available'),
        );
      } finally {
        await noGateway.dispose();
      }
    });
  });

  group('fa.media.readVideo', () {
    const videoJs = '''
(function() {
  jsr.fa.media.readVideo({path: 'clip.mp4', frames: 4, question: 'What happens?'})
    .then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__error: '' + error}});
    });
  jsr.render({type: 'text', data: 'x'});
})();
''';

    /// A reader over a fake extractor + a fake vision endpoint answering a
    /// fixed chat-completions reply.
    VideoReader fakeReader(MemoryExecutionEnv env, FakeVideoApi video) =>
        VideoReader(
          video: video,
          gateway: MediaGateway(
            env: env,
            fallback: () => const MediaFallback(
              providerKind: 'openai-completions',
              baseUrl: 'https://api.test/v1',
              modelId: 'gpt-5',
              apiKey: 'sk-main',
            ),
            store: MediaModelsStore.inMemory(),
          ),
          httpClient: http_testing.MockClient((request) async {
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'A robot dances.'},
                  },
                ],
              }),
              200,
            );
          }),
        );

    testWidgets('is denied without the media permission', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', videoJs);
        await env.writeFile('clip.mp4', 'x');
        final video = FakeVideoApi();

        final denied = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(),
          videoReader: fakeReader(env, video),
        );
        try {
          await denied.start();
          await Future<void>.delayed(settle);
          final result = jsonEncode(denied.exportedState?['result']);
          expect(result, contains('__error'));
          expect(result, contains('media permission'));
          expect(video.extractCalls, isEmpty);
        } finally {
          await denied.dispose();
        }
      });
    });

    testWidgets('with the permission but no session reader answers with an '
        'actionable error', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', videoJs);
        await env.writeFile('clip.mp4', 'x');

        final noReader = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(media: true),
        );
        try {
          await noReader.start();
          await Future<void>.delayed(settle);
          expect(
            jsonEncode(noReader.exportedState?['result']),
            contains('not available'),
          );
        } finally {
          await noReader.dispose();
        }
      });
    });

    testWidgets('with the permission resolves with the vision description', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', videoJs);
        await env.writeFile('clip.mp4', 'x');
        final video = FakeVideoApi();

        final granted = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(media: true),
          videoReader: fakeReader(env, video),
        );
        try {
          await granted.start();
          await Future<void>.delayed(settle);
          expect(video.extractCalls.single.count, 4);
          final result = granted.exportedState?['result'] as Map;
          expect(result['description'], 'A robot dances.');
        } finally {
          await granted.dispose();
        }
      });
    });

    testWidgets('a missing video file rejects with an actionable error', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', videoJs);

        final granted = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(media: true),
          videoReader: fakeReader(env, FakeVideoApi()),
        );
        try {
          await granted.start();
          await Future<void>.delayed(settle);
          expect(
            jsonEncode(granted.exportedState?['result']),
            contains('no such file: clip.mp4'),
          );
        } finally {
          await granted.dispose();
        }
      });
    });
  });
}

/// Configurable fake [VideoApi] for the readVideo bridge tests.
final class FakeVideoApi implements VideoApi {
  bool available = true;
  final extractCalls = <({String path, int count})>[];

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<List<VideoFrame>> extractFrames({
    required String path,
    required int count,
  }) async {
    extractCalls.add((path: path, count: count));
    return [
      (bytes: Uint8List.fromList([1, 2, 3]), positionMs: 0),
    ];
  }
}
