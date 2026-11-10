import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// Split out of openai_completions_test.dart (gh-1232 loc-scope ceiling:
// the whole-tree test/ cap at 2800 lines; this suite stays under it with
// the provider-specific URL fixtures living here).
const okSse =
    'data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

void main() {
  group('streamOpenAICompletions (AIIN base URL)', () {
    test('normalizes a scheme-less AIIN base URL before sending', () async {
      Uri? requestedUrl;
      final client = http_testing.MockClient.streaming((request, body) async {
        requestedUrl = request.url;
        return http.StreamedResponse(
          Stream.value(utf8.encode(okSse)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final model = Model(
        id: 'openai/gpt-4o-mini',
        api: 'openai-completions',
        provider: 'aiin',
        baseUrl: 'api.aiin.by/v1',
        contextWindow: 200000,
        maxTokens: 16384,
      );

      final events = await streamOpenAICompletions(
        model,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: '[REDACTED:Sensitive-Value]'),
        client,
      ).toList();

      expect(
        requestedUrl,
        Uri.parse('https://api.aiin.by/v1/chat/completions'),
      );
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });
  });
}
