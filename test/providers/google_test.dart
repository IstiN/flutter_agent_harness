import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Encodes one Google SSE chunk (data-only event, no `event:` name).
String googleChunk(Map<String, dynamic> json) {
  return 'data: ${jsonEncode(json)}\n\n';
}

/// Concatenates SSE body parts: [Map]s are encoded as data chunks, [String]s
/// are used verbatim (e.g. a malformed payload).
String sseBody(List<Object> parts) {
  return parts
      .map(
        (part) => part is String
            ? part
            : googleChunk(part as Map<String, dynamic>),
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

Map<String, dynamic> textChunk(
  String text, {
  String? finishReason,
  Map<String, dynamic>? usage,
}) => {
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': text},
        ],
        'role': 'model',
      },
      'finishReason': ?finishReason,
    },
  ],
  'usageMetadata': ?usage,
};

final testModel = Model(
  id: 'gemini-2.5-flash',
  name: 'Gemini 2.5 Flash',
  api: 'google-generative-ai',
  provider: 'google',
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  reasoning: true,
  input: const ['text', 'image'],
  contextWindow: 1000000,
  maxTokens: 65536,
  cost: const ModelCost(input: 0.3, output: 2.5, cacheRead: 0.03),
);

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

void main() {
  group('streamGoogle', () {
    test('streams text with live partial accumulation', () async {
      final client = sseClient(
        sseBody([
          textChunk('Hel', usage: {'promptTokenCount': 10, 'totalTokenCount': 10}),
          textChunk('lo'),
          textChunk(
            '',
            finishReason: 'STOP',
            usage: {
              'promptTokenCount': 10,
              'candidatesTokenCount': 2,
              'totalTokenCount': 12,
            },
          ),
        ]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.first, isA<StartEvent>());

      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas, hasLength(3));
      expect(deltas[0].delta, 'Hel');
      expect((deltas[0].partial.content.single as TextContent).text, 'Hel');
      expect(deltas[1].delta, 'lo');
      expect((deltas[1].partial.content.single as TextContent).text, 'Hello');
      expect(events.whereType<TextStartEvent>(), hasLength(1));
      expect(events.whereType<TextEndEvent>().single.content, 'Hello');

      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.stop);
      expect(done.message.usage.input, 10);
      expect(done.message.usage.output, 2);
      expect(done.message.usage.totalTokens, 12);
      expect(done.message.usage.cost.total, greaterThan(0));

      expect(await stream.result, same(done.message));
    });

    test('captures the first non-empty responseId', () async {
      final client = sseClient(
        sseBody([
          {'responseId': 'resp-1', ...textChunk('hi')},
          {'responseId': 'resp-2', ...textChunk('', finishReason: 'STOP')},
        ]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final message = await stream.result;
      expect(message.responseId, 'resp-1');
    });

    test('streams thought parts as thinking with signature retention', () async {
      final client = sseClient(
        sseBody([
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': 'let me ',
                      'thought': true,
                      'thoughtSignature': 'c2lnMQ==',
                    },
                  ],
                  'role': 'model',
                },
              },
            ],
          },
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'think', 'thought': true},
                  ],
                  'role': 'model',
                },
              },
            ],
          },
          textChunk('answer'),
          textChunk(
            '',
            finishReason: 'STOP',
            usage: {
              'promptTokenCount': 10,
              'candidatesTokenCount': 20,
              'thoughtsTokenCount': 12,
              'totalTokenCount': 42,
            },
          ),
        ]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ThinkingStartEvent>(), hasLength(1));
      final thinkingDeltas = events.whereType<ThinkingDeltaEvent>().toList();
      expect(thinkingDeltas, hasLength(2));
      final thinkingPartial =
          thinkingDeltas[1].partial.content.first as ThinkingContent;
      expect(thinkingPartial.thinking, 'let me think');
      expect(
        events.whereType<ThinkingEndEvent>().single.content,
        'let me think',
      );

      final done = events.last as DoneEvent;
      final thinking = done.message.content.first as ThinkingContent;
      expect(thinking.thinking, 'let me think');
      // Signature sent on the first delta is retained across the block.
      expect(thinking.thinkingSignature, 'c2lnMQ==');
      expect(done.message.content[1], isA<TextContent>());
      expect(done.message.usage.reasoning, 12);
      expect(done.message.usage.output, 32);
    });

    test('streams functionCall parts as tool calls', () async {
      final client = sseClient(
        sseBody([
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'id': 'call_1',
                        'name': 'get_weather',
                        'args': {'location': 'Paris'},
                      },
                      'thoughtSignature': 'dG9vbHNpZw==',
                    },
                  ],
                  'role': 'model',
                },
                'finishReason': 'STOP',
              },
            ],
          },
        ]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ToolCallStartEvent>(), hasLength(1));

      final delta = events.whereType<ToolCallDeltaEvent>().single;
      expect(delta.delta, '{"location":"Paris"}');
      final partial = delta.partial.content.single as ToolCall;
      expect(partial.id, 'call_1');
      expect(partial.name, 'get_weather');
      expect(partial.partialArguments, '{"location":"Paris"}');
      expect(partial.arguments, isEmpty);

      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.id, 'call_1');
      expect(end.toolCall.name, 'get_weather');
      expect(end.toolCall.arguments, {'location': 'Paris'});
      expect(end.toolCall.thoughtSignature, 'dG9vbHNpZw==');
      expect(end.toolCall.partialArguments, isNull);

      final done = events.last as DoneEvent;
      // A tool call overrides the mapped finish reason, per pi.
      expect(done.reason, StopReason.toolUse);
      expect(done.message.content.single, isA<ToolCall>());
    });

    test('generates a tool call id when none is provided', () async {
      final client = sseClient(
        sseBody([
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {'name': 'ping', 'args': <String, dynamic>{}},
                    },
                  ],
                  'role': 'model',
                },
                'finishReason': 'STOP',
              },
            ],
          },
        ]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final end = (await stream.toList()).whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.id, startsWith('ping_'));
      expect(end.toolCall.arguments, isEmpty);
    });

    test('maps usageMetadata incl. cached and thoughts tokens', () async {
      final client = sseClient(
        sseBody([
          textChunk(
            'hi',
            finishReason: 'STOP',
            usage: {
              'promptTokenCount': 100,
              'candidatesTokenCount': 50,
              'cachedContentTokenCount': 40,
              'thoughtsTokenCount': 10,
              'totalTokenCount': 200,
            },
          ),
        ]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final message = await stream.result;
      // input = prompt - cached; output = candidates + thoughts, per pi.
      expect(message.usage.input, 60);
      expect(message.usage.output, 60);
      expect(message.usage.cacheRead, 40);
      expect(message.usage.cacheWrite, 0);
      expect(message.usage.reasoning, 10);
      expect(message.usage.totalTokens, 200);
      // 60*0.3 + 60*2.5 + 40*0.03 per million tokens.
      expect(
        message.usage.cost.total,
        closeTo((18 + 150 + 1.2) / 1e6, 1e-12),
      );
    });

    test('MAX_TOKENS finish reason maps to length', () async {
      final client = sseClient(
        sseBody([textChunk('cut', finishReason: 'MAX_TOKENS')]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final done = (await stream.toList()).last as DoneEvent;
      expect(done.reason, StopReason.length);
    });

    test('SAFETY finish reason becomes an error event', () async {
      final client = sseClient(
        sseBody([textChunk('nope', finishReason: 'SAFETY')]),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.stopReason, StopReason.error);
      expect((error.error.content.single as TextContent).text, 'nope');
    });

    test('429 becomes an error event, never an exception', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(
          '{"error":{"message":"Resource has been exhausted"}}',
          429,
        ),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.single as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.stopReason, StopReason.error);
      expect(error.error.errorMessage, contains('429'));
      expect(error.error.errorMessage, contains('Resource has been exhausted'));
      expect(error.retryAfter, isNull);
      expect(await stream.result, same(error.error));
    });

    test('429 with Retry-After header surfaces the parsed duration', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(
          '{"error":{"message":"Resource has been exhausted"}}',
          429,
          headers: {'retry-after': '60'},
        ),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final error = (await stream.toList()).single as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.retryAfter, const Duration(seconds: 60));
    });

    test('in-stream provider error chunk becomes an error event', () async {
      final client = sseClient(
        'data: {"error":{"code":500,"message":"internal error"}}\n\n',
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('internal error'));
    });

    test('malformed SSE data becomes an error event, not an exception', () async {
      final client = sseClient('data: {not valid json\n\n');

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('Could not parse'));
    });

    test('network failure becomes an error event', () async {
      final client = http_testing.MockClient(
        (request) async => throw http.ClientException('connection reset'),
      );

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('connection reset'));
    });

    test('CancelToken abort mid-stream ends with aborted stop reason', () async {
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
      final stream = streamGoogle(
        testModel,
        simpleContext(),
        GoogleOptions(apiKey: 'test-key', cancelToken: source.token),
        client,
      );

      final events = <AssistantMessageEvent>[];
      final consumed = stream.forEach(events.add);

      controller.add(utf8.encode(sseBody([textChunk('partial')])));
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
    });

    test('CancelToken abort before sending ends with aborted stop reason', () async {
      var requestSent = false;
      final client = http_testing.MockClient.streaming((request, body) async {
        requestSent = true;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final source = CancelTokenSource()..cancel();
      final stream = streamGoogle(
        testModel,
        simpleContext(),
        GoogleOptions(apiKey: 'test-key', cancelToken: source.token),
        client,
      );

      final events = await stream.toList();
      expect(requestSent, isFalse);
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.aborted);
    });

    test('posts to {baseUrl}/models/{id}:streamGenerateContent?alt=sse', () async {
      Uri? capturedUrl;
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedUrl = request.url;
        capturedHeaders = request.headers;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final model = Model(
        id: 'gemini-2.5-flash',
        api: 'google-generative-ai',
        provider: 'google',
        baseUrl: 'https://proxy.example.com/v1beta',
        contextWindow: 1000000,
        maxTokens: 8192,
        headers: const {'x-model': 'model-default', 'x-keep': 'keep'},
      );

      final stream = streamGoogle(
        model,
        simpleContext(),
        const GoogleOptions(
          apiKey: 'test-key',
          headers: {'x-custom': 'custom', 'x-model': null},
        ),
        client,
      );
      await stream.result;

      expect(
        capturedUrl.toString(),
        'https://proxy.example.com/v1beta/models/gemini-2.5-flash'
        ':streamGenerateContent?alt=sse',
      );
      expect(capturedHeaders!['x-goog-api-key'], 'test-key');
      expect(capturedHeaders!['content-type'], 'application/json');
      expect(capturedHeaders!['x-keep'], 'keep');
      expect(capturedHeaders!['x-custom'], 'custom');
      expect(capturedHeaders!.containsKey('x-model'), isFalse);
    });

    test('missing API key becomes an error event', () async {
      final client = sseClient(sseBody([textChunk('hi')]));
      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('No API key'));
    });

    test('an x-goog-api-key option header satisfies auth without apiKey', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final stream = streamGoogle(
        testModel,
        simpleContext(),
        const GoogleOptions(headers: {'x-goog-api-key': 'header-key'}),
        client,
      );
      await stream.result;

      expect(capturedHeaders!['x-goog-api-key'], 'header-key');
    });

    test('builds the request payload from context, tools, and options', () async {
      Map<String, dynamic>? capturedBody;
      var onPayloadSeen = false;
      var onResponseSeen = false;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final timestamp = DateTime.utc(2026);
      final context = Context(
        systemPrompt: 'You are helpful.',
        messages: [
          UserMessage.text('What is the weather?', timestamp: timestamp),
          AssistantMessage(
            content: const [
              ThinkingContent(
                thinking: 'hmm',
                thinkingSignature: 'c2lnMQ==',
              ),
              TextContent(text: 'Let me check.'),
              ToolCall(
                id: 'call_1',
                name: 'get_weather',
                arguments: {'location': 'Paris'},
                thoughtSignature: 'dG9vbHNpZw==',
              ),
            ],
            api: 'google-generative-ai',
            provider: 'google',
            model: 'gemini-2.5-flash',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: timestamp,
          ),
          ToolResultMessage(
            toolCallId: 'call_1',
            toolName: 'get_weather',
            content: const [
              TextContent(text: 'Sunny, 21C'),
              ImageContent(data: 'aGk=', mimeType: 'image/png'),
            ],
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
              'required': ['location'],
            },
          ),
        ],
      );

      final stream = streamGoogle(
        testModel,
        context,
        GoogleOptions(
          apiKey: 'test-key',
          temperature: 0.2,
          maxTokens: 512,
          toolChoice: 'any',
          thinking: const GoogleThinking(enabled: true, budgetTokens: 2048),
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

      expect(body['generationConfig'], {
        'temperature': 0.2,
        'maxOutputTokens': 512,
        'thinkingConfig': {'includeThoughts': true, 'thinkingBudget': 2048},
      });
      expect(body['systemInstruction'], {
        'parts': [
          {'text': 'You are helpful.'},
        ],
      });
      expect(body['toolConfig'], {
        'functionCallingConfig': {'mode': 'ANY'},
      });

      final contents = body['contents'] as List;
      expect(contents[0], {
        'role': 'user',
        'parts': [
          {'text': 'What is the weather?'},
        ],
      });
      expect(contents[1], {
        'role': 'model',
        'parts': [
          {'thought': true, 'text': 'hmm', 'thoughtSignature': 'c2lnMQ=='},
          {'text': 'Let me check.'},
          {
            'functionCall': {
              'name': 'get_weather',
              'args': {'location': 'Paris'},
            },
            'thoughtSignature': 'dG9vbHNpZw==',
          },
        ],
      });
      // Gemini 2.5 (< 3): images go in a separate user turn.
      expect(contents[2], {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'get_weather',
              'response': {'output': 'Sunny, 21C'},
            },
          },
        ],
      });
      expect(contents[3], {
        'role': 'user',
        'parts': [
          {'text': 'Tool result image:'},
          {
            'inlineData': {'mimeType': 'image/png', 'data': 'aGk='},
          },
        ],
      });
      expect(contents[4], {
        'role': 'user',
        'parts': [
          {'text': 'And here is a picture:'},
          {
            'inlineData': {'mimeType': 'image/png', 'data': 'aGk='},
          },
        ],
      });

      expect(body['tools'], [
        {
          'functionDeclarations': [
            {
              'name': 'get_weather',
              'description': 'Get the weather',
              'parametersJsonSchema': {
                'type': 'object',
                'properties': {
                  'location': {'type': 'string'},
                },
                'required': ['location'],
              },
            },
          ],
        },
      ]);
    });

    test('consecutive tool results merge into one user turn', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final timestamp = DateTime.utc(2026);
      final context = Context(
        messages: [
          ToolResultMessage(
            toolCallId: 'call_1',
            toolName: 'a',
            content: const [TextContent(text: 'first')],
            isError: false,
            timestamp: timestamp,
          ),
          ToolResultMessage(
            toolCallId: 'call_2',
            toolName: 'b',
            content: const [TextContent(text: 'boom')],
            isError: true,
            timestamp: timestamp,
          ),
        ],
      );

      final stream = streamGoogle(
        testModel,
        context,
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      final contents = capturedBody!['contents'] as List;
      expect(contents, hasLength(1));
      expect(contents[0]['role'], 'user');
      final parts = contents[0]['parts'] as List;
      expect(parts, [
        {
          'functionResponse': {
            'name': 'a',
            'response': {'output': 'first'},
          },
        },
        {
          'functionResponse': {
            'name': 'b',
            'response': {'error': 'boom'},
          },
        },
      ]);
    });

    test('Gemini 3 keeps tool result images inside functionResponse.parts', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final model = Model(
        id: 'gemini-3-pro',
        api: 'google-generative-ai',
        provider: 'google',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        reasoning: true,
        input: const ['text', 'image'],
        contextWindow: 1000000,
        maxTokens: 65536,
      );
      final context = Context(
        messages: [
          ToolResultMessage(
            toolCallId: 'call_1',
            toolName: 'screenshot',
            content: const [ImageContent(data: 'aGk=', mimeType: 'image/png')],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
        ],
      );

      final stream = streamGoogle(
        model,
        context,
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      final contents = capturedBody!['contents'] as List;
      expect(contents, hasLength(1));
      expect(contents[0], {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'screenshot',
              'response': {'output': '(see attached image)'},
              'parts': [
                {
                  'inlineData': {'mimeType': 'image/png', 'data': 'aGk='},
                },
              ],
            },
          },
        ],
      });
    });

    test('thinking config variants and disable configs per model family', () async {
      Future<Map<String, dynamic>?> captureThinkingConfig(
        Model model,
        GoogleThinking thinking,
      ) async {
        Map<String, dynamic>? capturedBody;
        final client = http_testing.MockClient.streaming((request, body) async {
          capturedBody =
              jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
          return http.StreamedResponse(
            Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
            200,
          );
        });
        await streamGoogle(
          model,
          simpleContext(),
          GoogleOptions(apiKey: 'test-key', thinking: thinking),
          client,
        ).result;
        final config =
            capturedBody!['generationConfig'] as Map<String, dynamic>?;
        return config?['thinkingConfig'] as Map<String, dynamic>?;
      }

      Model modelWithId(String id) => Model(
        id: id,
        api: 'google-generative-ai',
        provider: 'google',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        reasoning: true,
        contextWindow: 1000000,
        maxTokens: 65536,
      );

      // thinkingLevel wins over budgetTokens when both are set, per pi.
      expect(
        await captureThinkingConfig(
          modelWithId('gemini-3-pro'),
          const GoogleThinking(
            enabled: true,
            level: 'LOW',
            budgetTokens: 2048,
          ),
        ),
        {'includeThoughts': true, 'thinkingLevel': 'LOW'},
      );
      // Gemini 3 Pro cannot disable thinking: lowest level, no includeThoughts.
      expect(
        await captureThinkingConfig(
          modelWithId('gemini-3-pro'),
          const GoogleThinking(enabled: false),
        ),
        {'thinkingLevel': 'LOW'},
      );
      expect(
        await captureThinkingConfig(
          modelWithId('gemini-3-flash'),
          const GoogleThinking(enabled: false),
        ),
        {'thinkingLevel': 'MINIMAL'},
      );
      expect(
        await captureThinkingConfig(
          modelWithId('gemma-4'),
          const GoogleThinking(enabled: false),
        ),
        {'thinkingLevel': 'MINIMAL'},
      );
      // Gemini 2.x disables via thinkingBudget = 0.
      expect(
        await captureThinkingConfig(
          modelWithId('gemini-2.5-flash'),
          const GoogleThinking(enabled: false),
        ),
        {'thinkingBudget': 0},
      );
      // Thinking options are ignored for non-reasoning models.
      expect(
        await captureThinkingConfig(
          Model(
            id: 'gemini-2.5-flash',
            api: 'google-generative-ai',
            provider: 'google',
            baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
            contextWindow: 1000000,
            maxTokens: 8192,
          ),
          const GoogleThinking(enabled: true),
        ),
        isNull,
      );
    });

    test('useParameters sends sanitized legacy parameters schema', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final context = Context(
        messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
        tools: const [
          Tool(
            name: 'search',
            description: 'Search the web',
            parameters: {
              r'$schema': 'http://json-schema.org/draft-07/schema#',
              r'$defs': {
                'query': {'type': 'string'},
              },
              'type': 'object',
              'properties': {
                'q': {
                  r'$comment': 'the query',
                  'type': 'string',
                },
              },
            },
          ),
        ],
      );

      final stream = streamGoogle(
        testModel,
        context,
        const GoogleOptions(apiKey: 'test-key', useParameters: true),
        client,
      );
      await stream.result;

      expect(capturedBody!['tools'], [
        {
          'functionDeclarations': [
            {
              'name': 'search',
              'description': 'Search the web',
              'parameters': {
                'type': 'object',
                'properties': {
                  'q': {'type': 'string'},
                },
              },
            },
          ],
        },
      ]);
    });

    test('claude- models include normalized tool call ids', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final model = Model(
        id: 'claude-sonnet-4-5',
        api: 'google-generative-ai',
        provider: 'google',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        contextWindow: 200000,
        maxTokens: 8192,
      );
      final timestamp = DateTime.utc(2026);
      final context = Context(
        messages: [
          AssistantMessage(
            content: const [
              ToolCall(
                id: 'call.1|extra',
                name: 'ping',
                arguments: {'host': 'example.com'},
              ),
            ],
            api: 'google-generative-ai',
            provider: 'google',
            model: 'claude-sonnet-4-5',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: timestamp,
          ),
          ToolResultMessage(
            toolCallId: 'call.1|extra',
            toolName: 'ping',
            content: const [TextContent(text: 'pong')],
            isError: false,
            timestamp: timestamp,
          ),
        ],
      );

      final stream = streamGoogle(
        model,
        context,
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      final contents = capturedBody!['contents'] as List;
      expect(contents[0], {
        'role': 'model',
        'parts': [
          {
            'functionCall': {
              'name': 'ping',
              'args': {'host': 'example.com'},
              'id': 'call_1_extra',
            },
          },
        ],
      });
      expect(contents[1], {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'ping',
              'response': {'output': 'pong'},
              'id': 'call_1_extra',
            },
          },
        ],
      });
    });

    test('cross-provider thinking becomes plain text without signatures', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([textChunk('hi')]))),
          200,
        );
      });

      final context = Context(
        messages: [
          AssistantMessage(
            content: const [
              ThinkingContent(
                thinking: 'other model thought',
                thinkingSignature: 'c2lnMQ==',
              ),
              TextContent(text: 'answer', textSignature: 'invalid sig!'),
            ],
            api: 'anthropic-messages',
            provider: 'anthropic',
            model: 'claude-sonnet-4-5',
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.utc(2026),
          ),
        ],
      );

      final stream = streamGoogle(
        testModel,
        context,
        const GoogleOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      final contents = capturedBody!['contents'] as List;
      expect(contents[0], {
        'role': 'model',
        'parts': [
          {'text': 'other model thought'},
          {'text': 'answer'},
        ],
      });
    });
  });
}
