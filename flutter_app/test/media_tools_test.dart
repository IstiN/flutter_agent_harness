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

  /// Answers every slot's named key. A slot override NEVER uses the main
  /// connection key ('sk-main') — only its own named key rides along.
  Future<String?> slotKeyResolver(String name) async =>
      name.endsWith('_KEY') ? 'sk-slot' : null;

  MediaGateway gateway(
    MemoryExecutionEnv env,
    http.Client client, {
    MediaModelsStore? store,
    MediaKeyResolver? resolveKey,
  }) => MediaGateway(
    env: env,
    fallback: () => fallback,
    store: store ?? MediaModelsStore.inMemory(),
    resolveKey: resolveKey ?? slotKeyResolver,
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

    MediaModelsStore ttsStore() {
      final store = MediaModelsStore.inMemory();
      store.setOverride(
        MediaSlot.audioTts,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.test/v1',
          modelId: 'tts-1',
          voice: 'af_heart',
          apiKeyName: 'TTS_KEY',
        ),
      );
      return store;
    }

    test(
      'uses the slot\'s configured voice when no argument is given',
      () async {
        final env = MemoryExecutionEnv();
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        });
        final tool = speakTool(gateway(env, client, store: ttsStore()));

        final result = await tool.execute(const {'text': 'hi'}, null, null);
        expect(
          (jsonDecode(seen!.body) as Map<String, dynamic>)['voice'],
          'af_heart',
        );
        expect(textOf(result), contains('voice "af_heart"'));
      },
    );

    test('an explicit voice argument overrides the configured voice', () async {
      final env = MemoryExecutionEnv();
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response.bytes(Uint8List.fromList([1]), 200);
      });
      final tool = speakTool(gateway(env, client, store: ttsStore()));

      await tool.execute(const {'text': 'hi', 'voice': 'nova'}, null, null);
      expect((jsonDecode(seen!.body) as Map<String, dynamic>)['voice'], 'nova');
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
          apiKeyName: 'MUSIC_KEY',
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
      // The slot's own named key — never the main connection's.
      expect(seen!.headers['authorization'], 'Bearer sk-slot');

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

  group('generate_video', () {
    MediaModelsStore videoStore() {
      final store = MediaModelsStore.inMemory();
      store.setOverride(
        MediaSlot.videoGeneration,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://video.test/v1',
          modelId: 'bytedance/seedance-1-5-pro',
          apiKeyName: 'VIDEO_KEY',
        ),
      );
      return store;
    }

    MediaGateway videoGateway(
      MemoryExecutionEnv env,
      http.Client client, {
      Duration? pollTimeout,
    }) => MediaGateway(
      env: env,
      fallback: () => fallback,
      store: videoStore(),
      resolveKey: slotKeyResolver,
      httpClient: client,
      videoPollInterval: const Duration(milliseconds: 5),
      videoPollTimeout: pollTimeout ?? const Duration(seconds: 5),
    );

    test('creates a job, polls until completed, saves the mp4', () async {
      final env = MemoryExecutionEnv();
      final seen = <http.Request>[];
      var polls = 0;
      final client = http_testing.MockClient((request) async {
        seen.add(request);
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 'job-1', 'status': 'pending'}),
            202,
          );
        }
        if (request.url.host == 'cdn.test') {
          return http.Response.bytes(Uint8List.fromList([7, 7, 7]), 200);
        }
        polls++;
        return http.Response(
          jsonEncode(
            polls < 2
                ? {'id': 'job-1', 'status': 'in_progress'}
                : {
                    'id': 'job-1',
                    'status': 'completed',
                    'unsigned_urls': ['https://cdn.test/clip.mp4'],
                  },
          ),
          200,
        );
      });
      final tool = generateVideoTool(videoGateway(env, client));
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {
          'prompt': 'a teal robot dances',
          'seconds': 8,
          'size': '1280x720',
        },
        null,
        null,
      );

      final post = seen.first;
      expect(post.url.toString(), 'https://video.test/v1/videos');
      expect(post.headers['authorization'], 'Bearer sk-slot');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body, {
        'model': 'bytedance/seedance-1-5-pro',
        'prompt': 'a teal robot dances',
        'duration': 8,
        'size': '1280x720',
      });
      // Two status polls, then the download from the job's unsigned_urls.
      expect(polls, 2);
      expect(seen.last.url.toString(), 'https://cdn.test/clip.mp4');

      final text = textOf(result);
      expect(text, contains('Video saved to generated/video-'));
      expect(text, contains('.mp4'));
      expect(text, contains('3 bytes'));
      expect(text, contains('8s, 1280x720'));
      final path = RegExp(r'generated/\S+\.mp4').firstMatch(text)![0]!;
      expect((await env.readBinaryFile(path)).valueOrNull, [7, 7, 7]);
    });

    test(
      'falls back to the authenticated content endpoint without URLs',
      () async {
        final env = MemoryExecutionEnv();
        final seen = <http.Request>[];
        final client = http_testing.MockClient((request) async {
          seen.add(request);
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({'id': 'job-9', 'status': 'queued'}),
              200,
            );
          }
          if (request.url.path.endsWith('/content')) {
            return http.Response.bytes(Uint8List.fromList([1, 2]), 200);
          }
          return http.Response(
            jsonEncode({'id': 'job-9', 'status': 'completed'}),
            200,
          );
        });
        final tool = generateVideoTool(videoGateway(env, client));

        final result = await tool.execute(const {'prompt': 'x'}, null, null);

        final content = seen.last;
        expect(
          content.url.toString(),
          'https://video.test/v1/videos/job-9/content',
        );
        expect(content.headers['authorization'], 'Bearer sk-slot');
        expect(textOf(result), contains('2 bytes'));
        expect(textOf(result), contains('provider defaults'));
      },
    );

    test('the job\'s own-origin url (OpenRouter .../content?index=0) is '
        'fetched WITH auth — as-is fetching 401s', () async {
      final env = MemoryExecutionEnv();
      final seen = <http.Request>[];
      final client = http_testing.MockClient((request) async {
        seen.add(request);
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 'job-7', 'status': 'queued'}),
            202,
          );
        }
        if (request.url.path.endsWith('/content')) {
          return http.Response.bytes(Uint8List.fromList([9, 9, 9, 9]), 200);
        }
        return http.Response(
          jsonEncode({
            'id': 'job-7',
            'status': 'completed',
            // OpenRouter's completed job: an authenticated content URL,
            // not a public unsigned link.
            'url': 'https://video.test/v1/videos/job-7/content?index=0',
          }),
          200,
        );
      });
      final tool = generateVideoTool(videoGateway(env, client));

      final result = await tool.execute(const {'prompt': 'x'}, null, null);

      final download = seen.last;
      expect(
        download.url.toString(),
        'https://video.test/v1/videos/job-7/content?index=0',
      );
      expect(download.headers['authorization'], 'Bearer sk-slot');
      expect(textOf(result), contains('4 bytes'));
    });

    test('a failed job surfaces the endpoint error', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'job-2'}), 202);
        }
        return http.Response(
          jsonEncode({
            'id': 'job-2',
            'status': 'failed',
            'error': 'Content policy violation',
          }),
          200,
        );
      });
      final tool = generateVideoTool(videoGateway(env, client));

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      final text = textOf(result);
      expect(text, startsWith('Error:'));
      expect(text, contains('failed'));
      expect(text, contains('Content policy violation'));
    });

    test('a job that never completes times out', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'job-3'}), 202);
        }
        return http.Response(
          jsonEncode({'id': 'job-3', 'status': 'pending'}),
          200,
        );
      });
      final tool = generateVideoTool(
        videoGateway(
          env,
          client,
          pollTimeout: const Duration(milliseconds: 20),
        ),
      );

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      final text = textOf(result);
      expect(text, startsWith('Error:'));
      expect(text, contains('timed out'));
      expect(text, contains('job-3'));
    });

    test('create-endpoint HTTP errors surface the status and body', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient(
        (request) async => http.Response('model not found', 404),
      );
      final tool = generateVideoTool(videoGateway(env, client));

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      expect(textOf(result), contains('HTTP 404'));
      expect(textOf(result), contains('model not found'));
    });

    test('a cancelled token aborts the wait', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'job-4'}), 202);
        }
        return http.Response(
          jsonEncode({'id': 'job-4', 'status': 'pending'}),
          200,
        );
      });
      final tool = generateVideoTool(videoGateway(env, client));
      final source = CancelTokenSource()..cancel('user stopped');

      await expectLater(
        tool.execute(const {'prompt': 'x'}, source.token, null),
        throwsA(isA<CancelledException>()),
      );
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
        // No videoGeneration override: there is no provider fallback for video.
        final tool = generateVideoTool(gateway(env, client));

        final result = await tool.execute(const {'prompt': 'x'}, null, null);
        final text = textOf(result);
        expect(text, startsWith('Error:'));
        expect(text, contains('media_models.json'));
        expect(text, contains('videoGeneration'));
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

  group('google (generativelanguage) endpoints', () {
    const googleBaseUrl = 'https://generativelanguage.googleapis.com/v1beta';

    MediaGateway googleGateway(
      MemoryExecutionEnv env,
      http.Client client, {
      required String slot,
      String modelId = 'gemini-2.5-flash-preview-tts',
      String? voice,
    }) {
      final store = MediaModelsStore.inMemory();
      store.setOverride(
        slot,
        MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: googleBaseUrl,
          modelId: modelId,
          apiKeyName: 'GEMINI_API_KEY',
          voice: voice,
        ),
      );
      return MediaGateway(
        env: env,
        fallback: () => fallback,
        store: store,
        resolveKey: (name) async =>
            name == 'GEMINI_API_KEY' ? 'goog-key' : null,
        httpClient: client,
      );
    }

    http_testing.MockClient geminiTtsClient(
      Uint8List pcm,
      void Function(http.Request) onRequest,
    ) => http_testing.MockClient((request) async {
      onRequest(request);
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'inlineData': {
                      'mimeType': 'audio/L16;rate=24000',
                      'data': base64Encode(pcm),
                    },
                  },
                ],
              },
            },
          ],
        }),
        200,
      );
    });

    test(
      'speak posts Gemini generateContent and saves a wrapped wav',
      () async {
        final env = MemoryExecutionEnv();
        http.Request? seen;
        final pcm = Uint8List.fromList([1, 2, 3, 4]);
        final client = geminiTtsClient(pcm, (request) => seen = request);
        final tool = speakTool(
          googleGateway(env, client, slot: MediaSlot.audioTts),
        );

        final result = await tool.execute(const {'text': 'hello'}, null, null);

        expect(
          seen!.url.toString(),
          '$googleBaseUrl/models/gemini-2.5-flash-preview-tts:generateContent',
        );
        expect(seen!.headers['x-goog-api-key'], 'goog-key');
        expect(seen!.headers['authorization'], isNull);
        final body = jsonDecode(seen!.body) as Map<String, dynamic>;
        expect(body['contents'], [
          {
            'parts': [
              {'text': 'hello'},
            ],
          },
        ]);
        final config = body['generationConfig'] as Map<String, dynamic>;
        expect(config['responseModalities'], ['AUDIO']);
        expect(
          (config['speechConfig'] as Map<String, dynamic>)['voiceConfig'],
          {
            'prebuiltVoiceConfig': {'voiceName': 'Kore'},
          },
        );

        final text = textOf(result);
        expect(text, contains('generated/speech-'));
        expect(text, contains('.wav'));
        expect(text, contains('voice "Kore"'));
        final path = RegExp(r'generated/\S+\.wav').firstMatch(text)![0]!;
        final saved = (await env.readBinaryFile(path)).valueOrNull!;
        expect(saved, hasLength(44 + pcm.length));
        expect(String.fromCharCodes(saved.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(saved.sublist(8, 12)), 'WAVE');
        expect(saved.sublist(44), pcm);
        // The fmt chunk describes LINEAR16 PCM, 24 kHz mono.
        final header = ByteData.sublistView(saved);
        expect(header.getUint16(20, Endian.little), 1);
        expect(header.getUint16(22, Endian.little), 1);
        expect(header.getUint32(24, Endian.little), 24000);
        expect(header.getUint16(34, Endian.little), 16);
        expect(header.getUint32(40, Endian.little), pcm.length);
      },
    );

    test('speak on google: the argument wins, then the slot voice', () async {
      final env = MemoryExecutionEnv();
      final bodies = <Map<String, dynamic>>[];
      final client = geminiTtsClient(Uint8List.fromList([0]), (request) {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      });
      final tool = speakTool(
        googleGateway(env, client, slot: MediaSlot.audioTts, voice: 'Aoede'),
      );

      await tool.execute(const {'text': 'a'}, null, null);
      await tool.execute(const {'text': 'b', 'voice': 'Zephyr'}, null, null);

      String voiceOf(Map<String, dynamic> body) =>
          ((body['generationConfig'] as Map<String, dynamic>)['speechConfig']
                  as Map<String, dynamic>)['voiceConfig']
              .toString();
      expect(voiceOf(bodies[0]), contains('Aoede'));
      expect(voiceOf(bodies[1]), contains('Zephyr'));
    });

    test(
      'generateMusic posts to /interactions and deep-finds the audio',
      () async {
        final env = MemoryExecutionEnv();
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'outputs': [
                {'type': 'text', 'text': 'composing'},
                {
                  'type': 'audio',
                  'data': base64Encode(Uint8List.fromList([5, 5, 5])),
                },
              ],
            }),
            200,
          );
        });
        final tool = generateMusicTool(
          googleGateway(
            env,
            client,
            slot: MediaSlot.musicGeneration,
            modelId: 'lyria-2',
          ),
        );

        final result = await tool.execute(
          const {'prompt': 'lo-fi loop'},
          null,
          null,
        );

        expect(seen!.url.toString(), '$googleBaseUrl/interactions');
        expect(seen!.headers['x-goog-api-key'], 'goog-key');
        expect(jsonDecode(seen!.body), {
          'model': 'lyria-2',
          'input': 'lo-fi loop',
        });
        final text = textOf(result);
        expect(text, contains('generated/music-'));
        expect(text, contains('.mp3'));
        expect(text, contains('3 bytes'));
        final path = RegExp(r'generated/\S+\.mp3').firstMatch(text)![0]!;
        expect((await env.readBinaryFile(path)).valueOrNull, [5, 5, 5]);
      },
    );

    test('generateMusic finds output_audio-style blocks too', () async {
      final env = MemoryExecutionEnv();
      final client = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'result': {
              'output_audio': {
                'data': base64Encode(Uint8List.fromList([7, 7])),
              },
            },
          }),
          200,
        );
      });
      final tool = generateMusicTool(
        googleGateway(env, client, slot: MediaSlot.musicGeneration),
      );

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      expect(textOf(result), contains('2 bytes'));
    });

    test(
      'generateMusic without audio in the response errors honestly',
      () async {
        final env = MemoryExecutionEnv();
        final client = http_testing.MockClient(
          (request) async => http.Response(jsonEncode({'outputs': []}), 200),
        );
        final tool = generateMusicTool(
          googleGateway(env, client, slot: MediaSlot.musicGeneration),
        );

        final result = await tool.execute(const {'prompt': 'x'}, null, null);
        final text = textOf(result);
        expect(text, startsWith('Error:'));
        expect(text, contains('no audio payload'));
      },
    );

    test('generateImage on google is an honest not-supported error', () async {
      final env = MemoryExecutionEnv();
      var calls = 0;
      final client = http_testing.MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      });
      final tool = generateImageTool(
        googleGateway(env, client, slot: MediaSlot.imageGeneration),
      );

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      final text = textOf(result);
      expect(text, startsWith('Error:'));
      expect(text, contains('not supported for the Google provider yet'));
      expect(calls, 0);
    });

    test('generateVideo on google is an honest not-supported error', () async {
      final env = MemoryExecutionEnv();
      var calls = 0;
      final client = http_testing.MockClient((request) async {
        calls++;
        return http.Response('{}', 500);
      });
      final tool = generateVideoTool(
        googleGateway(env, client, slot: MediaSlot.videoGeneration),
      );

      final result = await tool.execute(const {'prompt': 'x'}, null, null);
      final text = textOf(result);
      expect(text, startsWith('Error:'));
      expect(text, contains('not supported for the Google provider yet'));
      expect(calls, 0);
    });
  });
}
