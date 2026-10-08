// gh-1426 UT-3/UT-4 (AC6/AC7): a model-pinned thinking level reaches the
// wire per adapter, the reasoning:false gate never sends thinking fields,
// and `omitMaxOutputTokens` drops the max-output field for rejecting
// endpoints.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

const _okOpenAiSse =
    'data: {"id":"c","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"c","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

String _googleSse() =>
    'data: ${jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'ok'},
            ],
            'role': 'model',
          },
          'finishReason': 'STOP',
        },
      ],
    })}\n\n';

String _anthropicSse() =>
    'event: message_start\ndata: ${jsonEncode({
      'type': 'message_start',
      'message': {
        'id': 'msg_1',
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      },
    })}\n\n'
    'event: content_block_start\ndata: ${jsonEncode({
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    })}\n\n'
    'event: content_block_delta\ndata: ${jsonEncode({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': 'ok'},
    })}\n\n'
    'event: message_stop\ndata: {"type":"message_stop"}\n\n';

Context _ctx() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

Model _openAiModel({
  String? thinkingLevel,
  bool reasoning = true,
  OpenAICompletionsCompat? compat,
}) => Model(
  id: 'glm-5.3-flash',
  api: 'openai-completions',
  provider: 'zai',
  baseUrl: 'https://api.z.ai/api/coding/paas/v4',
  reasoning: reasoning,
  thinkingLevel: thinkingLevel,
  compat: compat,
  contextWindow: 200000,
  maxTokens: 16384,
);

Future<Map<String, dynamic>> _captureOpenAi(
  Model model, {
  OpenAICompletionsOptions? options,
}) async {
  Map<String, dynamic>? captured;
  final client = http_testing.MockClient.streaming((request, body) async {
    captured =
        jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_okOpenAiSse)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  final stream = streamOpenAICompletions(
    model,
    _ctx(),
    options ?? const OpenAICompletionsOptions(apiKey: 'k'),
    client,
  );
  await stream.result;
  return captured!;
}

Future<Map<String, dynamic>> _captureGoogle(
  Model model, {
  GoogleOptions? options,
}) async {
  Map<String, dynamic>? captured;
  final client = http_testing.MockClient.streaming((request, body) async {
    captured =
        jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_googleSse())),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  final stream = streamGoogle(
    model,
    _ctx(),
    options ?? GoogleOptions(apiKey: 'k'),
    client,
  );
  await stream.result;
  return captured!;
}

Future<Map<String, dynamic>> _captureAnthropic(Model model) async {
  Map<String, dynamic>? captured;
  final client = http_testing.MockClient.streaming((request, body) async {
    captured =
        jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_anthropicSse())),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  final stream = streamAnthropic(
    model,
    _ctx(),
    const AnthropicOptions(apiKey: 'k'),
    client,
  );
  await stream.result;
  return captured!;
}

void main() {
  group('openai-completions wire — pinned thinking level (AC6)', () {
    test('model.thinkingLevel rides reasoning_effort', () async {
      final body = await _captureOpenAi(_openAiModel(thinkingLevel: 'high'));
      expect(body['reasoning_effort'], 'high');
    });

    test('openrouter-shaped endpoints get the nested reasoning object',
        () async {
      final body = await _captureOpenAi(
        Model(
          id: 'vendor/model',
          api: 'openai-completions',
          provider: 'openrouter',
          baseUrl: 'https://openrouter.ai/api/v1',
          reasoning: true,
          thinkingLevel: 'low',
          contextWindow: 200000,
          maxTokens: 16384,
        ),
      );
      expect(body['reasoning'], {'effort': 'low'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('reasoning:false model never sends the pinned level (E3)', () async {
      final body = await _captureOpenAi(
        _openAiModel(thinkingLevel: 'high', reasoning: false),
      );
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('reasoning'), isFalse);
    });

    test('an explicit options effort wins over the model pin', () async {
      final body = await _captureOpenAi(
        _openAiModel(thinkingLevel: 'high'),
        options: const OpenAICompletionsOptions(
          apiKey: 'k',
          reasoningEffort: 'low',
        ),
      );
      expect(body['reasoning_effort'], 'low');
    });

    test('no pin → byte-identical payload (REG-1)', () async {
      final body = await _captureOpenAi(_openAiModel());
      expect(body.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('openai-completions wire — omitMaxOutputTokens (AC7)', () {
    test('the flag omits every max-output field spelling', () async {
      final body = await _captureOpenAi(
        _openAiModel(
          compat: const OpenAICompletionsCompat(omitMaxOutputTokens: true),
        ),
      );
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });

    test('without the flag the default field rides (REG-1)', () async {
      final body = await _captureOpenAi(_openAiModel());
      expect(body['max_completion_tokens'], 16384);
    });

    test('an explicit options maxTokens is omitted under the flag too',
        () async {
      final body = await _captureOpenAi(
        _openAiModel(
          compat: const OpenAICompletionsCompat(omitMaxOutputTokens: true),
        ),
        options: const OpenAICompletionsOptions(apiKey: 'k', maxTokens: 4096),
      );
      expect(body.containsKey('max_completion_tokens'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
    });
  });

  group('google wire — pinned thinking level (AC6)', () {
    test('model.thinkingLevel maps to the Gemini thinkingLevel ladder',
        () async {
      for (final entry in {
        'minimal': 'MINIMAL',
        'low': 'LOW',
        'medium': 'MEDIUM',
        'high': 'HIGH',
      }.entries) {
        final body = await _captureGoogle(
          Model(
            id: 'gemini-2.5-pro',
            api: 'google-generative-ai',
            provider: 'google',
            baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
            reasoning: true,
            thinkingLevel: entry.key,
            contextWindow: 1000000,
            maxTokens: 16384,
          ),
        );
        final config = body['generationConfig'] as Map<String, dynamic>;
        expect(
          config['thinkingConfig'],
          {'includeThoughts': true, 'thinkingLevel': entry.value},
          reason: 'level ${entry.key}',
        );
      }
    });

    test('reasoning:false model never sends thinkingConfig (E3)', () async {
      final body = await _captureGoogle(
        Model(
          id: 'gemini-2.5-pro',
          api: 'google-generative-ai',
          provider: 'google',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          reasoning: false,
          thinkingLevel: 'high',
          contextWindow: 1000000,
          maxTokens: 16384,
        ),
      );
      final config = body['generationConfig'] as Map<String, dynamic>?;
      expect(config?['thinkingConfig'], isNull);
    });

    test('an explicit options thinking wins over the model pin', () async {
      final body = await _captureGoogle(
        Model(
          id: 'gemini-2.5-pro',
          api: 'google-generative-ai',
          provider: 'google',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          reasoning: true,
          thinkingLevel: 'high',
          contextWindow: 1000000,
          maxTokens: 16384,
        ),
        options: GoogleOptions(
          apiKey: 'k',
          thinking: const GoogleThinking(enabled: true, budgetTokens: 2048),
        ),
      );
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['thinkingConfig'], {
        'includeThoughts': true,
        'thinkingBudget': 2048,
      });
    });

    test('no pin → no thinkingConfig (REG-1)', () async {
      final body = await _captureGoogle(
        Model(
          id: 'gemini-2.5-pro',
          api: 'google-generative-ai',
          provider: 'google',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          reasoning: true,
          contextWindow: 1000000,
          maxTokens: 16384,
        ),
      );
      final config = body['generationConfig'] as Map<String, dynamic>?;
      expect(config?['thinkingConfig'], isNull);
    });
  });

  group('anthropic wire — pinned thinking level (AC6 re-assert)', () {
    test('model.thinkingLevel rides the budget ladder', () async {
      final body = await _captureAnthropic(
        Model(
          id: 'claude-sonnet-4-5',
          api: 'anthropic-messages',
          provider: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          reasoning: true,
          thinkingLevel: 'medium',
          contextWindow: 200000,
          maxTokens: 64000,
        ),
      );
      expect(body['thinking']['budget_tokens'], 8192);
      expect(body['max_tokens'], 64000);
    });

    test('reasoning:false model never sends thinking (E3)', () async {
      final body = await _captureAnthropic(
        Model(
          id: 'claude-sonnet-4-5',
          api: 'anthropic-messages',
          provider: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          reasoning: false,
          thinkingLevel: 'medium',
          contextWindow: 200000,
          maxTokens: 64000,
        ),
      );
      expect(body.containsKey('thinking'), isFalse);
    });
  });
}
