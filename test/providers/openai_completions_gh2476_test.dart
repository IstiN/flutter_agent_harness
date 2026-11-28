import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'openai_completions_fixtures.dart';

void main() {
  group('streamOpenAICompletions', () {
    test('gh-2476: a rich error payload on the final finish_reason:error '
        'chunk is captured into errorMessage (redacted, bounded)', () async {
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
            'id': 'chatcmpl-err',
            'choices': [
              {
                'delta': <String, dynamic>{},
                'finish_reason': 'error',
                'error': {
                  'message':
                      'upstream decode failure for org acme '
                      '(key sk-projABCDEFGHIJKLMNOPQRSTUVWXYZabcd leaked)',
                  'code': 'model_overloaded',
                  'details': {'hint': 'retry with backoff'},
                },
              },
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final events = await streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'sk-placeholder'),
        client,
      ).toList();

      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      final text = error.error.errorMessage!;
      // The literal prefix survives (every classifier keys on it).
      expect(text, startsWith('Provider finish_reason: error'));
      // The provider's own detail rides the same line — the per-attempt
      // evidence log keeps only the first line.
      expect(text, contains(' — provider said: '));
      expect(text, contains('upstream decode failure for org acme'));
      expect(text, contains('model_overloaded'));
      // Redacted: a vendor-key shape inside the payload never survives.
      expect(text, contains('[REDACTED:OpenAI-Key]'));
      expect(text, isNot(contains('sk-projABCDEFGHIJKLMNOPQRSTUVWXYZabcd')));
      expect(error.error.rawStopReason, 'error');
    });

    test('gh-2476: network_error finish reason captures choice error '
        'detail', () async {
      final client = sseClient(
        sseBody([
          {
            'choices': [
              {
                'delta': <String, dynamic>{},
                'finish_reason': 'network_error',
                'error': {'message': 'bad gateway to upstream'},
              },
            ],
          },
          'data: [DONE]\n\n',
        ]),
      );

      final events = await streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'k'),
        client,
      ).toList();

      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      final text = error.error.errorMessage!;
      expect(text, startsWith('Provider finish_reason: network_error'));
      expect(text, contains('bad gateway to upstream'));
    });

    test('gh-2476: an SSE-level {"error": …} chunk without choices is '
        'captured, not discarded', () async {
      final client = sseClient(
        sseBody([
          {
            'error': {
              'message': 'The model is over capacity',
              'type': 'server_error',
            },
          },
          'data: [DONE]\n\n',
        ]),
      );

      final events = await streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'k'),
        client,
      ).toList();

      final error = events.last as ErrorEvent;
      expect(error.reason, StopReason.error);
      final text = error.error.errorMessage!;
      expect(text, contains('The model is over capacity'));
      expect(text, contains('server_error'));
    });

    test('gh-2476: a >2KB non-200 body is bounded and redacted in the '
        'error message', () async {
      final filler = List.filled(4000, 'x').join();
      final client = http_testing.MockClient(
        (request) async => http.Response(
          '{"error":{"message":"sk-projABCDEFGHIJKLMNOPQRSTUVWXYZabcd'
          ' head key","filler":"$filler"}}',
          502,
          headers: {'content-type': 'application/json'},
        ),
      );

      final events = await streamOpenAICompletions(
        testModel,
        simpleContext(),
        const OpenAICompletionsOptions(apiKey: 'k'),
        client,
      ).toList();

      final error = events.last as ErrorEvent;
      final text = error.error.errorMessage!;
      expect(text, startsWith('502:'));
      // Bounded around the 2KB capture budget (the message head adds a
      // little): well below the raw 4KB body.
      expect(text.length, lessThan(2048 + 200));
      expect(text, isNot(contains(filler)));
      // Redacted: the vendor-key shape inside the body never survives.
      expect(text, contains('[REDACTED:OpenAI-Key]'));
      expect(text, isNot(contains('sk-projABCDEFGHIJKLMNOPQRSTUVWXYZabcd')));
    });
  });
}
