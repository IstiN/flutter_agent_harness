import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/media_tools.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fallback = MediaFallback(
    providerKind: 'openai-completions',
    baseUrl: 'https://api.test/v1',
    modelId: 'gpt-5',
    apiKey: 'sk-main',
  );

  String textOf(ToolExecutionResult result) =>
      result.content.whereType<TextContent>().map((b) => b.text).join();

  MediaGateway gateway(
    MemoryExecutionEnv env,
    http.Client client, {
    MediaModelsStore? store,
  }) => MediaGateway(
    env: env,
    fallback: () => fallback,
    store: store ?? MediaModelsStore.inMemory(),
    httpClient: client,
  );

  group('generate_image', () {
    test('posts to /images/generations and saves the PNG', () async {
      final env = MemoryExecutionEnv();
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
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
      });
      final tool = generateImageTool(gateway(env, client));
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {'prompt': 'a teal robot', 'size': '1024x1024'},
        null,
        null,
      );

      expect(seen!.url.toString(), 'https://api.test/v1/images/generations');
      expect(seen!.headers['authorization'], 'Bearer sk-main');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-image-1'); // slot default, not the chat model
      expect(body['prompt'], 'a teal robot');
      expect(body['size'], '1024x1024');
      expect(body['response_format'], 'b64_json');

      final text = textOf(result);
      expect(text, contains('generated/image-'));
      expect(text, contains('.png'));
      expect(text, contains('3 bytes'));
      final path = RegExp(r'generated/\S+\.png').firstMatch(text)![0]!;
      // The result teaches the model the inline-display convention.
      expect(text, contains('Reference it as ![image]($path)'));
      final saved = await env.readBinaryFile(path);
      expect(saved.valueOrNull, [1, 2, 3]);
    });

    test('handles a URL payload (provider ignores response_format)', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'data': [
                {'url': 'https://cdn.test/img.png'},
              ],
            }),
            200,
          );
        }
        expect(request.url.toString(), 'https://cdn.test/img.png');
        return http.Response.bytes(Uint8List.fromList([9, 9]), 200);
      });
      final tool = generateImageTool(gateway(env, client));

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      expect(textOf(result), contains('2 bytes'));
    });

    test('unconfigured endpoint answers with an actionable error', () async {
      final env = MemoryExecutionEnv();
      var calls = 0;
      final client = http_testing.MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      });
      final onDeviceGateway = MediaGateway(
        env: env,
        fallback: () => const MediaFallback(
          providerKind: 'gemma',
          baseUrl: '',
          modelId: 'gemma3n',
          apiKey: '',
        ),
        store: MediaModelsStore.inMemory(),
        httpClient: client,
      );
      final tool = generateImageTool(onDeviceGateway);

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      final text = textOf(result);
      expect(text, startsWith('Error:'));
      expect(text, contains('media_models.json'));
      expect(text, contains('imageGeneration'));
      expect(calls, 0); // never hit the network
    });

    test('endpoint HTTP errors surface the status and body', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient(
        (request) async => http.Response('quota exceeded', 429),
      );
      final tool = generateImageTool(gateway(env, client));

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      expect(textOf(result), contains('HTTP 429'));
      expect(textOf(result), contains('quota exceeded'));
    });
  });

  group('speak', () {
    test('posts to /audio/speech and saves the mp3', () async {
      final env = MemoryExecutionEnv();
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response.bytes(
          Uint8List.fromList(List.filled(32000, 7)),
          200,
        );
      });
      final tool = speakTool(gateway(env, client));

      final result = await tool.execute(
        const {'text': 'hello world', 'voice': 'nova'},
        null,
        null,
      );

      expect(seen!.url.toString(), 'https://api.test/v1/audio/speech');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['model'], 'tts-1');
      expect(body['input'], 'hello world');
      expect(body['voice'], 'nova');

      final text = textOf(result);
      expect(text, contains('generated/speech-'));
      expect(text, contains('.mp3'));
      expect(text, contains('32000 bytes'));
      expect(text, contains('~2s')); // duration hint at ~16 KB/s
      final path = RegExp(r'generated/\S+\.mp3').firstMatch(text)![0]!;
      expect((await env.readBinaryFile(path)).valueOrNull, hasLength(32000));
    });

    test('defaults the voice to alloy', () async {
      final env = MemoryExecutionEnv();
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response.bytes(Uint8List.fromList([1]), 200);
      });
      final tool = speakTool(gateway(env, client));

      await tool.execute(const {'text': 'hi'}, null, null);
      expect(
        (jsonDecode(seen!.body) as Map<String, dynamic>)['voice'],
        'alloy',
      );
    });
  });

  group('generate_music', () {
    MediaModelsStore musicStore() {
      final store = MediaModelsStore.inMemory();
      store.setOverride(
        MediaSlot.musicGeneration,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://music.test/v1',
          modelId: 'music-1',
        ),
      );
      return store;
    }

    test('saves b64 audio from the configured endpoint', () async {
      final env = MemoryExecutionEnv();
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'data': [
              {
                'b64_json': base64Encode(Uint8List.fromList([5, 5, 5])),
              },
            ],
          }),
          200,
        );
      });
      final tool = generateMusicTool(gateway(env, client, store: musicStore()));

      final result = await tool.execute(
        const {'prompt': 'lo-fi loop', 'seconds': 20},
        null,
        null,
      );

      expect(seen!.url.toString(), 'https://music.test/v1/music/generations');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body, {
        'model': 'music-1',
        'prompt': 'lo-fi loop',
        'duration': 20,
      });
      // No apiKeyName on the slot → the main connection key rides along.
      expect(seen!.headers['authorization'], 'Bearer sk-main');

      final text = textOf(result);
      expect(text, contains('generated/music-'));
      expect(text, contains('3 bytes'));
    });

    test('saves audio fetched from a URL payload', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'data': [
                {'url': 'https://cdn.test/track.mp3'},
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(Uint8List.fromList([8, 8]), 200);
      });
      final tool = generateMusicTool(gateway(env, client, store: musicStore()));

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      expect(textOf(result), contains('2 bytes'));
    });

    test(
      'without a configured slot the error is honest and actionable',
      () async {
        final env = MemoryExecutionEnv();
        var calls = 0;
        final client = http_testing.MockClient((request) async {
          calls++;
          return http.Response('{}', 500);
        });
        // No musicGeneration override: there is no provider fallback for music.
        final tool = generateMusicTool(gateway(env, client));

        final result = await tool.execute(const {'prompt': 'x'}, null, null);
        final text = textOf(result);
        expect(text, startsWith('Error:'));
        expect(text, contains('media_models.json'));
        expect(text, contains('musicGeneration'));
        expect(calls, 0);
      },
    );
  });

  group('endpoint resolution shared with the store', () {
    test(
      'a slot override redirects the tool to its own endpoint + key',
      () async {
        final env = MemoryExecutionEnv();
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'b64_json': base64Encode(Uint8List.fromList([1])),
                },
              ],
            }),
            200,
          );
        });
        final store = MediaModelsStore.inMemory();
        await store.setOverride(
          MediaSlot.imageGeneration,
          const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://images.test/v1',
            modelId: 'dall-e-3',
            apiKeyName: 'IMAGES_KEY',
          ),
        );
        final tool = generateImageTool(
          MediaGateway(
            env: env,
            fallback: () => fallback,
            store: store,
            resolveKey: (name) async =>
                name == 'IMAGES_KEY' ? 'sk-images' : null,
            httpClient: client,
          ),
        );

        await tool.execute(const {'prompt': 'x'}, null, null);
        expect(
          seen!.url.toString(),
          'https://images.test/v1/images/generations',
        );
        expect(seen!.headers['authorization'], 'Bearer sk-images');
        expect(
          (jsonDecode(seen!.body) as Map<String, dynamic>)['model'],
          'dall-e-3',
        );
      },
    );
  });
}
