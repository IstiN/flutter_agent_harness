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

String sseChunk(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

/// Concatenates SSE body parts: [Map]s are encoded as chunks, [String]s are
/// used verbatim (e.g. the terminating `data: [DONE]`).
String sseBody(List<Object> parts) {
  return parts
      .map(
        (part) =>
            part is String ? part : sseChunk(part as Map<String, dynamic>),
      )
      .join();
}

http.Client sseClient(String body) {
  return http_testing.MockClient.streaming(
    (request, requestBody) async => http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'text/event-stream'},
    ),
  );
}

final testModel = Model(
  id: 'gpt-4o-mini',
  name: 'GPT-4o mini',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  input: const ['text', 'image'],
  contextWindow: 128000,
  maxTokens: 16384,
  cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
);

final openRouterModel = Model(
  id: 'anthropic/claude-sonnet-4',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  reasoning: true,
  contextWindow: 200000,
  maxTokens: 64000,
);

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

void main() {
  group('streamOpenAICompletions', () {
    test('streams text with live partial accumulation', () async {
      final client = sseClient(
        sseBody([
          {
            'id': 'chatcmpl-9',
            'choices': [
              {
                'delta': {'content': 'Hel'},
              },
            ],
          },
          {
            'id': 'chatcmpl-9',
            'choices': [
              {
                'delta': {'content': 'lo'},
              },
            ],
          },
          {
            'id': 'chatcmpl-9',
            'usage': {'prompt_tokens': 10, 'completion_tokens': 2},
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.first, isA<StartEvent>());

      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas, hasLength(2));
      expect(deltas[0].delta, 'Hel');
      expect((deltas[0].partial.content.single as TextContent).text, 'Hel');
      expect(deltas[1].delta, 'lo');
      expect((deltas[1].partial.content.single as TextContent).text, 'Hello');
      expect(events.whereType<TextStartEvent>(), hasLength(1));
      expect(events.whereType<TextEndEvent>().single.content, 'Hello');

      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.stop);
      expect(done.message.responseId, 'chatcmpl-9');
      expect(done.message.usage.input, 10);
      expect(done.message.usage.output, 2);
      expect(done.message.usage.cost.total, greaterThan(0));

      expect(await stream.result, same(done.message));
    });

    test('streams tool calls with partial JSON arguments', () async {
      final client = sseClient(
        sseBody([
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'function': {'name': 'get_weather', 'arguments': '{"loc'},
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': 'ation":"Paris"}'},
                    },
                  ],
                  'reasoning_details': [
                    {
                      'type': 'reasoning.encrypted',
                      'id': 'call_1',
                      'data': 'sig-data',
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'},
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ToolCallStartEvent>(), hasLength(1));

      final deltas = events.whereType<ToolCallDeltaEvent>().toList();
      expect(deltas, hasLength(2));
      expect(deltas[0].delta, '{"loc');
      final firstPartial = deltas[0].partial.content.single as ToolCall;
      expect(firstPartial.partialArguments, '{"loc');
      expect(firstPartial.arguments, isEmpty);

      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.id, 'call_1');
      expect(end.toolCall.name, 'get_weather');
      expect(end.toolCall.arguments, {'location': 'Paris'});
      expect(end.toolCall.partialArguments, isNull);
      expect(
        end.toolCall.thoughtSignature,
        jsonEncode({
          'type': 'reasoning.encrypted',
          'id': 'call_1',
          'data': 'sig-data',
        }),
      );

      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.toolUse);
      expect(done.message.content.single, isA<ToolCall>());
    });

    test('streams reasoning deltas as thinking blocks', () async {
      final client = sseClient(
        sseBody([
          {
            'choices': [
              {
                'delta': {'reasoning_content': 'let me '},
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'reasoning_content': 'think'},
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'content': 'answer'},
              },
            ],
          },
          {
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final stream = streamOpenAICompletions(
        openRouterModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ThinkingStartEvent>(), hasLength(1));
      final thinkingDeltas = events.whereType<ThinkingDeltaEvent>().toList();
      expect(thinkingDeltas, hasLength(2));
      final thinkingPartial =
          thinkingDeltas[1].partial.content.first as ThinkingContent;
      expect(thinkingPartial.thinking, 'let me think');
      expect(thinkingPartial.thinkingSignature, 'reasoning_content');
      expect(
        events.whereType<ThinkingEndEvent>().single.content,
        'let me think',
      );
      expect(events.last, isA<DoneEvent>());
    });

    test('streams reasoning_details text entries as thinking blocks', () async {
      // OpenRouter routes some models' reasoning (e.g. NVIDIA nemotron) as
      // reasoning_details text entries instead of a `reasoning` delta field.
      final client = sseClient(
        sseBody([
          {
            'choices': [
              {
                'delta': {
                  'reasoning_details': [
                    {'type': 'reasoning.text', 'text': 'let me ', 'index': 0},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'reasoning_details': [
                    {'type': 'reasoning.text', 'text': 'think', 'index': 0},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'content': 'answer'},
              },
            ],
          },
          {
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final stream = streamOpenAICompletions(
        openRouterModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ThinkingStartEvent>(), hasLength(1));
      final thinkingDeltas = events.whereType<ThinkingDeltaEvent>().toList();
      expect(thinkingDeltas, hasLength(2));
      final thinkingPartial =
          thinkingDeltas[1].partial.content.first as ThinkingContent;
      expect(thinkingPartial.thinking, 'let me think');
      expect(events.last, isA<DoneEvent>());
    });

    test('parses usage incl. cached tokens and OpenRouter cost', () async {
      final client = sseClient(
        sseBody([
          {
            'choices': [
              {
                'delta': {'content': 'hi'},
              },
            ],
          },
          {
            'usage': {
              'prompt_tokens': 100,
              'completion_tokens': 20,
              'prompt_tokens_details': {
                'cached_tokens': 40,
                'cache_write_tokens': 10,
              },
              'completion_tokens_details': {'reasoning_tokens': 5},
              'cost': 0.00123,
            },
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final stream = streamOpenAICompletions(
        openRouterModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final message = await stream.result;
      expect(message.usage.input, 50);
      expect(message.usage.output, 20);
      expect(message.usage.cacheRead, 40);
      expect(message.usage.cacheWrite, 10);
      expect(message.usage.reasoning, 5);
      expect(message.usage.totalTokens, 120);
      // OpenRouter's billed cost wins over the rate-based estimate.
      expect(message.usage.cost.total, closeTo(0.00123, 1e-9));
    });

    test('429 becomes an error event, never an exception', () async {
      final client = http_testing.MockClient(
        (request) async =>
            http.Response('{"error":{"message":"Rate limit exceeded"}}', 429),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.single as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.stopReason, StopReason.error);
      expect(error.error.errorMessage, contains('429'));
      expect(error.error.errorMessage, contains('Rate limit exceeded'));
      expect(error.retryAfter, isNull);
      expect(await stream.result, same(error.error));
    });

    test('429 with Retry-After header surfaces the parsed duration', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(
          '{"error":{"message":"Rate limit exceeded"}}',
          429,
          headers: {'retry-after': '30'},
        ),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final error = (await stream.toList()).single as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.retryAfter, const Duration(seconds: 30));
    });

    test('429 with HTTP-date Retry-After header surfaces the delta', () async {
      final retryDate = DateTime.now().toUtc().add(const Duration(seconds: 45));
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      String two(int value) => value.toString().padLeft(2, '0');
      // IMF-fixdate (RFC 9110): "Wed, 21 Oct 2015 07:28:00 GMT".
      final httpDate =
          '${weekdays[retryDate.weekday - 1]}, ${two(retryDate.day)} '
          '${months[retryDate.month - 1]} ${retryDate.year} '
          '${two(retryDate.hour)}:${two(retryDate.minute)}:'
          '${two(retryDate.second)} GMT';
      final client = http_testing.MockClient(
        (request) async => http.Response(
          '{"error":{"message":"Rate limit exceeded"}}',
          429,
          headers: {'retry-after': httpDate},
        ),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final error = (await stream.toList()).single as ErrorEvent;
      expect(error.retryAfter, isNotNull);
      expect(error.retryAfter!.inSeconds, greaterThan(0));
      expect(error.retryAfter!.inSeconds, lessThanOrEqualTo(45));
    });

    test(
      'malformed SSE data becomes an error event, not an exception',
      () async {
        final client = sseClient('data: {not valid json\n\n');

        final stream = streamOpenAICompletions(
          testModel,
          simpleContext(),
          const OpenAICompletionsOptions(apiKey: 'test-key'),
          client,
        );

        final events = await stream.toList();
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, isNotNull);
      },
    );

    test('network failure becomes an error event', () async {
      final client = http_testing.MockClient(
        (request) async => throw http.ClientException('connection reset'),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('connection reset'));
    });

    test('content_filter finish reason becomes an error event', () async {
      final client = sseClient(
        sseBody([
          {
            'choices': [
              {
                'delta': {'content': 'partial'},
              },
            ],
          },
          {
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'content_filter'},
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('content_filter'));
      // The partial content is still attached to the error message.
      expect((error.error.content.single as TextContent).text, 'partial');
    });

    test(
      'stream ending without finish_reason completes with a natural stop',
      () async {
        // Some providers (seen on OpenRouter free-tier models) close the SSE
        // stream without a final finish_reason chunk; the accumulated content
        // is treated as complete instead of failing the turn.
        final client = sseClient(
          sseChunk({
            'choices': [
              {
                'delta': {'content': 'cut off'},
              },
            ],
          }),
        );

        final stream = streamOpenAICompletions(
          testModel,
          simpleContext(),
          const OpenAICompletionsOptions(apiKey: 'test-key'),
          client,
        );

        final events = await stream.toList();
        final done = events.last as DoneEvent;
        expect(done.reason, StopReason.stop);
        expect((done.message.content.single as TextContent).text, 'cut off');
      },
    );

    test(
      'CancelToken abort mid-stream ends with aborted stop reason',
      () async {
        final controller = StreamController<List<int>>();
        var connectionClosed = false;
        controller.onCancel = () => connectionClosed = true;
        final client = http_testing.MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            controller.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );

        final source = CancelTokenSource();
        final stream = streamOpenAICompletions(
          testModel,
          simpleContext(),
          OpenAICompletionsOptions(
            apiKey: 'test-key',
            cancelToken: source.token,
          ),
          client,
        );

        final events = <AssistantMessageEvent>[];
        final consumed = stream.forEach(events.add);

        controller.add(
          utf8.encode(
            sseChunk({
              'choices': [
                {
                  'delta': {'content': 'partial'},
                },
              ],
            }),
          ),
        );
        await pumpEventQueue();
        source.cancel();
        await consumed;
        unawaited(controller.close());
        // Let the subscription-cancellation propagation settle.
        await pumpEventQueue();

        expect(connectionClosed, isTrue);
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.aborted);
        expect(error.error.stopReason, StopReason.aborted);
        expect(error.error.errorMessage, contains('aborted'));
        expect((error.error.content.single as TextContent).text, 'partial');
        expect(await stream.result, same(error.error));
      },
    );

    test('mid-stream network error becomes an error event', () async {
      final controller = StreamController<List<int>>();
      final client = http_testing.MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );

      final source = CancelTokenSource();
      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        OpenAICompletionsOptions(apiKey: 'test-key', cancelToken: source.token),
        client,
      );

      final events = <AssistantMessageEvent>[];
      final consumed = stream.forEach(events.add);
      controller.add(
        utf8.encode(
          sseChunk({
            'choices': [
              {
                'delta': {'content': 'partial'},
              },
            ],
          }),
        ),
      );
      await pumpEventQueue();
      controller.addError(http.ClientException('connection reset'));
      await consumed;
      unawaited(controller.close());

      // The token is not cancelled, so the error propagates to the adapter's
      // try/catch and surfaces as a regular error event.
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('connection reset'));
      expect((error.error.content.single as TextContent).text, 'partial');
    });

    test('post-abort connection teardown error is swallowed', () async {
      final controller = StreamController<List<int>>();
      final client = http_testing.MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );

      final source = CancelTokenSource();
      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        OpenAICompletionsOptions(apiKey: 'test-key', cancelToken: source.token),
        client,
      );

      final events = <AssistantMessageEvent>[];
      final consumed = stream.forEach(events.add);
      controller.add(
        utf8.encode(
          sseChunk({
            'choices': [
              {
                'delta': {'content': 'partial'},
              },
            ],
          }),
        ),
      );
      await pumpEventQueue();
      source.cancel();
      await consumed;

      // Cancellation through the async* SseDecoder is lazy, so the response
      // subscription is still active here. Mirrors what force-closing the
      // owned HTTP client injects into the dying connection on a real abort
      // (seen live against OpenRouter): it must not escape as an unhandled
      // async error.
      controller.addError(
        http.ClientException('Connection closed while receiving data'),
      );
      await pumpEventQueue();
      unawaited(controller.close());

      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.aborted);
    });

    test(
      'CancelToken abort before sending ends with aborted stop reason',
      () async {
        var requestSent = false;
        final client = http_testing.MockClient.streaming((request, body) async {
          requestSent = true;
          return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
        });

        final source = CancelTokenSource()..cancel();
        final stream = streamOpenAICompletions(
          testModel,
          simpleContext(),
          OpenAICompletionsOptions(
            apiKey: 'test-key',
            cancelToken: source.token,
          ),
          client,
        );

        final events = await stream.toList();
        expect(requestSent, isFalse);
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.aborted);
      },
    );

    test('baseUrl swap routes the request to the given base URL', () async {
      Uri? capturedUrl;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedUrl = request.url;
        return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
      });

      final stream = streamOpenAICompletions(
        openRouterModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      expect(
        capturedUrl.toString(),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('headers and auth are merged with null suppression', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
      });

      final model = Model(
        id: 'gpt-4o-mini',
        api: 'openai-completions',
        provider: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        contextWindow: 128000,
        maxTokens: 16384,
        headers: const {'x-model': 'model-default', 'x-keep': 'keep'},
      );

      final stream = streamOpenAICompletions(
        model,
        simpleContext(),
        const OpenAICompletionsOptions(
          apiKey: 'test-key',
          headers: {'x-custom': 'custom', 'x-model': null},
        ),
        client,
      );
      await stream.result;

      expect(capturedHeaders!['authorization'], 'Bearer test-key');
      expect(capturedHeaders!['content-type'], 'application/json');
      expect(capturedHeaders!['x-keep'], 'keep');
      expect(capturedHeaders!['x-custom'], 'custom');
      expect(capturedHeaders!.containsKey('x-model'), isFalse);
    });

    test('missing API key sends no Authorization header', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
      });

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(),
        client,
      );
      await stream.result;

      // Keyless local servers (llama.cpp, Ollama, LM Studio) must not get a
      // bogus `Bearer ` header — some reject it.
      expect(capturedHeaders!.containsKey('authorization'), isFalse);
      expect(capturedHeaders!['content-type'], 'application/json');
    });

    test('empty API key sends no Authorization header', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
      });

      final stream = streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: ''),
        client,
      );
      await stream.result;

      expect(capturedHeaders!.containsKey('authorization'), isFalse);
    });

    test(
      'an explicit authorization header applies without an API key',
      () async {
        Map<String, String>? capturedHeaders;
        final client = http_testing.MockClient.streaming((request, body) async {
          capturedHeaders = request.headers;
          return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
        });

        final stream = streamOpenAICompletions(
          testModel,
          simpleContext(),
          const OpenAICompletionsOptions(
            headers: {'authorization': 'Bearer explicit'},
          ),
          client,
        );
        await stream.result;

        expect(capturedHeaders!['authorization'], 'Bearer explicit');
      },
    );

    test(
      'builds the request payload from context, tools, and options',
      () async {
        Map<String, dynamic>? capturedBody;
        var onPayloadSeen = false;
        var onResponseSeen = false;
        final client = http_testing.MockClient.streaming((request, body) async {
          capturedBody =
              jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
          return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
        });

        final timestamp = DateTime.utc(2026);
        final context = Context(
          systemPrompt: 'You are helpful.',
          messages: [
            UserMessage.text('What is the weather?', timestamp: timestamp),
            AssistantMessage(
              content: const [
                TextContent(text: 'Let me check.'),
                ToolCall(
                  id: 'call_1',
                  name: 'get_weather',
                  arguments: {'location': 'Paris'},
                ),
              ],
              api: 'openai-completions',
              provider: 'openai',
              model: 'gpt-4o-mini',
              usage: Usage.zero,
              stopReason: StopReason.toolUse,
              timestamp: timestamp,
            ),
            ToolResultMessage(
              toolCallId: 'call_1',
              toolName: 'get_weather',
              content: const [TextContent(text: 'Sunny, 21C')],
              isError: false,
              timestamp: timestamp,
            ),
            UserMessage(
              content: const [
                TextContent(text: 'And here is a picture:'),
                ImageContent(data: 'aGk=', mimeType: 'image/png'),
              ],
              timestamp: timestamp,
            ),
          ],
          tools: const [
            Tool(
              name: 'get_weather',
              description: 'Get the weather',
              parameters: {
                'type': 'object',
                'properties': {
                  'location': {'type': 'string'},
                },
              },
            ),
          ],
        );

        final stream = streamOpenAICompletions(
          testModel,
          context,
          OpenAICompletionsOptions(
            apiKey: 'test-key',
            temperature: 0.2,
            maxTokens: 512,
            toolChoice: 'auto',
            onPayload: (payload, model) {
              onPayloadSeen = true;
              return null;
            },
            onResponse: (statusCode, headers, model) {
              onResponseSeen = true;
              expect(statusCode, 200);
            },
          ),
          client,
        );
        await stream.result;

        expect(onPayloadSeen, isTrue);
        expect(onResponseSeen, isTrue);
        final body = capturedBody!;
        expect(body['model'], 'gpt-4o-mini');
        expect(body['stream'], isTrue);
        expect(body['stream_options'], {'include_usage': true});
        expect(body['max_completion_tokens'], 512);
        expect(body['temperature'], 0.2);
        expect(body['tool_choice'], 'auto');

        final messages = body['messages'] as List;
        expect(messages[0], {'role': 'system', 'content': 'You are helpful.'});
        expect(messages[1], {
          'role': 'user',
          'content': 'What is the weather?',
        });
        expect(messages[2], {
          'role': 'assistant',
          'content': 'Let me check.',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'get_weather',
                'arguments': '{"location":"Paris"}',
              },
            },
          ],
        });
        expect(messages[3], {
          'role': 'tool',
          'content': 'Sunny, 21C',
          'tool_call_id': 'call_1',
        });
        expect(messages[4], {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'And here is a picture:'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,aGk='},
            },
          ],
        });

        expect(body['tools'], [
          {
            'type': 'function',
            'function': {
              'name': 'get_weather',
              'description': 'Get the weather',
              'parameters': {
                'type': 'object',
                'properties': {
                  'location': {'type': 'string'},
                },
              },
            },
            'strict': false,
          },
        ]);
      },
    );

    test(
      'non-vision model gets explicit placeholders instead of images',
      () async {
        Map<String, dynamic>? capturedBody;
        final client = http_testing.MockClient.streaming((request, body) async {
          capturedBody =
              jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
          return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
        });

        final textOnlyModel = Model(
          id: 'gpt-text-only',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://api.openai.com/v1',
          contextWindow: 128000,
          maxTokens: 16384,
        );
        final context = Context(
          messages: [
            ToolResultMessage(
              toolCallId: 'call_1',
              toolName: 'screenshot',
              content: const [
                TextContent(text: 'done'),
                ImageContent(data: 'aGk=', mimeType: 'image/png'),
              ],
              isError: false,
              timestamp: DateTime.utc(2026),
            ),
            UserMessage(
              content: const [
                TextContent(text: 'look:'),
                ImageContent(data: 'aGk=', mimeType: 'image/png'),
                ImageContent(data: 'aGk=', mimeType: 'image/png'),
              ],
              timestamp: DateTime.utc(2026),
            ),
          ],
        );

        final stream = streamOpenAICompletions(
          textOnlyModel,
          context,
          const OpenAICompletionsOptions(apiKey: 'test-key'),
          client,
        );
        await stream.result;

        final messages = capturedBody!['messages'] as List;
        // Tool result: image replaced with the explicit tool placeholder;
        // no trailing "Attached image(s)" user turn is emitted.
        expect(messages[0], {
          'role': 'tool',
          'content':
              'done\n(tool image omitted: model does not support images)',
          'tool_call_id': 'call_1',
        });
        // User message: consecutive images collapse into ONE placeholder.
        expect(messages[1], {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look:'},
            {
              'type': 'text',
              'text': '(image omitted: model does not support images)',
            },
          ],
        });
        expect(messages, hasLength(2));
      },
    );

    test(
      'sends OpenRouter-style reasoning object for reasoning models',
      () async {
        Map<String, dynamic>? capturedBody;
        final client = http_testing.MockClient.streaming((request, body) async {
          capturedBody =
              jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
          return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
        });

        final stream = streamOpenAICompletions(
          openRouterModel,
          simpleContext(),
          const OpenAICompletionsOptions(
            apiKey: 'test-key',
            reasoningEffort: 'high',
          ),
          client,
        );
        await stream.result;

        expect(capturedBody!['reasoning'], {'effort': 'high'});
        expect(capturedBody!.containsKey('reasoning_effort'), isFalse);
      },
    );
  });

  group('serialization round-trip', () {
    test('context types survive JSON round-trip', () {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(1767225600000);
      final context = Context(
        systemPrompt: 'sys',
        messages: [
          UserMessage.text('plain text', timestamp: timestamp),
          UserMessage(
            content: const [
              TextContent(text: 'with image'),
              ImageContent(data: 'aGk=', mimeType: 'image/png'),
            ],
            timestamp: timestamp,
          ),
          AssistantMessage(
            content: const [
              TextContent(text: 'answer', textSignature: 'sig'),
              ThinkingContent(
                thinking: 'hmm',
                thinkingSignature: 'rs_1',
                redacted: true,
              ),
              ToolCall(
                id: 'call_1',
                name: 'tool',
                arguments: {'a': 1},
                thoughtSignature: 'ts',
              ),
            ],
            api: 'openai-completions',
            provider: 'openai',
            model: 'gpt-4o-mini',
            responseModel: 'gpt-4o-mini-2024',
            responseId: 'chatcmpl-1',
            usage: const Usage(
              input: 1,
              output: 2,
              cacheRead: 3,
              cacheWrite: 4,
              cacheWrite1h: 1,
              reasoning: 1,
              totalTokens: 10,
              cost: UsageCost(
                input: 0.1,
                output: 0.2,
                cacheRead: 0.3,
                cacheWrite: 0.4,
                total: 1.0,
              ),
            ),
            stopReason: StopReason.toolUse,
            errorMessage: 'oops',
            timestamp: timestamp,
          ),
          ToolResultMessage(
            toolCallId: 'call_1',
            toolName: 'tool',
            content: const [
              TextContent(text: 'result'),
              ImageContent(data: 'aGk=', mimeType: 'image/png'),
            ],
            isError: true,
            timestamp: timestamp,
          ),
        ],
        tools: const [
          Tool(
            name: 'tool',
            description: 'desc',
            parameters: {'type': 'object'},
          ),
        ],
      );

      final roundTripped = Context.fromJson(
        jsonDecode(jsonEncode(context.toJson())) as Map<String, dynamic>,
      );
      expect(jsonEncode(roundTripped.toJson()), jsonEncode(context.toJson()));
    });
  });
}
