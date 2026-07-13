/// Tests for [isContextOverflow] — ported from pi's
/// `packages/ai/test/overflow.test.ts`, extended to cover every overflow
/// regex branch positively and negatively.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage errorMessage(String errorMessage) {
  return AssistantMessage(
    content: const [],
    api: 'openai-completions',
    provider: 'ollama',
    model: 'qwen3.5:35b',
    usage: Usage.zero,
    stopReason: StopReason.error,
    errorMessage: errorMessage,
    timestamp: DateTime.now(),
  );
}

AssistantMessage lengthStopMessage(int input, int cacheRead, int output) {
  return AssistantMessage(
    content: const [],
    api: 'openai-completions',
    provider: 'xiaomi',
    model: 'mimo-v2.5-pro',
    usage: Usage(
      input: input,
      output: output,
      cacheRead: cacheRead,
      cacheWrite: 0,
      totalTokens: input + cacheRead + output,
      cost: const UsageCost(),
    ),
    stopReason: StopReason.length,
    timestamp: DateTime.now(),
  );
}

AssistantMessage stopMessage(int input, int cacheRead) {
  return AssistantMessage(
    content: const [],
    api: 'openai-completions',
    provider: 'z',
    model: 'glm-4.6',
    usage: Usage(
      input: input,
      output: 100,
      cacheRead: cacheRead,
      cacheWrite: 0,
      totalTokens: input + cacheRead + 100,
      cost: const UsageCost(),
    ),
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );
}

void main() {
  group('isContextOverflow — ported pi cases', () {
    test('detects explicit Ollama prompt-too-long errors', () {
      final message = errorMessage(
        '400 `prompt too long; exceeded max context length by 100918 tokens`',
      );
      expect(isContextOverflow(message, contextWindow: 32768), isTrue);
    });

    test('detects Together AI context length errors', () {
      final message = errorMessage(
        '400 The input (516368 tokens) is longer than the model\'s context '
        'length (262144 tokens).',
      );
      expect(isContextOverflow(message, contextWindow: 262144), isTrue);
    });

    test('detects LiteLLM-wrapped OpenAI maximum context length errors', () {
      final message = errorMessage(
        'Error: 503 litellm.ServiceUnavailableError: '
        'litellm.MidStreamFallbackError: litellm.APIConnectionError: '
        'APIConnectionError: OpenAIException - Requested token count exceeds '
        'the model\'s maximum context length of 131072 tokens.',
      );
      expect(isContextOverflow(message, contextWindow: 131072), isTrue);
    });

    test('detects parenthesized maximum context length errors', () {
      final message = errorMessage(
        "Error: 400 Input length (265330) exceeds model's maximum context "
        'length (262144).',
      );
      expect(isContextOverflow(message, contextWindow: 262144), isTrue);
    });

    test('detects OpenRouter Poolside maximum allowed input length errors', () {
      final message = errorMessage(
        'Provider returned error: Input length 131393 exceeds the maximum '
        'allowed input length of 131040 tokens.',
      );
      expect(isContextOverflow(message, contextWindow: 131072), isTrue);
    });

    test('detects DS4 configured context size errors', () {
      final message = errorMessage(
        '400 Prompt has 256468 tokens, but the configured context size is '
        '256000 tokens',
      );
      expect(isContextOverflow(message, contextWindow: 256000), isTrue);

      final commaMessage = errorMessage(
        'Prompt has 5,958,968 tokens, but the configured context size is '
        '256,000 tokens',
      );
      expect(isContextOverflow(commaMessage, contextWindow: 256000), isTrue);
    });

    test('does not treat generic non-overflow Ollama errors as overflow', () {
      final message = errorMessage('500 `model runner crashed unexpectedly`');
      expect(isContextOverflow(message, contextWindow: 32768), isFalse);
    });

    test("does not treat Bedrock throttling 'Too many tokens' as overflow", () {
      final message = errorMessage(
        'Throttling error: Too many tokens, please wait before trying again.',
      );
      expect(isContextOverflow(message, contextWindow: 200000), isFalse);
    });

    test('does not treat Bedrock service unavailable as overflow', () {
      final message = errorMessage(
        'Service unavailable: The service is temporarily unavailable.',
      );
      expect(isContextOverflow(message, contextWindow: 200000), isFalse);
    });

    test('does not treat generic rate limit errors as overflow', () {
      final message = errorMessage(
        'Rate limit exceeded, please retry after 30 seconds.',
      );
      expect(isContextOverflow(message, contextWindow: 200000), isFalse);
    });

    test('does not treat HTTP 429 style errors as overflow', () {
      final message = errorMessage('Too many requests. Please slow down.');
      expect(isContextOverflow(message, contextWindow: 200000), isFalse);
    });

    test('detects Xiaomi-style overflow (length stop, zero output, full)', () {
      final message = lengthStopMessage(58, 1048512, 0);
      expect(isContextOverflow(message, contextWindow: 1048576), isTrue);
    });

    test('does not treat normal length stops with output as overflow', () {
      final message = lengthStopMessage(1000, 0, 4096);
      expect(isContextOverflow(message, contextWindow: 200000), isFalse);
    });

    test('does not treat length stops far below context as overflow', () {
      final message = lengthStopMessage(100, 0, 0);
      expect(isContextOverflow(message, contextWindow: 200000), isFalse);
    });
  });

  group('isContextOverflow — overflow pattern coverage', () {
    final cases = {
      'Anthropic token overflow':
          'prompt is too long: 213462 tokens > 200000 maximum',
      'Anthropic HTTP 413':
          '413 {"error":{"type":"request_too_large","message":"Request '
              'exceeds the maximum size"}}',
      'Amazon Bedrock': 'input is too long for requested model',
      'OpenAI': 'Your input exceeds the context window of this model',
      'LiteLLM (no model prefix)':
          'Requested token count exceeds the maximum context length of '
              '131072 tokens',
      'LiteLLM (with the)':
          "exceeds the model's maximum context length of 65,536 tokens",
      'Google Gemini':
          'The input token count (1196265) exceeds the maximum number of '
              'tokens allowed (1048575)',
      'xAI':
          "This model's maximum prompt length is 131072 but the request "
              'contains 537812 tokens',
      'Groq': 'Please reduce the length of the messages or completion',
      'OpenRouter':
          "This endpoint's maximum context length is 64000 tokens. However, "
              'you requested about 100000 tokens',
      'OpenRouter/Poolside':
          'Input length 131,393 exceeds the maximum allowed input length of '
              '131,040 tokens.',
      'GitHub Copilot': 'prompt token count of 200000 exceeds the limit of '
          '128000',
      'llama.cpp':
          'the request exceeds the available context size, try increasing it',
      'LM Studio':
          'tokens to keep from the initial prompt is greater than the '
              'context length',
      'MiniMax': 'invalid params, context window exceeds limit',
      'Kimi For Coding':
          'Your request exceeded model token limit: 200000 (requested: '
              '300000)',
      'Mistral':
          'Prompt contains 200000 tokens, too large for model with 128000 '
              'maximum context length',
      'z.ai': 'model_context_window_exceeded',
      'Ollama (without max)': 'prompt too long; exceeded context length',
      'Generic context_length_exceeded': 'context_length_exceeded',
      'Generic context length exceeded': 'context length exceeded',
      'Generic too many tokens': 'The request has too many tokens',
      'Generic token limit exceeded': 'token limit exceeded',
      'Cerebras 400': '400 status code (no body)',
      'Cerebras 413': '413 (no body)',
    };

    for (final entry in cases.entries) {
      test('detects ${entry.key}', () {
        expect(
          isContextOverflow(errorMessage(entry.value), contextWindow: 100),
          isTrue,
        );
      });
    }

    test('all patterns are case-insensitive', () {
      expect(isContextOverflow(errorMessage('PROMPT IS TOO LONG')), isTrue);
      expect(
        isContextOverflow(errorMessage('EXCEEDS THE CONTEXT WINDOW')),
        isTrue,
      );
      expect(isContextOverflow(errorMessage('TOKEN LIMIT EXCEEDED')), isTrue);
    });
  });

  group('isContextOverflow — guards and silent overflow', () {
    test('ignores overflow text when stopReason is not error', () {
      final message = errorMessage(
        'prompt is too long: 213462 tokens > 200000 maximum',
      ).copyWith(stopReason: StopReason.stop);
      expect(isContextOverflow(message), isFalse);
    });

    test('returns false for an error without a message', () {
      final message = AssistantMessage(
        content: const [],
        api: 'openai-completions',
        provider: 'openai',
        model: 'gpt-4',
        usage: Usage.zero,
        stopReason: StopReason.error,
        timestamp: DateTime.now(),
      );
      expect(isContextOverflow(message), isFalse);
    });

    test('detects silent overflow (z.ai style) via usage over window', () {
      expect(
        isContextOverflow(stopMessage(900, 200), contextWindow: 1000),
        isTrue,
      );
    });

    test('usage exactly at the window is not silent overflow', () {
      expect(
        isContextOverflow(stopMessage(900, 100), contextWindow: 1000),
        isFalse,
      );
    });

    test('silent overflow requires a context window', () {
      expect(isContextOverflow(stopMessage(900, 200)), isFalse);
    });

    test('silent overflow is not detected on non-stop reasons', () {
      final message = stopMessage(900, 200).copyWith(stopReason: StopReason.toolUse);
      expect(isContextOverflow(message, contextWindow: 1000), isFalse);
    });

    test('length-stop overflow requires a context window', () {
      expect(isContextOverflow(lengthStopMessage(58, 1048512, 0)), isFalse);
    });

    test('length stop at 99% of the window counts as overflow', () {
      // 990 >= 1000 * 0.99
      expect(isContextOverflow(lengthStopMessage(990, 0, 0), contextWindow: 1000), isTrue);
      // 989 < 1000 * 0.99
      expect(isContextOverflow(lengthStopMessage(989, 0, 0), contextWindow: 1000), isFalse);
    });
  });
}
