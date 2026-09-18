import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/tools/generate_image.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Captures the outgoing request and answers [statusCode] with a body whose
/// `data[0].b64_json` decodes to [imageBytes] when [imageBytes] is non-null.
/// With [minimax], the response is `{ "data": { "image_base64": [...] } }`.
http.Client _captureClient(
  void Function(http.BaseRequest request, String body) onRequest, {
  int statusCode = 200,
  Uint8List? imageBytes,
  bool minimax = false,
  Object? payload,
}) {
  return http_testing.MockClient.streaming((request, bodyStream) async {
    final bodyText = await bodyStream.bytesToString();
    onRequest(request, bodyText);
    final bodyJson =
        payload ??
        (imageBytes == null
            ? {
                'data': [
                  {'url': 'https://example.com/img.png'},
                ],
              }
            : minimax
            ? {
                'data': {
                  'image_base64': [base64Encode(imageBytes)],
                },
              }
            : {
                'data': [
                  {'b64_json': base64Encode(imageBytes)},
                ],
              });
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(bodyJson))),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  group('generateImageTool', () {
    late MemoryExecutionEnv env;

    setUp(() {
      env = MemoryExecutionEnv();
    });

    ModelsConfig slotConfig(String model, {String? apiKeyName}) => ModelsConfig(
      slots: {
        'imageGeneration': MediaSlotModelConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.example.com/v1',
          modelId: model,
          apiKeyName: apiKeyName,
        ),
      },
    );

    test('generates an image via the imageGeneration slot override', () async {
      http.BaseRequest? seenRequest;
      String? seenBody;
      final tool = generateImageTool(
        env: env,
        modelsConfig: slotConfig('MiniMax-M3', apiKeyName: 'MINIMAX_KEY'),
        mainBaseUrl: () => 'https://main.example/v1',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        resolveKey: (name) async => name == 'MINIMAX_KEY' ? 'slot-key' : null,
        httpClient: _captureClient((request, body) {
          seenRequest = request;
          seenBody = body;
        }, imageBytes: Uint8List.fromList([1, 2, 3])),
      );

      final result = await tool.execute({'prompt': 'a red apple'}, null, null);

      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('saved image to generated/images_'));
      expect(text, contains('.png'));

      // The image content is staged as base64 + mime, not a bare path.
      final image = result.content.whereType<ImageContent>().single;
      expect(image.mimeType, 'image/png');
      expect(base64Decode(image.data), [1, 2, 3]);

      final request = seenRequest!;
      expect(request.method, 'POST');
      // The slot's own named key — never the main provider's.
      expect(request.headers['authorization'], 'Bearer slot-key');
      expect(
        request.url.toString(),
        'https://api.example.com/v1/images/generations',
      );
      expect(request.headers['authorization'], 'Bearer slot-key');
      final body = jsonDecode(seenBody!) as Map<String, dynamic>;
      expect(body['model'], 'MiniMax-M3');
      expect(body['prompt'], 'a red apple');
    });

    test(
      'resolves the slot apiKeyName through the resolveKey callback',
      () async {
        final tool = generateImageTool(
          env: env,
          modelsConfig: slotConfig('MiniMax-M3', apiKeyName: 'MINIMAX_KEY'),
          mainBaseUrl: () => 'https://main.example/v1',
          mainModelId: () => 'main-model',
          mainApiKey: () => 'main-key',
          resolveKey: (name) async => name == 'MINIMAX_KEY' ? 'slot-key' : null,
          httpClient: _captureClient(
            (request, body) {},
            imageBytes: Uint8List.fromList([9]),
          ),
        );

        final result = await tool.execute({'prompt': 'x'}, null, null);
        expect(result.content.whereType<TextContent>(), isNotEmpty);
      },
    );

    test(
      'falls back to the main connection when no slot override exists',
      () async {
        http.BaseRequest? seenRequest;
        final tool = generateImageTool(
          env: env,
          modelsConfig: ModelsConfig(),
          mainBaseUrl: () => 'https://main.example/v1',
          mainModelId: () => 'main-model',
          mainApiKey: () => 'main-key',
          httpClient: _captureClient((request, body) {
            seenRequest = request;
          }, imageBytes: Uint8List.fromList([5])),
        );

        await tool.execute({'prompt': 'x'}, null, null);
        expect(
          seenRequest!.url.toString(),
          'https://main.example/v1/images/generations',
        );
        expect(seenRequest!.headers['authorization'], 'Bearer main-key');
      },
    );

    test('throws when the endpoint errors', () async {
      final tool = generateImageTool(
        env: env,
        modelsConfig: slotConfig('MiniMax-M3', apiKeyName: 'K'),
        mainBaseUrl: () => 'https://main.example/v1',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        resolveKey: (name) async => 'k',
        httpClient: _captureClient((request, body) {}, statusCode: 500),
      );

      expect(
        () => tool.execute({'prompt': 'x'}, null, null),
        throwsA(isA<MediaException>()),
      );
    });

    test('throws when prompt is empty', () async {
      final tool = generateImageTool(
        env: env,
        modelsConfig: slotConfig('MiniMax-M3'),
        mainBaseUrl: () => 'https://main.example/v1',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        httpClient: _captureClient((request, body) {}),
      );

      expect(
        () => tool.execute({'prompt': '   '}, null, null),
        throwsA(isA<MediaException>()),
      );
    });

    test('uses the MiniMax dialect for minimax endpoints', () async {
      http.BaseRequest? seenRequest;
      String? seenBody;
      final tool = generateImageTool(
        env: env,
        modelsConfig: ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://api.minimax.io/v1',
              modelId: 'image-01',
              apiKeyName: 'MINIMAX_API_KEY',
            ),
          },
        ),
        mainBaseUrl: () => 'https://main.example/v1',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        resolveKey: (name) async => name == 'MINIMAX_API_KEY' ? 'mm-key' : null,
        httpClient: _captureClient(
          (request, body) {
            seenRequest = request;
            seenBody = body;
          },
          // MiniMax returns { "data": { "image_base64": [...] } }.
          imageBytes: Uint8List.fromList([7, 8, 9]),
          minimax: true,
        ),
      );

      final result = await tool.execute(
        {'prompt': 'a cat', 'size': '1024x1024'},
        null,
        null,
      );

      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('saved image to generated/images_'));
      final image = result.content.whereType<ImageContent>().single;
      expect(base64Decode(image.data), [7, 8, 9]);

      final request = seenRequest!;
      expect(
        request.url.toString(),
        'https://api.minimax.io/v1/image_generation',
      );
      final body = jsonDecode(seenBody!) as Map<String, dynamic>;
      expect(body['model'], 'image-01');
      expect(body['aspect_ratio'], '1:1');
      expect(body['response_format'], 'base64');
    });

    test('surfaces MiniMax base_resp errors hidden behind HTTP 200', () async {
      // MiniMax answers HTTP 200 with the failure inside the body:
      // {"base_resp":{"status_code":1004,"status_msg":"login fail: ..."}}.
      final tool = generateImageTool(
        env: env,
        modelsConfig: ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://api.minimax.io/v1',
              modelId: 'image-01',
              apiKeyName: 'MINIMAX_API_KEY',
            ),
          },
        ),
        mainBaseUrl: () => 'https://main.example/v1',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        resolveKey: (name) async => name == 'MINIMAX_API_KEY' ? 'mm-key' : null,
        httpClient: _captureClient(
          (request, body) {},
          payload: {
            'base_resp': {
              'status_code': 1004,
              'status_msg': 'login fail: Please carry the API secret key',
            },
          },
        ),
      );

      await expectLater(
        () => tool.execute({'prompt': 'a cat'}, null, null),
        throwsA(
          isA<MediaException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('1004'),
              contains('login fail: Please carry the API secret key'),
              contains('apiKeyName'),
            ),
          ),
        ),
      );
    });

    test('accepts a zero base_resp alongside the image data', () async {
      final tool = generateImageTool(
        env: env,
        modelsConfig: ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://api.minimax.io/v1',
              modelId: 'image-01',
              apiKeyName: 'MINIMAX_API_KEY',
            ),
          },
        ),
        mainBaseUrl: () => 'https://main.example/v1',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        resolveKey: (name) async => name == 'MINIMAX_API_KEY' ? 'mm-key' : null,
        httpClient: _captureClient(
          (request, body) {},
          imageBytes: Uint8List.fromList([4, 5]),
          minimax: true,
          payload: {
            'base_resp': {'status_code': 0, 'status_msg': 'success'},
            'data': {
              'image_base64': [
                base64Encode([4, 5]),
              ],
            },
          },
        ),
      );

      final result = await tool.execute({'prompt': 'a cat'}, null, null);
      final image = result.content.whereType<ImageContent>().single;
      expect(base64Decode(image.data), [4, 5]);
    });

    test(
      'a slot override without apiKeyName never takes the main key',
      () async {
        final tool = generateImageTool(
          env: env,
          modelsConfig: slotConfig('MiniMax-M3'),
          mainBaseUrl: () => 'https://main.example/v1',
          mainModelId: () => 'main-model',
          mainApiKey: () => 'main-key',
          httpClient: _captureClient((request, body) {}, statusCode: 500),
        );

        await expectLater(
          () => tool.execute({'prompt': 'x'}, null, null),
          throwsA(
            isA<MediaException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('no resolvable API key'),
                contains('never uses the main provider key'),
                contains('apiKeyName'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'an unresolvable slot apiKeyName fails without falling back',
      () async {
        final tool = generateImageTool(
          env: env,
          modelsConfig: slotConfig('MiniMax-M3', apiKeyName: 'MISSING_KEY'),
          mainBaseUrl: () => 'https://main.example/v1',
          mainModelId: () => 'main-model',
          mainApiKey: () => 'main-key',
          resolveKey: (name) async => null,
          httpClient: _captureClient((request, body) {}, statusCode: 500),
        );

        await expectLater(
          () => tool.execute({'prompt': 'x'}, null, null),
          throwsA(
            isA<MediaException>().having(
              (e) => e.message,
              'message',
              allOf(contains('MISSING_KEY'), contains('never uses the main')),
            ),
          ),
        );
      },
    );

    test('uses the DIAL dialect for ai-proxy/dial endpoints', () async {
      http.BaseRequest? seenPostRequest;
      String? seenPostBody;
      http.BaseRequest? seenGetRequest;

      final dialClient = http_testing.MockClient((request) async {
        if (request.method == 'POST') {
          seenPostRequest = request;
          seenPostBody = request.body;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'custom_content': {
                      'attachments': [
                        {
                          'type': 'image/png',
                          'url': 'files/test/img.png',
                        },
                      ],
                    },
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET') {
          seenGetRequest = request;
          return http.Response.bytes(
            Uint8List.fromList([10, 20, 30]),
            200,
            headers: {'content-type': 'image/png'},
          );
        }
        return http.Response('not found', 404);
      });

      final tool = generateImageTool(
        env: env,
        modelsConfig: ModelsConfig(
          slots: {
            'imageGeneration': MediaSlotModelConfig(
              providerKind: 'openai-completions',
              baseUrl: 'https://ai-proxy.lab.epam.com',
              modelId: 'gpt-image-2-2026-04-21',
              apiKeyName: 'DIAL_API_KEY',
            ),
          },
        ),
        mainBaseUrl: () => 'https://ai-proxy.lab.epam.com',
        mainModelId: () => 'main-model',
        mainApiKey: () => 'main-key',
        resolveKey: (name) async => name == 'DIAL_API_KEY' ? 'dial-key' : null,
        httpClient: dialClient,
      );

      final result = await tool.execute({'prompt': 'a dragon'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('saved image to generated/images_'));
      final image = result.content.whereType<ImageContent>().single;
      expect(base64Decode(image.data), [10, 20, 30]);

      expect(seenPostRequest!.method, 'POST');
      expect(
        seenPostRequest!.url.toString(),
        'https://ai-proxy.lab.epam.com/openai/deployments/gpt-image-2-2026-04-21/chat/completions',
      );
      expect(seenPostRequest!.headers['api-key'], 'dial-key');
      expect(seenPostBody, contains('a dragon'));

      expect(seenGetRequest!.method, 'GET');
      expect(
        seenGetRequest!.url.toString(),
        'https://ai-proxy.lab.epam.com/v1/files/test/img.png',
      );
      expect(seenGetRequest!.headers['api-key'], 'dial-key');
    });

    test(
      'slot override with matching host falls back to main key when apiKeyName is omitted',
      () async {
        http.BaseRequest? seenRequest;
        final dialClient = http_testing.MockClient((request) async {
          seenRequest = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'custom_content': {
                      'attachments': [
                        {'b64_json': base64Encode([1, 2])},
                      ],
                    },
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final tool = generateImageTool(
          env: env,
          modelsConfig: ModelsConfig(
            slots: {
              'imageGeneration': MediaSlotModelConfig(
                providerKind: 'openai-completions',
                baseUrl: 'https://ai-proxy.lab.epam.com',
                modelId: 'gpt-image-2-2026-04-21',
              ),
            },
          ),
          mainBaseUrl: () => 'https://ai-proxy.lab.epam.com',
          mainModelId: () => 'claude-sonnet',
          mainApiKey: () => 'dial-main-key',
          httpClient: dialClient,
        );

        final result = await tool.execute({'prompt': 'a rose'}, null, null);
        expect(result.content.whereType<ImageContent>(), isNotEmpty);
        expect(seenRequest!.headers['api-key'], 'dial-main-key');
      },
    );
  });
}
