import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Encodes one named Anthropic SSE event (`event:` + `data:`).
String sseEvent(String name, Map<String, dynamic> json) {
  return 'event: $name\ndata: ${jsonEncode(json)}\n\n';
}

/// Concatenates SSE body parts: [Map]s are encoded as named events, [String]s
/// are used verbatim (e.g. a `ping` event or malformed payload).
String sseBody(List<Object> parts) {
  return parts
      .map(
        (part) => part is String
            ? part
            : sseEvent((part as Map<String, dynamic>)['type'] as String, part),
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

Map<String, dynamic> messageStart({Map<String, dynamic>? usage}) => {
  'type': 'message_start',
  'message': {
    'id': 'msg_1',
    'usage': usage ?? {'input_tokens': 10, 'output_tokens': 1},
  },
};

Map<String, dynamic> blockStart(int index, Map<String, dynamic> block) => {
  'type': 'content_block_start',
  'index': index,
  'content_block': block,
};

Map<String, dynamic> blockDelta(int index, Map<String, dynamic> delta) => {
  'type': 'content_block_delta',
  'index': index,
  'delta': delta,
};

Map<String, dynamic> blockStop(int index) => {
  'type': 'content_block_stop',
  'index': index,
};

Map<String, dynamic> messageDelta(
  String stopReason, {
  Map<String, dynamic>? usage,
  Map<String, dynamic>? stopDetails,
}) => {
  'type': 'message_delta',
  'delta': {'stop_reason': stopReason, 'stop_details': ?stopDetails},
  'usage': ?usage,
};

final messageStop = {'type': 'message_stop'};

final testModel = Model(
  id: 'claude-sonnet-4-5',
  name: 'Claude Sonnet 4.5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  contextWindow: 200000,
  maxTokens: 8192,
  cost: const ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
);

final reasoningModel = Model(
  id: 'claude-sonnet-4-5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  reasoning: true,
  contextWindow: 200000,
  maxTokens: 64000,
);

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

void main() {
  group('streamAnthropic', () {
    test('streams text with live partial accumulation', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {'type': 'text', 'text': ''}),
          blockDelta(0, {'type': 'text_delta', 'text': 'Hel'}),
          blockDelta(0, {'type': 'text_delta', 'text': 'lo'}),
          blockStop(0),
          messageDelta('end_turn', usage: {'output_tokens': 2}),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
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
      expect(done.message.responseId, 'msg_1');
      expect(done.message.usage.input, 10);
      expect(done.message.usage.output, 2);
      expect(done.message.usage.totalTokens, 12);
      expect(done.message.usage.cost.total, greaterThan(0));

      expect(await stream.result, same(done.message));
    });

    test('streams thinking deltas and accumulates the signature', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {'type': 'thinking', 'thinking': ''}),
          blockDelta(0, {'type': 'thinking_delta', 'thinking': 'let me '}),
          blockDelta(0, {'type': 'thinking_delta', 'thinking': 'think'}),
          blockDelta(0, {'type': 'signature_delta', 'signature': 'sig-abc'}),
          blockStop(0),
          blockStart(1, {'type': 'text', 'text': ''}),
          blockDelta(1, {'type': 'text_delta', 'text': 'answer'}),
          blockStop(1),
          messageDelta(
            'end_turn',
            usage: {
              'output_tokens': 30,
              'output_tokens_details': {'thinking_tokens': 12},
            },
          ),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        reasoningModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
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
      expect(thinking.thinkingSignature, 'sig-abc');
      expect(done.message.usage.reasoning, 12);
    });

    test('streams redacted_thinking blocks', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {
            'type': 'redacted_thinking',
            'data': 'encrypted-payload',
          }),
          blockStop(0),
          messageDelta('end_turn'),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        reasoningModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ThinkingStartEvent>(), hasLength(1));
      final done = events.last as DoneEvent;
      final thinking = done.message.content.single as ThinkingContent;
      expect(thinking.redacted, isTrue);
      expect(thinking.thinking, '[Reasoning redacted]');
      expect(thinking.thinkingSignature, 'encrypted-payload');
    });

    test('streams tool_use with partial JSON arguments', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'get_weather',
            'input': <String, dynamic>{},
          }),
          blockDelta(0, {'type': 'input_json_delta', 'partial_json': '{"loc'}),
          blockDelta(0, {
            'type': 'input_json_delta',
            'partial_json': 'ation":"Paris"}',
          }),
          blockStop(0),
          messageDelta('tool_use'),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      expect(events.whereType<ToolCallStartEvent>(), hasLength(1));

      final deltas = events.whereType<ToolCallDeltaEvent>().toList();
      expect(deltas, hasLength(2));
      expect(deltas[0].delta, '{"loc');
      final firstPartial = deltas[0].partial.content.single as ToolCall;
      expect(firstPartial.id, 'toolu_1');
      expect(firstPartial.name, 'get_weather');
      expect(firstPartial.partialArguments, '{"loc');
      expect(firstPartial.arguments, isEmpty);

      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.id, 'toolu_1');
      expect(end.toolCall.name, 'get_weather');
      expect(end.toolCall.arguments, {'location': 'Paris'});
      expect(end.toolCall.partialArguments, isNull);

      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.toolUse);
      expect(done.message.content.single, isA<ToolCall>());
    });

    test(
      'keeps complete tool_use input when no argument deltas arrive',
      () async {
        final client = sseClient(
          sseBody([
            messageStart(),
            blockStart(0, {
              'type': 'tool_use',
              'id': 'toolu_9',
              'name': 'ping',
              'input': {'host': 'example.com'},
            }),
            blockStop(0),
            messageDelta('tool_use'),
            messageStop,
          ]),
        );

        final stream = streamAnthropic(
          testModel,
          simpleContext(),
          const AnthropicOptions(apiKey: 'test-key'),
          client,
        );

        final events = await stream.toList();
        final end = events.whereType<ToolCallEndEvent>().single;
        expect(end.toolCall.arguments, {'host': 'example.com'});
        expect(end.toolCall.partialArguments, isNull);
      },
    );

    test('handles multi-block sequences interleaved across indices', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {'type': 'thinking', 'thinking': ''}),
          blockStart(1, {'type': 'text', 'text': ''}),
          blockDelta(1, {'type': 'text_delta', 'text': 'ans'}),
          blockDelta(0, {'type': 'thinking_delta', 'thinking': 'why'}),
          blockStart(2, {
            'type': 'tool_use',
            'id': 'toolu_2',
            'name': 'search',
            'input': <String, dynamic>{},
          }),
          blockDelta(2, {
            'type': 'input_json_delta',
            'partial_json': '{"q":"x"}',
          }),
          blockStop(1),
          blockStop(0),
          blockStop(2),
          messageDelta('tool_use'),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        reasoningModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final done = events.last as DoneEvent;
      expect(done.message.content, hasLength(3));
      expect(done.message.content[0], isA<ThinkingContent>());
      expect((done.message.content[0] as ThinkingContent).thinking, 'why');
      expect((done.message.content[1] as TextContent).text, 'ans');
      expect((done.message.content[2] as ToolCall).arguments, {'q': 'x'});

      final textEnd = events.whereType<TextEndEvent>().single;
      expect(textEnd.contentIndex, 1);
      expect(textEnd.content, 'ans');
      final toolEnd = events.whereType<ToolCallEndEvent>().single;
      expect(toolEnd.contentIndex, 2);
    });

    test('maps usage incl. cache tokens and preserves start values', () async {
      final client = sseClient(
        sseBody([
          messageStart(
            usage: {
              'input_tokens': 100,
              'output_tokens': 1,
              'cache_read_input_tokens': 80,
              'cache_creation_input_tokens': 20,
              'cache_creation': {'ephemeral_1h_input_tokens': 20},
            },
          ),
          blockStart(0, {'type': 'text', 'text': ''}),
          blockDelta(0, {'type': 'text_delta', 'text': 'hi'}),
          blockStop(0),
          // message_delta omits input/cache fields (proxies do this); the
          // message_start values must survive.
          messageDelta('end_turn', usage: {'output_tokens': 50}),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final message = await stream.result;
      expect(message.usage.input, 100);
      expect(message.usage.output, 50);
      expect(message.usage.cacheRead, 80);
      expect(message.usage.cacheWrite, 20);
      expect(message.usage.cacheWrite1h, 20);
      expect(message.usage.totalTokens, 250);
      // 100*3 + 50*15 + 80*0.3 + 20*3.75 per million tokens.
      expect(
        message.usage.cost.total,
        closeTo((300 + 750 + 24 + 75) / 1e6, 1e-12),
      );
    });

    test('max_tokens stop reason maps to length', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {'type': 'text', 'text': ''}),
          blockDelta(0, {'type': 'text_delta', 'text': 'cut'}),
          blockStop(0),
          messageDelta('max_tokens'),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final done = (await stream.toList()).last as DoneEvent;
      expect(done.reason, StopReason.length);
    });

    test('429 becomes an error event, never an exception', () async {
      final client = http_testing.MockClient(
        (request) async =>
            http.Response('{"error":{"message":"Rate limit exceeded"}}', 429),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.single as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.stopReason, StopReason.error);
      expect(error.error.errorMessage, contains('429'));
      expect(error.error.errorMessage, contains('Rate limit exceeded'));
      expect(await stream.result, same(error.error));
    });

    test('provider error SSE event becomes an error event', () async {
      final client = sseClient(
        'event: error\n'
        'data: {"type":"error","error":{"message":"overloaded_error"}}\n\n',
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('overloaded_error'));
    });

    test(
      'malformed SSE data becomes an error event, not an exception',
      () async {
        final client = sseClient(
          'event: content_block_delta\ndata: {not valid json\n\n',
        );

        final stream = streamAnthropic(
          testModel,
          simpleContext(),
          const AnthropicOptions(apiKey: 'test-key'),
          client,
        );

        final events = await stream.toList();
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, contains('Could not parse'));
        expect(error.error.errorMessage, contains('content_block_delta'));
      },
    );

    test('stream ending before message_stop becomes an error event', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          blockStart(0, {'type': 'text', 'text': ''}),
          blockDelta(0, {'type': 'text_delta', 'text': 'cut off'}),
          blockStop(0),
        ]),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('message_stop'));
      expect((error.error.content.single as TextContent).text, 'cut off');
    });

    test('unknown stop reason becomes an error event', () async {
      final client = sseClient(
        sseBody([
          messageStart(),
          messageDelta('weird_new_reason'),
          messageStop,
        ]),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('weird_new_reason'));
    });

    test(
      'refusal stop reason becomes an error event with explanation',
      () async {
        final client = sseClient(
          sseBody([
            messageStart(),
            blockStart(0, {'type': 'text', 'text': ''}),
            blockStop(0),
            messageDelta(
              'refusal',
              stopDetails: {'explanation': 'I cannot help with that'},
            ),
            messageStop,
          ]),
        );

        final stream = streamAnthropic(
          testModel,
          simpleContext(),
          const AnthropicOptions(apiKey: 'test-key'),
          client,
        );

        final events = await stream.toList();
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, contains('I cannot help with that'));
      },
    );

    test('network failure becomes an error event', () async {
      final client = http_testing.MockClient(
        (request) async => throw http.ClientException('connection reset'),
      );

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('connection reset'));
    });

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
        final stream = streamAnthropic(
          testModel,
          simpleContext(),
          AnthropicOptions(apiKey: 'test-key', cancelToken: source.token),
          client,
        );

        final events = <AssistantMessageEvent>[];
        final consumed = stream.forEach(events.add);

        controller.add(
          utf8.encode(
            sseBody([
              messageStart(),
              blockStart(0, {'type': 'text', 'text': ''}),
              blockDelta(0, {'type': 'text_delta', 'text': 'partial'}),
            ]),
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

    test(
      'CancelToken abort before sending ends with aborted stop reason',
      () async {
        var requestSent = false;
        final client = http_testing.MockClient.streaming((request, body) async {
          requestSent = true;
          return http.StreamedResponse(
            Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
            200,
          );
        });

        final source = CancelTokenSource()..cancel();
        final stream = streamAnthropic(
          testModel,
          simpleContext(),
          AnthropicOptions(apiKey: 'test-key', cancelToken: source.token),
          client,
        );

        final events = await stream.toList();
        expect(requestSent, isFalse);
        final error = events.last as ErrorEvent;
        expect(error.reason, StopReason.aborted);
      },
    );

    test('baseUrl swap routes the request to {baseUrl}/v1/messages', () async {
      Uri? capturedUrl;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedUrl = request.url;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final model = Model(
        id: 'claude-sonnet-4-5',
        api: 'anthropic-messages',
        provider: 'anthropic',
        baseUrl: 'https://proxy.example.com',
        contextWindow: 200000,
        maxTokens: 8192,
      );
      final stream = streamAnthropic(
        model,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      expect(capturedUrl.toString(), 'https://proxy.example.com/v1/messages');
    });

    test('sends anthropic headers and merges with null suppression', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final model = Model(
        id: 'claude-sonnet-4-5',
        api: 'anthropic-messages',
        provider: 'anthropic',
        baseUrl: 'https://api.anthropic.com',
        contextWindow: 200000,
        maxTokens: 8192,
        headers: const {'x-model': 'model-default', 'x-keep': 'keep'},
      );

      final stream = streamAnthropic(
        model,
        simpleContext(),
        const AnthropicOptions(
          apiKey: 'test-key',
          headers: {'x-custom': 'custom', 'x-model': null},
        ),
        client,
      );
      await stream.result;

      expect(capturedHeaders!['x-api-key'], 'test-key');
      expect(capturedHeaders!['anthropic-version'], '2023-06-01');
      expect(capturedHeaders!['accept'], 'application/json');
      expect(capturedHeaders!['content-type'], 'application/json');
      expect(
        capturedHeaders!['anthropic-beta'],
        'interleaved-thinking-2025-05-14',
      );
      expect(capturedHeaders!['x-keep'], 'keep');
      expect(capturedHeaders!['x-custom'], 'custom');
      expect(capturedHeaders!.containsKey('x-model'), isFalse);
    });

    test('interleavedThinking: false drops the beta header', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key', interleavedThinking: false),
        client,
      );
      await stream.result;

      expect(capturedHeaders!.containsKey('anthropic-beta'), isFalse);
    });

    test('missing API key becomes an error event', () async {
      final client = sseClient(sseBody([messageStart(), messageStop]));
      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(),
        client,
      );

      final events = await stream.toList();
      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('No API key'));
    });

    test('an x-api-key option header satisfies auth without apiKey', () async {
      Map<String, String>? capturedHeaders;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedHeaders = request.headers;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        const AnthropicOptions(headers: {'x-api-key': 'header-key'}),
        client,
      );
      await stream.result;

      expect(capturedHeaders!['x-api-key'], 'header-key');
    });

    test(
      'builds the request payload from context, tools, and options',
      () async {
        Map<String, dynamic>? capturedBody;
        var onPayloadSeen = false;
        var onResponseSeen = false;
        final client = http_testing.MockClient.streaming((request, body) async {
          capturedBody =
              jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
          return http.StreamedResponse(
            Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
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
                ThinkingContent(thinking: 'hmm', thinkingSignature: 'sig_1'),
                TextContent(text: 'Let me check.'),
                ToolCall(
                  id: 'call.1|extra',
                  name: 'get_weather',
                  arguments: {'location': 'Paris'},
                ),
              ],
              api: 'anthropic-messages',
              provider: 'anthropic',
              model: 'claude-sonnet-4-5',
              usage: Usage.zero,
              stopReason: StopReason.toolUse,
              timestamp: timestamp,
            ),
            ToolResultMessage(
              toolCallId: 'call.1|extra',
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
                'required': ['location'],
              },
            ),
          ],
        );

        final stream = streamAnthropic(
          testModel,
          context,
          AnthropicOptions(
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
        expect(body['model'], 'claude-sonnet-4-5');
        expect(body['stream'], isTrue);
        expect(body['max_tokens'], 512);
        expect(body['temperature'], 0.2);
        expect(body['tool_choice'], {'type': 'auto'});

        expect(body['system'], [
          {
            'type': 'text',
            'text': 'You are helpful.',
            'cache_control': {'type': 'ephemeral'},
          },
        ]);

        final messages = body['messages'] as List;
        expect(messages[0], {
          'role': 'user',
          'content': 'What is the weather?',
        });
        expect(messages[1], {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'hmm', 'signature': 'sig_1'},
            {'type': 'text', 'text': 'Let me check.'},
            {
              'type': 'tool_use',
              // Tool call ids are sanitized to Anthropic's allowed pattern.
              'id': 'call_1_extra',
              'name': 'get_weather',
              'input': {'location': 'Paris'},
            },
          ],
        });
        expect(messages[2], {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call_1_extra',
              'content': 'Sunny, 21C',
              'is_error': false,
            },
          ],
        });
        expect(messages[3], {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'And here is a picture:'},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/png',
                'data': 'aGk=',
              },
              // Cache breakpoint lands on the last block of the last user
              // message.
              'cache_control': {'type': 'ephemeral'},
            },
          ],
        });

        expect(body['tools'], [
          {
            'name': 'get_weather',
            'description': 'Get the weather',
            'eager_input_streaming': true,
            'input_schema': {
              'type': 'object',
              'properties': {
                'location': {'type': 'string'},
              },
              'required': ['location'],
            },
            'cache_control': {'type': 'ephemeral'},
          },
        ]);
      },
    );

    test('consecutive tool results group into one user message', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final timestamp = DateTime.utc(2026);
      final context = Context(
        messages: [
          ToolResultMessage(
            toolCallId: 'toolu_1',
            toolName: 'a',
            content: const [TextContent(text: 'first')],
            isError: false,
            timestamp: timestamp,
          ),
          ToolResultMessage(
            toolCallId: 'toolu_2',
            toolName: 'b',
            content: const [
              TextContent(text: 'second'),
              ImageContent(data: 'aGk=', mimeType: 'image/png'),
            ],
            isError: true,
            timestamp: timestamp,
          ),
        ],
      );

      final stream = streamAnthropic(
        testModel,
        context,
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      final messages = capturedBody!['messages'] as List;
      expect(messages, hasLength(1));
      expect(messages[0]['role'], 'user');
      final content = messages[0]['content'] as List;
      expect(content[0], {
        'type': 'tool_result',
        'tool_use_id': 'toolu_1',
        'content': 'first',
        'is_error': false,
      });
      expect(content[1], {
        'type': 'tool_result',
        'tool_use_id': 'toolu_2',
        'content': [
          {'type': 'text', 'text': 'second'},
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/png',
              'data': 'aGk=',
            },
          },
        ],
        'is_error': true,
        // Cache breakpoint on the last tool_result block.
        'cache_control': {'type': 'ephemeral'},
      });
    });

    test('image-only tool result gets placeholder text', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final context = Context(
        messages: [
          ToolResultMessage(
            toolCallId: 'toolu_1',
            toolName: 'screenshot',
            content: const [ImageContent(data: 'aGk=', mimeType: 'image/png')],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
        ],
      );

      final stream = streamAnthropic(
        testModel,
        context,
        const AnthropicOptions(apiKey: 'test-key'),
        client,
      );
      await stream.result;

      final messages = capturedBody!['messages'] as List;
      final content = (messages[0]['content'] as List).first;
      expect(content['content'], [
        {'type': 'text', 'text': '(see attached image)'},
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': 'aGk=',
          },
        },
      ]);
    });

    test('sends thinking config for reasoning models', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final stream = streamAnthropic(
        reasoningModel,
        simpleContext(),
        const AnthropicOptions(
          apiKey: 'test-key',
          temperature: 0.2,
          thinkingEnabled: true,
          thinkingBudgetTokens: 2048,
          thinkingDisplay: 'omitted',
        ),
        client,
      );
      await stream.result;

      expect(capturedBody!['thinking'], {
        'type': 'enabled',
        'budget_tokens': 2048,
        'display': 'omitted',
      });
      // Temperature is incompatible with extended thinking.
      expect(capturedBody!.containsKey('temperature'), isFalse);
    });

    test('thinkingEnabled: false sends disabled thinking', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final stream = streamAnthropic(
        reasoningModel,
        simpleContext(),
        const AnthropicOptions(apiKey: 'test-key', thinkingEnabled: false),
        client,
      );
      await stream.result;

      expect(capturedBody!['thinking'], {'type': 'disabled'});
    });

    test('cacheRetention none omits cache_control everywhere', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final context = Context(
        systemPrompt: 'sys',
        messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
        tools: const [
          Tool(name: 't', description: 'd', parameters: {'type': 'object'}),
        ],
      );
      final stream = streamAnthropic(
        testModel,
        context,
        const AnthropicOptions(apiKey: 'test-key', cacheRetention: 'none'),
        client,
      );
      await stream.result;

      final encoded = jsonEncode(capturedBody);
      expect(encoded, isNot(contains('cache_control')));
      // max_tokens falls back to the model cap.
      expect(capturedBody!['max_tokens'], 8192);
    });

    test('cacheRetention long requests a 1h TTL', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final stream = streamAnthropic(
        testModel,
        Context(
          systemPrompt: 'sys',
          messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))],
        ),
        const AnthropicOptions(apiKey: 'test-key', cacheRetention: 'long'),
        client,
      );
      await stream.result;

      expect(capturedBody!['system'], [
        {
          'type': 'text',
          'text': 'sys',
          'cache_control': {'type': 'ephemeral', 'ttl': '1h'},
        },
      ]);
    });

    test('onPayload can replace the request payload', () async {
      Map<String, dynamic>? capturedBody;
      final client = http_testing.MockClient.streaming((request, body) async {
        capturedBody =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody([messageStart(), messageStop]))),
          200,
        );
      });

      final stream = streamAnthropic(
        testModel,
        simpleContext(),
        AnthropicOptions(
          apiKey: 'test-key',
          onPayload: (payload, model) => {...payload, 'max_tokens': 42},
        ),
        client,
      );
      await stream.result;

      expect(capturedBody!['max_tokens'], 42);
    });
  });
}
