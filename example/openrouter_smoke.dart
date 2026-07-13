/// Manual smoke test for the openai-completions adapter against OpenRouter
/// (GOAL.md Phase 0). Not run by `dart test` — it needs a real API key and
/// network access.
///
/// Usage:
///
/// ```sh
/// dart --dart-define=OPENROUTER_API_KEY=sk-or-... run example/openrouter_smoke.dart
/// ```
///
/// Optional: `--dart-define=OPENROUTER_MODEL=openai/gpt-4o-mini` to pick a
/// different model (default: anthropic/claude-sonnet-4).
///
/// The example streams a short answer, printing text deltas as they arrive,
/// then asks for a tool call to demonstrate tool-call streaming, and prints
/// the final usage/cost accounting. Abort is demonstrated by cancelling the
/// first request's token mid-stream when it takes too long.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

const apiKey = String.fromEnvironment('OPENROUTER_API_KEY');
const modelId = String.fromEnvironment(
  'OPENROUTER_MODEL',
  defaultValue: 'anthropic/claude-sonnet-4',
);

final openRouter = Model(
  id: modelId,
  name: modelId,
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  reasoning: true,
  contextWindow: 200000,
  maxTokens: 8192,
);

Future<void> main() async {
  if (apiKey.isEmpty) {
    print(
      'Set OPENROUTER_API_KEY via --dart-define; see the comment at the top '
      'of this file.',
    );
    return;
  }

  // 1. Plain text streaming.
  print('--- text streaming ---');
  final textStream = streamOpenAICompletions(
    openRouter,
    Context(messages: [UserMessage.text('Say hello in three words.')]),
    const OpenAICompletionsOptions(apiKey: apiKey, maxTokens: 64),
  );
  await for (final event in textStream) {
    if (event is TextDeltaEvent) {
      print(event.delta);
    }
  }
  final textMessage = await textStream.result;
  print('\nstopReason: ${textMessage.stopReason}');
  print(
    'usage: ${textMessage.usage.totalTokens} tokens, '
    '\$${textMessage.usage.cost.total}',
  );

  // 2. Tool-call streaming.
  print('\n--- tool-call streaming ---');
  final toolStream = streamOpenAICompletions(
    openRouter,
    Context(
      messages: [UserMessage.text('What is the weather in Paris?')],
      tools: const [
        Tool(
          name: 'get_weather',
          description: 'Get the current weather for a location.',
          parameters: {
            'type': 'object',
            'properties': {
              'location': {'type': 'string'},
            },
            'required': ['location'],
          },
        ),
      ],
    ),
    const OpenAICompletionsOptions(apiKey: apiKey, maxTokens: 256),
  );
  await for (final event in toolStream) {
    if (event is ToolCallDeltaEvent) {
      print(event.delta);
    }
  }
  final toolMessage = await toolStream.result;
  print('\nstopReason: ${toolMessage.stopReason}');
  for (final block in toolMessage.content) {
    if (block is ToolCall) {
      print('tool call: ${block.name}(${block.arguments})');
    }
  }

  // 3. CancelToken abort mid-stream.
  print('\n--- cancel mid-stream ---');
  final source = CancelTokenSource();
  final abortStream = streamOpenAICompletions(
    openRouter,
    Context(messages: [UserMessage.text('Count from 1 to 1000.')]),
    OpenAICompletionsOptions(
      apiKey: apiKey,
      maxTokens: 2048,
      cancelToken: source.token,
    ),
  );
  await for (final event in abortStream) {
    if (event is TextDeltaEvent) {
      print(event.delta);
      source.cancel(); // abort after the very first delta
    }
  }
  final aborted = await abortStream.result;
  print(
    '\nstopReason: ${aborted.stopReason} '
    '(${aborted.errorMessage ?? 'no error'})',
  );
}
