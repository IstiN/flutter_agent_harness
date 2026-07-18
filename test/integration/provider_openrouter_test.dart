// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Live integration tests for the openai-completions provider adapter against
/// OpenRouter (reached via a `baseUrl` swap, see
/// `example/openrouter_smoke.dart`).
///
/// These tests hit the real OpenRouter API and require the
/// `OPENROUTER_API_KEY` environment variable; every test skips gracefully
/// when it is unset so keyless CI/dev runs pass. Prompts are kept tiny and
/// `maxTokens` small to bound cost. Tagged `integration` and therefore
/// excluded from the pre-commit gate — run manually with:
/// `dart test --tags integration`
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _apiKey = Platform.environment['OPENROUTER_API_KEY'];

/// `false` when the key is present (tests run), otherwise the skip reason.
final _skip = (_apiKey?.isEmpty ?? true) ? 'OPENROUTER_API_KEY not set' : false;

/// Cheap chat model known to work via OpenRouter (the `OPENROUTER_MODEL`
/// alternative documented in `example/openrouter_smoke.dart`).
const _model = Model(
  id: 'openai/gpt-4o-mini',
  name: 'GPT-4o mini (via OpenRouter)',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  contextWindow: 128000,
  maxTokens: 16384,
);

/// Trivial tool used to exercise tool-call streaming against the live API.
const _addTool = Tool(
  name: 'add',
  description: 'Add two numbers and return their sum.',
  parameters: {
    'type': 'object',
    'properties': {
      'a': {'type': 'number', 'description': 'First addend.'},
      'b': {'type': 'number', 'description': 'Second addend.'},
    },
    'required': ['a', 'b'],
    'additionalProperties': false,
  },
);

void main() {
  group('OpenRouter (openai-completions adapter, live)', () {
    test(
      'streams incremental text deltas, a done event, and non-zero usage',
      () async {
        final stream = streamOpenAICompletions(
          _model,
          Context(messages: [UserMessage.text('Say hello in three words.')]),
          OpenAICompletionsOptions(apiKey: _apiKey!, maxTokens: 64),
        );

        final events = await stream.toList();
        expect(events.first, isA<StartEvent>());

        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
        final fullText = deltas.map((delta) => delta.delta).join();
        expect(fullText.trim(), isNotEmpty);
        // Partial-first contract: the first incremental delta is a prefix of
        // the accumulated final text.
        expect(fullText.startsWith(deltas.first.delta), isTrue);

        final done = events.last;
        expect(done, isA<DoneEvent>());
        final doneEvent = done as DoneEvent;
        expect(doneEvent.reason, isNot(StopReason.error));
        expect(doneEvent.reason, StopReason.stop);

        final message = await stream.result;
        expect(message.stopReason, doneEvent.reason);
        expect(message.usage.totalTokens, greaterThan(0));
        expect(message.usage.output, greaterThan(0));
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'streams a forced add() tool call with parsed arguments',
      () async {
        final stream = streamOpenAICompletions(
          _model,
          Context(
            messages: [UserMessage.text('Use the add tool to compute 40 + 2.')],
            tools: const [_addTool],
          ),
          OpenAICompletionsOptions(
            apiKey: _apiKey!,
            maxTokens: 256,
            toolChoice: 'required',
          ),
        );

        final events = await stream.toList();
        expect(events.whereType<ToolCallStartEvent>(), isNotEmpty);
        expect(events.whereType<ToolCallDeltaEvent>(), isNotEmpty);

        final end = events.whereType<ToolCallEndEvent>().single;
        expect(end.toolCall.name, 'add');
        expect(end.toolCall.id, isNotEmpty);
        final args = end.toolCall.arguments;
        expect((args['a'] as num) + (args['b'] as num), 42);

        final done = events.last;
        expect(done, isA<DoneEvent>());
        expect((done as DoneEvent).reason, StopReason.toolUse);
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'drives one full tool round-trip through the agent loop',
      () async {
        AssistantMessageEventStream streamFunction(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          return streamOpenAICompletions(
            model,
            context,
            OpenAICompletionsOptions(
              apiKey: _apiKey!,
              maxTokens: 512,
              cancelToken: cancelToken,
            ),
          );
        }

        var executorCalls = 0;
        final agent = Agent(
          model: _model,
          systemPrompt:
              'You are a calculator. Always use the add tool for '
              'arithmetic, then answer with just the resulting number.',
          tools: const [_addTool],
          streamFunction: streamFunction,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            executorCalls++;
            expect(toolCall.name, 'add');
            final args = toolCall.arguments;
            final sum = (args['a'] as num) + (args['b'] as num);
            return ToolExecutionResult.text('$sum');
          },
        );

        await agent.prompt('What is 40 + 2?');
        await agent.waitForIdle();

        expect(agent.state.errorMessage, isNull);
        expect(executorCalls, 1);

        final messages = agent.state.messages;
        final toolResults = messages.whereType<ToolResultMessage>().toList();
        expect(toolResults, hasLength(1));
        final resultText = toolResults.single.content
            .whereType<TextContent>()
            .map((content) => content.text)
            .join();
        expect(resultText, contains('42'));

        final last = messages.last;
        expect(last, isA<AssistantMessage>());
        final lastAssistant = last as AssistantMessage;
        expect(lastAssistant.stopReason, StopReason.stop);
        final answer = lastAssistant.content
            .whereType<TextContent>()
            .map((content) => content.text)
            .join();
        expect(answer, contains('42'));
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'CancelToken abort mid-stream ends with aborted stop reason',
      () async {
        final source = CancelTokenSource();
        final stream = streamOpenAICompletions(
          _model,
          Context(
            messages: [
              UserMessage.text('Count from 1 to 1000, one number per line.'),
            ],
          ),
          OpenAICompletionsOptions(
            apiKey: _apiKey!,
            maxTokens: 2048,
            cancelToken: source.token,
          ),
        );

        final events = <AssistantMessageEvent>[];
        await for (final event in stream) {
          events.add(event);
          if (event is TextDeltaEvent && !source.token.isCancelled) {
            source.cancel(); // abort after the very first delta
          }
        }

        expect(events.whereType<TextDeltaEvent>(), isNotEmpty);
        final terminal = events.last;
        expect(terminal, isA<ErrorEvent>());
        expect((terminal as ErrorEvent).reason, StopReason.aborted);
        final message = await stream.result;
        expect(message.stopReason, StopReason.aborted);
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
