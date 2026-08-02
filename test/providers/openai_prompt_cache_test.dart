import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const _okSse =
    'data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

/// A transport that captures the request body/headers and answers [_okSse].
final class _Capture {
  Map<String, dynamic>? body;
  Map<String, String>? headers;

  http.Client get client => http_testing.MockClient.streaming((
    request,
    requestBody,
  ) async {
    headers = request.headers;
    body =
        jsonDecode(await requestBody.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_okSse)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

final _openAiModel = Model(
  id: 'gpt-4o-mini',
  name: 'GPT-4o mini',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  input: const ['text', 'image'],
  contextWindow: 128000,
  maxTokens: 16384,
);

final _openRouterModel = Model(
  id: 'openai/gpt-4o',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  contextWindow: 200000,
  maxTokens: 16384,
);

final _openRouterAnthropicModel = Model(
  id: 'anthropic/claude-sonnet-4',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  reasoning: true,
  input: const ['text', 'image'],
  contextWindow: 200000,
  maxTokens: 64000,
);

Context _context() => Context(
  systemPrompt: 'you are helpful',
  messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
  tools: const [
    Tool(name: 'a', description: 'tool a', parameters: {'type': 'object'}),
    Tool(name: 'b', description: 'tool b', parameters: {'type': 'object'}),
  ],
);

/// Streams one completion over [capture] and returns the decoded request.
Future<Map<String, dynamic>> _request(
  Model model,
  _Capture capture,
  OpenAICompletionsOptions options,
) async {
  final stream = streamOpenAICompletions(
    model,
    _context(),
    options,
    capture.client,
  );
  await stream.toList();
  return capture.body!;
}

void main() {
  group('prompt_cache_key', () {
    test('sends the session id on OpenAI endpoints (short default)', () async {
      final capture = _Capture();
      final body = await _request(
        _openAiModel,
        capture,
        const OpenAICompletionsOptions(sessionId: 'session-1'),
      );
      expect(body['prompt_cache_key'], 'session-1');
      expect(body.containsKey('prompt_cache_retention'), isFalse);
    });

    test('clamps the key to 64 characters', () async {
      final capture = _Capture();
      final longId = 'x' * 100;
      final body = await _request(
        _openAiModel,
        capture,
        OpenAICompletionsOptions(sessionId: longId),
      );
      expect(body['prompt_cache_key'], 'x' * 64);
    });

    test('is absent without a session id', () async {
      final capture = _Capture();
      final body = await _request(
        _openAiModel,
        capture,
        const OpenAICompletionsOptions(),
      );
      expect(body.containsKey('prompt_cache_key'), isFalse);
    });

    test('is absent under retention none, with no affinity header', () async {
      final capture = _Capture();
      final body = await _request(
        _openRouterModel,
        capture,
        const OpenAICompletionsOptions(
          sessionId: 'session-1',
          cacheRetention: 'none',
        ),
      );
      expect(body.containsKey('prompt_cache_key'), isFalse);
      expect(body.containsKey('prompt_cache_retention'), isFalse);
      expect(capture.headers!['x-session-id'], isNull);
    });

    test(
      'is not sent for non-OpenAI endpoints under short retention',
      () async {
        final capture = _Capture();
        final body = await _request(
          _openRouterModel,
          capture,
          const OpenAICompletionsOptions(sessionId: 'session-1'),
        );
        expect(body.containsKey('prompt_cache_key'), isFalse);
        expect(body.containsKey('prompt_cache_retention'), isFalse);
      },
    );

    test('long retention sends the key and 24h retention everywhere', () async {
      final capture = _Capture();
      final body = await _request(
        _openRouterModel,
        capture,
        const OpenAICompletionsOptions(
          sessionId: 'session-1',
          cacheRetention: 'long',
        ),
      );
      expect(body['prompt_cache_key'], 'session-1');
      expect(body['prompt_cache_retention'], '24h');
    });
  });

  group('session-affinity headers', () {
    test('sends x-session-id on OpenRouter base URLs', () async {
      final capture = _Capture();
      await _request(
        _openRouterModel,
        capture,
        const OpenAICompletionsOptions(sessionId: 'session-1'),
      );
      expect(capture.headers!['x-session-id'], 'session-1');
    });

    test('is not sent to non-OpenRouter endpoints', () async {
      final capture = _Capture();
      await _request(
        _openAiModel,
        capture,
        const OpenAICompletionsOptions(sessionId: 'session-1'),
      );
      expect(capture.headers!['x-session-id'], isNull);
    });
  });

  group('anthropic cache_control markers (OpenRouter anthropic/* models)', () {
    List<dynamic> messagesOf(Map<String, dynamic> body) {
      return body['messages'] as List<dynamic>;
    }

    test(
      'marks system prompt, last tool, and last conversation text',
      () async {
        final capture = _Capture();
        final body = await _request(
          _openRouterAnthropicModel,
          capture,
          const OpenAICompletionsOptions(sessionId: 'session-1'),
        );
        const marker = {'type': 'ephemeral'};

        final messages = messagesOf(body);
        final system = messages.first as Map<String, dynamic>;
        expect(system['role'], 'system');
        // Plain-string content is wrapped into a marked text part.
        expect(system['content'], [
          {'type': 'text', 'text': 'you are helpful', 'cache_control': marker},
        ]);

        final tools = body['tools'] as List<dynamic>;
        expect((tools[0] as Map).containsKey('cache_control'), isFalse);
        expect((tools[1] as Map)['cache_control'], marker);

        final last = messages.last as Map<String, dynamic>;
        expect(last['role'], 'user');
        expect(last['content'], [
          {'type': 'text', 'text': 'hi', 'cache_control': marker},
        ]);
      },
    );

    test('long retention adds a 1h ttl to the markers', () async {
      final capture = _Capture();
      final body = await _request(
        _openRouterAnthropicModel,
        capture,
        const OpenAICompletionsOptions(cacheRetention: 'long'),
      );
      const marker = {'type': 'ephemeral', 'ttl': '1h'};
      final tools = body['tools'] as List<dynamic>;
      expect((tools[1] as Map)['cache_control'], marker);
      final last = messagesOf(body).last as Map<String, dynamic>;
      expect((last['content'] as List).last, {
        'type': 'text',
        'text': 'hi',
        'cache_control': marker,
      });
    });

    test('retention none places no markers at all', () async {
      final capture = _Capture();
      final body = await _request(
        _openRouterAnthropicModel,
        capture,
        const OpenAICompletionsOptions(cacheRetention: 'none'),
      );
      final messages = messagesOf(body);
      final system = messages.first as Map<String, dynamic>;
      expect(system['content'], 'you are helpful');
      final tools = body['tools'] as List<dynamic>;
      expect((tools[1] as Map).containsKey('cache_control'), isFalse);
      final last = messages.last as Map<String, dynamic>;
      expect(last['content'], 'hi');
    });

    test('non-anthropic OpenRouter models get no markers', () async {
      final capture = _Capture();
      final body = await _request(
        _openRouterModel,
        capture,
        const OpenAICompletionsOptions(),
      );
      final messages = messagesOf(body);
      expect((messages.first as Map)['content'], 'you are helpful');
      final tools = body['tools'] as List<dynamic>;
      expect((tools[1] as Map).containsKey('cache_control'), isFalse);
    });

    test(
      'marks the last text part of a block-list conversation message',
      () async {
        final capture = _Capture();
        final context = Context(
          messages: [
            UserMessage(
              content: [
                TextContent(text: 'look'),
                ImageContent(data: 'aGk=', mimeType: 'image/png'),
              ],
              timestamp: DateTime.utc(2026),
            ),
          ],
        );
        final stream = streamOpenAICompletions(
          _openRouterAnthropicModel,
          context,
          const OpenAICompletionsOptions(),
          capture.client,
        );
        await stream.toList();
        const marker = {'type': 'ephemeral'};
        final last = (capture.body!['messages'] as List).last as Map;
        expect(last['content'], [
          {'type': 'text', 'text': 'look', 'cache_control': marker},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,aGk='},
          },
        ]);
      },
    );

    test(
      'skips messages without text content and marks the previous one',
      () async {
        final capture = _Capture();
        final context = Context(
          messages: [
            UserMessage.text('question', timestamp: DateTime.utc(2026)),
            // No text content and no tool calls: the marker scan skips the
            // empty string and the missing-content message, landing on the
            // earlier user message.
            UserMessage.text('', timestamp: DateTime.utc(2026)),
            AssistantMessage(
              content: const [],
              api: 'openai-completions',
              provider: 'openrouter',
              model: 'anthropic/claude-sonnet-4',
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.utc(2026),
            ),
          ],
        );
        final stream = streamOpenAICompletions(
          _openRouterAnthropicModel,
          context,
          const OpenAICompletionsOptions(),
          capture.client,
        );
        await stream.toList();
        const marker = {'type': 'ephemeral'};
        final messages = capture.body!['messages'] as List;
        // The empty assistant message is dropped by conversion; the empty
        // user string survives but cannot take a marker.
        expect(messages, hasLength(2));
        expect((messages[0] as Map)['content'], [
          {'type': 'text', 'text': 'question', 'cache_control': marker},
        ]);
        expect((messages[1] as Map)['content'], '');
      },
    );

    test('skips block lists without a text part', () async {
      final capture = _Capture();
      final context = Context(
        messages: [
          UserMessage.text('caption this', timestamp: DateTime.utc(2026)),
          UserMessage(
            content: [ImageContent(data: 'aGk=', mimeType: 'image/png')],
            timestamp: DateTime.utc(2026),
          ),
        ],
      );
      final stream = streamOpenAICompletions(
        _openRouterAnthropicModel,
        context,
        const OpenAICompletionsOptions(),
        capture.client,
      );
      await stream.toList();
      const marker = {'type': 'ephemeral'};
      final messages = capture.body!['messages'] as List;
      expect((messages[1] as Map)['content'], [
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,aGk='},
        },
      ]);
      expect((messages[0] as Map)['content'], [
        {'type': 'text', 'text': 'caption this', 'cache_control': marker},
      ]);
    });
  });

  group('cache usage parsing', () {
    test('prompt_cache_hit_tokens maps to cacheRead (DeepSeek style)', () async {
      final client = http_testing.MockClient.streaming((
        request,
        requestBody,
      ) async {
        const chunk =
            'data: {"id":"c1","choices":[{"delta":{},"finish_reason":"stop"}],'
            '"usage":{"prompt_tokens":100,"completion_tokens":5,'
            '"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}\n\n'
            'data: [DONE]\n\n';
        return http.StreamedResponse(
          Stream.value(utf8.encode(chunk)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final stream = streamOpenAICompletions(
        _openAiModel,
        _context(),
        const OpenAICompletionsOptions(),
        client,
      );
      final message = await stream.result;
      expect(message.usage.cacheRead, 40);
      expect(message.usage.input, 60);
    });
  });
}
