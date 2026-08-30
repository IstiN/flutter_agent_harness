import 'dart:async';
import 'dart:convert';

import 'package:fa_llm/src/copilot/copilot_provider.dart';
import 'package:fa_llm/src/llm_message.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  const base = 'https://api.githubcopilot.com';
  final deltaPayload = (String content) =>
      '{"choices":[{"delta":{"content":"$content"}}]}';

  http.StreamedResponse sse(List<String> chunks) =>
      http.StreamedResponse(Stream.value(utf8.encode(chunks.join())), 200);

  group('SSE parsing helpers', () {
    test('splitter yields complete data payloads and keeps partial tails', () {
      final parser = SseParser();
      expect(
        parser.push(
          'data: ${deltaPayload('Hel')}\n\ndata: ${deltaPayload('lo')}\n\n',
        ),
        [deltaPayload('Hel'), deltaPayload('lo')],
      );
      // Frame split across chunks: partial tail must not be emitted.
      expect(parser.push('data: {"choices":[{"del'), isEmpty);
      expect(parser.push('ta":{"content":" wo"}}]}\n\ndata: [DONE]\n\n'), [
        '{"choices":[{"delta":{"content":" wo"}}]}',
        '[DONE]',
      ]);
    });

    test('splitter ignores comment and blank lines', () {
      final parser = SseParser();
      expect(parser.push(': keep-alive\n\ndata: x\n\n'), ['x']);
    });

    test('event parser extracts delta content and detects [DONE]', () {
      expect(sseDeltaContent(deltaPayload('hi')), 'hi');
      expect(sseDeltaContent('[DONE]'), isNull);
      expect(sseDeltaContent('{"choices":[{"delta":{}}]}'), isNull);
      expect(sseDeltaContent('not json'), isNull);
    });
  });

  group('CopilotProvider chat', () {
    test('sends mandatory headers and correct URL, parses content', () async {
      late Uri uri;
      late Map<String, String> headers;
      final client = MockClient((request) async {
        uri = request.url;
        headers = request.headers;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'Hello!'},
              },
            ],
          }),
          200,
        );
      });

      final provider = CopilotProvider(
        token: () async => 'copilot-tok',
        baseUrl: base,
        defaultModel: 'gpt-4o',
        client: client,
      );

      final result = await provider.chat('Say hi');

      expect(result, 'Hello!');
      expect(uri, Uri.parse('$base/chat/completions'));
      expect(headers['authorization'], 'Bearer copilot-tok');
      expect(headers['content-type'], 'application/json');
      expect(headers['copilot-integration-id'], 'vscode-chat');
      expect(headers['editor-version'], 'vscode/1.109.3');
      expect(headers['editor-plugin-version'], 'copilot-chat/0.37.6');
      expect(headers['user-agent'], 'GitHubCopilotChat/0.37.6');
      expect(headers['openai-intent'], 'conversation-agent');
      expect(headers['x-github-api-version'], '2025-10-01');
      expect(
        headers['x-request-id'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(headers['x-vscode-user-agent-library-version'], 'electron-fetch');
    });

    test(
      'X-Initiator is user by default and agent after assistant/tool',
      () async {
        final initiators = <String>[];
        final client = MockClient((request) async {
          initiators.add(request.headers['x-initiator']!);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok'},
                },
              ],
            }),
            200,
          );
        });
        final provider = CopilotProvider(
          token: () async => 't',
          baseUrl: base,
          defaultModel: 'm',
          client: client,
        );

        await provider.chatMessages([
          const LlmMessage(role: 'system', content: 'sys'),
          const LlmMessage(role: 'user', content: 'q'),
        ]);
        await provider.chatMessages([
          const LlmMessage(role: 'user', content: 'q'),
          const LlmMessage(role: 'assistant', content: 'a'),
        ]);
        await provider.chatMessages([
          const LlmMessage(role: 'user', content: 'q'),
          const LlmMessage(role: 'tool', content: 'r'),
        ]);

        expect(initiators, ['user', 'agent', 'agent']);
      },
    );

    test('Copilot-Vision-Request is sent only with image content', () async {
      final seen = <bool>[];
      final client = MockClient((request) async {
        seen.add(request.headers['copilot-vision-request'] == 'true');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
          200,
        );
      });
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      await provider.chatMessages([
        LlmMessage(
          role: 'user',
          content: 'look',
          images: ['data:image/png;base64,AAAA'],
        ),
      ]);
      await provider.chat('text only');

      expect(seen, [true, false]);
    });

    test(
      'payload carries model, messages, stream flag and max_tokens',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok'},
                },
              ],
            }),
            200,
          );
        });
        final provider = CopilotProvider(
          token: () async => 't',
          baseUrl: base,
          defaultModel: 'gpt-4o',
          maxTokens: 512,
          client: client,
        );
        await provider.chat('hi');
        await CopilotProvider(
          token: () async => 't',
          baseUrl: base,
          defaultModel: 'gpt-4o',
          client: client,
        ).chat('hi');

        expect(bodies[0]['model'], 'gpt-4o');
        expect(bodies[0]['max_tokens'], 512);
        expect(bodies[0]['stream'], isFalse);
        expect(bodies[1].containsKey('max_tokens'), isFalse);
      },
    );

    test('401 refreshes the token once and retries', () async {
      var tokenCalls = 0;
      var refreshCalls = 0;
      final authorizations = <String>[];
      var responses = 0;
      final client = MockClient((request) async {
        authorizations.add(request.headers['authorization']!);
        responses++;
        if (responses == 1) return http.Response('expired', 401);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'after refresh'},
              },
            ],
          }),
          200,
        );
      });
      final provider = CopilotProvider(
        token: () async => 't${++tokenCalls}',
        refresh: () async {
          refreshCalls++;
          return 't${++tokenCalls}';
        },
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      expect(await provider.chat('hi'), 'after refresh');
      expect(responses, 2);
      expect(refreshCalls, 1);
      expect(authorizations, ['Bearer t1', 'Bearer t2']);
    });

    test('403 follows the same refresh-once path', () async {
      var responses = 0;
      final client = MockClient((request) async {
        responses++;
        if (responses == 1) return http.Response('forbidden', 403);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
          200,
        );
      });
      final provider = CopilotProvider(
        token: () async => 't1',
        refresh: () async => 't2',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      expect(await provider.chat('hi'), 'ok');
      expect(responses, 2);
    });

    test('second 401 surfaces an error', () async {
      var refreshCalls = 0;
      final client = MockClient((_) async => http.Response('expired', 401));
      final provider = CopilotProvider(
        token: () async => 't1',
        refresh: () async {
          refreshCalls++;
          return 't2';
        },
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      await expectLater(
        provider.chat('hi'),
        throwsA(isA<CopilotChatException>()),
      );
      expect(refreshCalls, 1);
    });

    test('other errors carry status and body', () async {
      final client = MockClient((_) async => http.Response('boom', 500));
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      CopilotChatException exception;
      try {
        await provider.chat('hi');
        fail('expected error');
      } on CopilotChatException catch (e) {
        exception = e;
      }
      expect(exception.statusCode, 500);
      expect(exception.message, contains('boom'));
      expect(exception.toString(), contains('CopilotChatException(500)'));
    });
  });

  group('CopilotProvider streaming', () {
    test('streams deltas across chunk boundaries until [DONE]', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        final body = await utf8.decodeStream(bodyStream);
        expect(body, contains('"stream":true'));
        return sse([
          'data: ${deltaPayload('Hel')}\n\ndata: ${deltaPayload('lo')}\n\ndata: {"choices":[{"del',
          'ta":{"content":" wo"}}]}\n\ndata: [DONE]\n\n',
        ]);
      });
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      final events = await provider
          .chatStream('hi')
          .toList()
          .then((chunks) => chunks.join());

      expect(events, 'Hello wo');
    });

    test('chatMessagesStream works the same way', () async {
      final client = MockClient.streaming(
        (request, bodyStream) async => sse([
          'data: ${deltaPayload('a')}\n\ndata: ${deltaPayload('b')}\n\ndata: [DONE]\n\n',
        ]),
      );
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      final events = await provider.chatMessagesStream([
        const LlmMessage(role: 'user', content: 'q'),
      ]).join();

      expect(events, 'ab');
    });

    test('cancel closes the response and stops emitting immediately', () async {
      final server = StreamController<List<int>>();
      final client = MockClient.streaming(
        (request, bodyStream) async =>
            http.StreamedResponse(server.stream, 200),
      );
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      final events = <String>[];
      final subscription = provider.chatStream('hi').listen(events.add);
      await pumpEventQueue();

      server.add(utf8.encode('data: ${deltaPayload('first')}\n\n'));
      await pumpEventQueue();
      expect(events, ['first']);

      await provider.cancel();
      await pumpEventQueue();

      server.add(
        utf8.encode('data: ${deltaPayload('second')}\n\ndata: [DONE]\n\n'),
      );
      await pumpEventQueue();
      await server.close();
      await pumpEventQueue();

      expect(events, ['first']);
      expect(subscription.hashCode, isNotNull);
    });

    test('cancel without an active stream is a no-op', () async {
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: MockClient((_) async => http.Response('', 200)),
      );
      await provider.cancel();
    });
  });

  group('listModels', () {
    test('parses capabilities, limits and supported endpoints', () async {
      late Uri uri;
      final client = MockClient((request) async {
        uri = request.url;
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'gpt-4o',
                'capabilities': {
                  'limits': {
                    'max_context_window_tokens': 128000,
                    'max_output_tokens': 16384,
                  },
                },
                'supported_endpoints': ['/chat/completions', '/responses'],
              },
              {
                'id': 'claude-3.7-sonnet',
                'capabilities': {
                  'type': 'chat',
                  'limits': {'max_context_window_tokens': 200000},
                },
                'supported_endpoints': ['/chat/completions'],
              },
            ],
          }),
          200,
        );
      });
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );

      final models = await provider.listModels();

      expect(uri, Uri.parse('$base/models'));
      expect(models, hasLength(2));
      expect(models[0].id, 'gpt-4o');
      expect(models[0].maxContextWindowTokens, 128000);
      expect(models[0].maxOutputTokens, 16384);
      expect(models[0].supportedEndpoints, ['/chat/completions', '/responses']);
      expect(models[1].maxOutputTokens, isNull);
      expect(models[1].supportedEndpoints, ['/chat/completions']);
    });

    test('non-200 fails', () async {
      final client = MockClient((_) async => http.Response('no', 503));
      final provider = CopilotProvider(
        token: () async => 't',
        baseUrl: base,
        defaultModel: 'm',
        client: client,
      );
      await expectLater(provider.listModels(), throwsA(isA<Exception>()));
    });
  });
}
