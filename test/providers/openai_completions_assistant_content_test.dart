import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Assistant-turn `content` wire-shape coverage for the OpenAI-completions
/// dialect (gh-2221). Lives in its own file because the main
/// openai_completions_test.dart sits against the 2800-line loc ratchet
/// (crap4dart.loc-scope.yaml, whole-tree in the guards job).

const okSse =
    'data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

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

AssistantMessage assistant({
  required List<ContentBlock> content,
  required StopReason stopReason,
}) {
  return AssistantMessage(
    content: content,
    api: 'openai-completions',
    provider: 'openai',
    model: 'gpt-4o-mini',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  /// Streams [context] through a capturing client and returns the decoded
  /// request body.
  Future<Map<String, dynamic>> sentBody(Model model, Context context) async {
    Map<String, dynamic>? body;
    final client = http_testing.MockClient.streaming((
      request,
      requestBody,
    ) async {
      body =
          jsonDecode(await requestBody.bytesToString()) as Map<String, dynamic>;
      return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
    });
    final stream = streamOpenAICompletions(
      model,
      context,
      const OpenAICompletionsOptions(apiKey: '[REDACTED:Sensitive Value]'),
      client,
    );
    await stream.result;
    return body!;
  }

  List<dynamic> messagesOf(Map<String, dynamic> body) =>
      body['messages'] as List<dynamic>;

  test('a tool-calls-only assistant message carries an explicit content: null '
      '(gh-2221 — strict OpenAI-compatible backends with a '
      'discriminated-union request schema reject the message when the key '
      'is omitted, surfacing a confusing unrelated-field error)', () async {
    final body = await sentBody(
      testModel,
      Context(
        messages: [
          assistant(
            content: const [TextContent(text: 'Working on it.')],
            stopReason: StopReason.stop,
          ),
          assistant(
            content: const [
              TextContent(text: 'Let me check.'),
              ToolCall(id: 'c1', name: 'read', arguments: {}),
            ],
            stopReason: StopReason.toolUse,
          ),
          assistant(
            content: const [ToolCall(id: 'c2', name: 'bash', arguments: {})],
            stopReason: StopReason.toolUse,
          ),
        ],
      ),
    );
    expect(messagesOf(body), [
      {'role': 'assistant', 'content': 'Working on it.'},
      {
        'role': 'assistant',
        'content': 'Let me check.',
        'tool_calls': [
          {
            'id': 'c1',
            'type': 'function',
            'function': {'name': 'read', 'arguments': '{}'},
          },
        ],
      },
      {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'c2',
            'type': 'function',
            'function': {'name': 'bash', 'arguments': '{}'},
          },
        ],
      },
    ]);
  });
}
