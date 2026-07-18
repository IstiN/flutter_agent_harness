// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Live integration tests for the openai-completions provider adapter against
/// Ollama Cloud (`https://ollama.com/v1`, OpenAI-compatible chat completions
/// with Bearer auth), mirroring `provider_openrouter_test.dart`.
///
/// Model choice: the originally requested `zerocopia/ministral-3:14b-cloud`
/// was retired upstream on 2026-07-15 (the API no longer serves it), and
/// `mistral-large-3:675b` requires a paid subscription the available key does
/// not have. The default is therefore `gpt-oss:20b`, verified working on a
/// free key; set the `OLLAMA_MODEL` environment variable to swap the model
/// without code changes.
///
/// `gpt-oss:20b` is a reasoning model: streamed chunks carry a separate
/// `reasoning` delta field, which the adapter surfaces as
/// [ThinkingStartEvent]/[ThinkingDeltaEvent] thinking blocks. With a small
/// `maxTokens` the reasoning eats the whole budget and `content` comes back
/// EMPTY (finish_reason `length`), so these tests use generous `maxTokens`
/// (512+) and tolerate reasoning-model behavior. Assertions that expect
/// thinking deltas assume the default (or another reasoning) model.
///
/// These tests hit the real Ollama Cloud API and require the
/// `OLLAMA_API_KEY` environment variable; every test skips gracefully when it
/// is unset so keyless CI/dev runs pass. Tagged `integration` and therefore
/// excluded from the pre-commit gate — run manually with:
/// `dart test --tags integration`
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _apiKey = Platform.environment['OLLAMA_API_KEY'];

/// `false` when the key is present (tests run), otherwise the skip reason.
final _skip = (_apiKey?.isEmpty ?? true) ? 'OLLAMA_API_KEY not set' : false;

/// Cloud model known to work on a free Ollama key (see file header for why
/// not ministral-3 / mistral-large-3); overridable via `OLLAMA_MODEL`.
final _model = Model(
  id: Platform.environment['OLLAMA_MODEL'] ?? 'gpt-oss:20b',
  name:
      'Ollama Cloud (${Platform.environment['OLLAMA_MODEL'] ?? 'gpt-oss:20b'})',
  api: 'openai-completions',
  provider: 'ollama',
  baseUrl: 'https://ollama.com/v1',
  reasoning: true,
  contextWindow: 128000,
  maxTokens: 8192,
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
  group('Ollama Cloud (openai-completions adapter, live)', () {
    test(
      'streams reasoning + text deltas, a done event, and non-zero usage',
      () async {
        final stream = streamOpenAICompletions(
          _model,
          Context(messages: [UserMessage.text('Say hello in three words.')]),
          // Generous budget: gpt-oss reasons first, and a small cap leaves no
          // room for the actual content (finish_reason would be `length`).
          OpenAICompletionsOptions(apiKey: _apiKey!, maxTokens: 512),
        );

        final events = await stream.toList();
        expect(events.first, isA<StartEvent>());

        // gpt-oss:20b emits its reasoning in a separate `reasoning` delta
        // field, surfaced by the adapter as thinking blocks.
        final thinkingDeltas = events.whereType<ThinkingDeltaEvent>().toList();
        expect(
          thinkingDeltas,
          isNotEmpty,
          reason: 'reasoning model should emit thinking deltas',
        );

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
        // Ollama Cloud does not break out reasoning tokens in
        // completion_tokens_details, so usage.reasoning stays null here.
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
            maxTokens: 1024,
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
              maxTokens: 1024,
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
          // gpt-oss reasons before it emits content, so cancel on the first
          // delta of either kind — waiting for text could outlast the budget.
          if ((event is TextDeltaEvent || event is ThinkingDeltaEvent) &&
              !source.token.isCancelled) {
            source.cancel(); // abort after the very first delta
          }
        }

        expect(
          events.where((e) => e is TextDeltaEvent || e is ThinkingDeltaEvent),
          isNotEmpty,
        );
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
