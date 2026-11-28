import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

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

/// Streams [reasoningChunks] as `reasoning` deltas and returns the final
/// thinking text (gh-1655 stuttering-relay fixtures).
Future<String> reasoningThinkingOf(List<String> reasoningChunks) async {
  final client = sseClient(
    sseBody([
      for (final text in reasoningChunks)
        {
          'choices': [
            {
              'delta': {'reasoning': text},
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
    const OpenAICompletionsOptions(apiKey: '[REDACTED:Sensitive-Value]'),
    client,
  );
  final events = await stream.toList();
  return events.whereType<ThinkingEndEvent>().single.content;
}
