import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const okSse =
    'data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

final dialModel = Model(
  id: 'anthropic.claude-sonnet-4-5-20250929-v1:0',
  api: 'openai-completions',
  provider: 'dial',
  baseUrl: 'https://dial.example.com',
  reasoning: true,
  contextWindow: 200000,
  maxTokens: 16384,
);

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

/// A mock client answering [okSse] and recording the request (with the
/// request body, so payload assertions can run) for later checks.
(http.Client, List<({http.BaseRequest request, String body})>)
recordingClient() {
  final requests = <({http.BaseRequest request, String body})>[];
  final client = http_testing.MockClient.streaming((request, body) async {
    requests.add((request: request, body: await body.bytesToString()));
    return http.StreamedResponse(
      Stream.value(utf8.encode(okSse)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  return (client, requests);
}

Future<void> drain(AssistantMessageEventStream stream) async {
  await for (final _ in stream) {}
}

void main() {
  group('dialCompletionsUri', () {
    test('builds the deployments path with the model id', () {
      expect(
        dialCompletionsUri('https://dial.example.com', 'gpt-4o').toString(),
        'https://dial.example.com/openai/deployments/gpt-4o/chat/completions',
      );
    });

    test('strips trailing slashes from the base URL', () {
      expect(
        dialCompletionsUri('https://dial.example.com/', 'gpt-4o').toString(),
        'https://dial.example.com/openai/deployments/gpt-4o/chat/completions',
      );
    });

    test('appends api-version when configured', () {
      expect(
        dialCompletionsUri(
          'https://dial.example.com',
          'gpt-4o',
          apiVersion: '2024-02-01',
        ).toString(),
        'https://dial.example.com/openai/deployments/gpt-4o/chat/completions'
        '?api-version=2024-02-01',
      );
    });

    test('omits api-version when blank', () {
      expect(
        dialCompletionsUri(
          'https://dial.example.com',
          'gpt-4o',
          apiVersion: '  ',
        ).query,
        isEmpty,
      );
    });
  });

  group('streamDial', () {
    test('posts to the deployment URL with Api-Key auth (no Bearer)', () async {
      final (client, requests) = recordingClient();
      await drain(
        streamDial(
          dialModel,
          simpleContext(),
          const DialOptions(apiKey: 'dial-key-1'),
          client,
        ),
      );
      expect(requests, hasLength(1));
      final request = requests.single.request;
      expect(
        request.url.toString(),
        'https://dial.example.com/openai/deployments/'
        'anthropic.claude-sonnet-4-5-20250929-v1:0/chat/completions',
      );
      expect(request.headers['Api-Key'], 'dial-key-1');
      expect(request.headers.containsKey('authorization'), isFalse);
    });

    test('threads the api-version query parameter', () async {
      final (client, requests) = recordingClient();
      await drain(
        streamDial(
          dialModel,
          simpleContext(),
          const DialOptions(apiKey: 'k', apiVersion: '2025-01-01-preview'),
          client,
        ),
      );
      expect(
        requests.single.request.url.queryParameters['api-version'],
        '2025-01-01-preview',
      );
    });

    test(
      'adds cache_breakpoint markers (manual DIAL prompt caching)',
      () async {
        final (client, requests) = recordingClient();
        final context = Context(
          messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
          tools: [
            Tool(
              name: 'read',
              description: 'read a file',
              parameters: const {'type': 'object'},
            ),
            Tool(
              name: 'bash',
              description: 'run a command',
              parameters: const {'type': 'object'},
            ),
          ],
          systemPrompt: 'You are an agent.',
        );
        await drain(
          streamDial(
            dialModel,
            context,
            const DialOptions(apiKey: 'k'),
            client,
          ),
        );
        final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
        // System message carries the breakpoint.
        final system = (body['messages'] as List).whereType<Map>().firstWhere(
          (m) => m['role'] == 'system',
        );
        expect((system['custom_fields'] as Map)['cache_breakpoint'], isNotNull);
        // Exactly the LAST tool definition is marked.
        final tools = (body['tools'] as List).whereType<Map>().toList();
        expect(
          tools.first.containsKey('custom_fields'),
          isFalse,
          reason: 'only the last tool is marked',
        );
        expect(
          (tools.last['custom_fields'] as Map)['cache_breakpoint'],
          isNotNull,
        );
      },
    );

    test('skips cache markers under none retention', () async {
      final (client, requests) = recordingClient();
      final context = Context(
        messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
        systemPrompt: 'You are an agent.',
      );
      await drain(
        streamDial(
          dialModel,
          context,
          const DialOptions(apiKey: 'k', cacheRetention: 'none'),
          client,
        ),
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      final system = (body['messages'] as List).whereType<Map>().firstWhere(
        (m) => m['role'] == 'system',
      );
      expect(system.containsKey('custom_fields'), isFalse);
    });

    test(
      'retries marker-less after a cache-unsupported deployment error',
      () async {
        // First call answers 502 (deployment without cacheSupported), the
        // retry must succeed WITHOUT the marker; the process-wide switch
        // then keeps later calls marker-less from the start.
        var calls = 0;
        final bodies = <String>[];
        final client = http_testing.MockClient.streaming((request, body) async {
          calls++;
          bodies.add(await body.bytesToString());
          if (calls == 1) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('bad gateway')),
              502,
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(okSse)),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        });
        final context = Context(
          messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
          systemPrompt: 'You are an agent.',
        );
        final events = await streamDial(
          dialModel,
          context,
          const DialOptions(apiKey: 'k'),
          client,
        ).toList();
        expect(calls, 2, reason: 'one marker attempt + one retry');
        expect(events.last, isA<DoneEvent>());
        final first = jsonDecode(bodies[0]) as Map<String, dynamic>;
        final second = jsonDecode(bodies[1]) as Map<String, dynamic>;
        final firstSystem = (first['messages'] as List)
            .whereType<Map>()
            .firstWhere((m) => m['role'] == 'system');
        expect(firstSystem['custom_fields'], isNotNull);
        final secondSystem = (second['messages'] as List)
            .whereType<Map>()
            .firstWhere((m) => m['role'] == 'system');
        expect(secondSystem['custom_fields'], isNull);
      },
    );

    test('omits the tools strict field (strict request schema)', () async {
      final (client, requests) = recordingClient();
      final context = Context(
        messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
        tools: [
          Tool(
            name: 'read',
            description: 'read a file',
            parameters: const {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
              'required': ['path'],
            },
          ),
        ],
      );
      await drain(
        streamDial(dialModel, context, const DialOptions(apiKey: 'k'), client),
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      final tool = (body['tools'] as List).single as Map<String, dynamic>;
      expect(tool.containsKey('strict'), isFalse, reason: 'dial rejects it');
      expect(tool['type'], 'function');
    });

    test('streams text content', () async {
      final (client, _) = recordingClient();
      final events = await streamDial(
        dialModel,
        simpleContext(),
        const DialOptions(apiKey: 'k'),
        client,
      ).toList();
      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.stop);
      expect(
        done.message.content.whereType<TextContent>().map((b) => b.text).join(),
        'ok',
      );
    });
  });

  group('fetchDialModels', () {
    test('fetches {baseUrl}/openai/models with the Api-Key header', () async {
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          '{"data":[{"id":"gpt-4o"},{"id":"claude-sonnet"}]}',
          200,
        );
      });
      final ids = await fetchDialModels(
        'https://dial.example.com',
        'key-1',
        client: client,
      );
      expect(ids, ['claude-sonnet', 'gpt-4o']);
      expect(seen!.url.toString(), 'https://dial.example.com/openai/models');
      expect(seen!.headers['Api-Key'], 'key-1');
    });

    test('fetchDialModelsInfo reports the features.cache set', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(
          '{"data":['
          '{"id":"claude-x","features":{"cache":true,"auto_caching":false}},'
          '{"id":"gpt-terra","features":{"cache":false,"auto_caching":true}},'
          '{"id":"kimi-y","features":{"cache":false}}'
          ']}',
          200,
        ),
      );
      final (
        ids,
        cacheSupported,
        windows,
        maxTokens,
      ) = await fetchDialModelsInfo(
        'https://dial.example.com',
        'k',
        client: client,
      );
      expect(ids, containsAll(['claude-x', 'gpt-terra', 'kimi-y']));
      // Only the manual-cache flag lands in the set; auto-caching models
      // cache on their own and must NOT receive markers.
      expect(cacheSupported, {'claude-x'});
    });

    test(
      'fetchDialModelsInfo reports the limits maxima (not defaults)',
      () async {
        final client = http_testing.MockClient(
          (request) async => http.Response(
            '{"data":['
            '{"id":"terra","limits":{"max_prompt_tokens":200000,'
            '"max_completion_tokens":128000},"defaults":{}},'
            '{"id":"gemini","limits":{"max_total_tokens":999000,'
            '"max_completion_tokens":8192},'
            '"defaults":{"max_tokens":1000}},'
            '{"id":"claude","limits":{"max_total_tokens":200000},'
            '"defaults":{"max_tokens":64000}}'
            ']}',
            200,
          ),
        );
        final (ids, _, windows, maxTokens) = await fetchDialModelsInfo(
          'https://dial.example.com',
          'k',
          client: client,
        );
        expect(ids, containsAll(['terra', 'gemini', 'claude']));
        // The MAXIMUM ceilings from `limits` — never the smaller defaults.
        expect(windows['terra'], 200000);
        expect(windows['gemini'], 999000);
        expect(windows['claude'], 200000);
        expect(maxTokens['terra'], 128000);
        expect(maxTokens['gemini'], 8192);
        expect(
          maxTokens.containsKey('claude'),
          isFalse,
          reason: 'claude reports no completion cap',
        );
      },
    );

    test('cacheMarkersSupported=false never sends markers', () async {
      final (client, requests) = recordingClient();
      final context = Context(
        messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
        systemPrompt: 'You are an agent.',
      );
      await drain(
        streamDial(
          dialModel,
          context,
          const DialOptions(apiKey: 'k', cacheMarkersSupported: false),
          client,
        ),
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      final system = (body['messages'] as List).whereType<Map>().firstWhere(
        (m) => m['role'] == 'system',
      );
      expect(system.containsKey('custom_fields'), isFalse);
      expect(requests, hasLength(1), reason: 'no optimistic retry needed');
    });

    test('answers an empty list on failure', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('nope', 500),
      );
      expect(
        await fetchDialModels('https://dial.example.com', 'k', client: client),
        isEmpty,
      );
    });
  });
}
