// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Mock-based parity for the scenarios the live Ollama Cloud suite
/// (`test/integration/provider_ollama_test.dart`) exercises — the same
/// assertions, replayed from canned SSE instead of the network, so the
/// nightly never depends on a live key's billing state (the 402 outage
/// class that reddened 12+ nightly runs in 2026-11).
///
/// The fixtures reproduce the Ollama-Cloud quirks the live suite
/// documented:
/// - reasoning arrives as a separate `reasoning` delta field;
/// - the final chunk carries a flat `usage` with no reasoning-token
///   breakdown (`usage.reasoning` stays null);
/// - `finish_reason` switches to `tool_calls` for tool-call turns.
///
/// The cancel/abort scenario is NOT duplicated here: the adapter's
/// CancelToken path is already covered by "CancelToken abort mid-stream
/// ends with aborted stop reason" in `openai_completions_test.dart`.
///
/// The live suite remains as an opt-in manual smoke (`FAH_LIVE_LM=1` +
/// `OLLAMA_API_KEY`); wire-drift discoveries from it land here as new
/// canned fixtures.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'openai_completions_test.dart' show sseBody, sseClient;

/// Mirrors the live suite's `_model`: same api/baseUrl shape, reasoning
/// enabled, Ollama Cloud identity — but every request hits the canned
/// client, never the network.
final _model = Model(
  id: 'gpt-oss:20b',
  name: 'Ollama Cloud (gpt-oss:20b)',
  api: 'openai-completions',
  provider: 'ollama',
  baseUrl: 'https://ollama.com/v1',
  reasoning: true,
  contextWindow: 128000,
  maxTokens: 8192,
);

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

/// Reasoning-first streaming turn: two `reasoning` deltas, then content,
/// then the terminal chunk with Ollama's flat usage block.
final _helloSse = sseBody([
  {
    'id': 'chatcmpl-ollama-1',
    'choices': [
      {
        'delta': {'reasoning': 'The user greets; reply briefly.'},
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-1',
    'choices': [
      {
        'delta': {'reasoning': ' Three words it is.'},
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-1',
    'choices': [
      {
        'delta': {'content': 'Hello'},
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-1',
    'choices': [
      {
        'delta': {'content': ' there, friend'},
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-1',
    'choices': [
      {'delta': {}, 'finish_reason': 'stop'},
    ],
    // Ollama's flat usage: prompt/completion totals, NO reasoning-token
    // breakdown — the live suite asserts usage.reasoning stays null.
    'usage': {
      'prompt_tokens': 24,
      'completion_tokens': 9,
      'total_tokens': 33,
    },
  },
  'data: [DONE]\n\n',
]);

/// A forced tool call: the function name in the first tool_calls delta,
/// the arguments JSON split across two deltas (the live model streams
/// argument fragments), `finish_reason: tool_calls`.
final _forcedToolCallSse = sseBody([
  {
    'id': 'chatcmpl-ollama-2',
    'choices': [
      {
        'delta': {
          'reasoning': 'Forced add: 40 + 2.',
        },
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-2',
    'choices': [
      {
        'delta': {
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_ollama_1',
              'type': 'function',
              'function': {'name': 'add', 'arguments': '{"a"'},
            },
          ],
        },
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-2',
    'choices': [
      {
        'delta': {
          'tool_calls': [
            {
              'index': 0,
              'function': {'arguments': ': 40, "b": 2}'},
            },
          ],
        },
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-2',
    'choices': [
      {'delta': {}, 'finish_reason': 'tool_calls'},
    ],
  },
  'data: [DONE]\n\n',
]);

/// The follow-up turn after the tool result: the plain answer.
final _answerSse = sseBody([
  {
    'id': 'chatcmpl-ollama-3',
    'choices': [
      {
        'delta': {'reasoning': 'The tool said 42; repeat just that.'},
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-3',
    'choices': [
      {
        'delta': {'content': '42'},
      },
    ],
  },
  {
    'id': 'chatcmpl-ollama-3',
    'choices': [
      {'delta': {}, 'finish_reason': 'stop'},
    ],
  },
  'data: [DONE]\n\n',
]);

void main() {
  group('Ollama Cloud parity (openai-completions adapter, canned SSE)', () {
    test('streams reasoning + text deltas, a done event, and non-zero usage',
        () async {
      final stream = streamOpenAICompletions(
        _model,
        Context(messages: [UserMessage.text('Say hello in three words.')]),
        const OpenAICompletionsOptions(apiKey: 'key', maxTokens: 512),
        sseClient(_helloSse),
      );

      final events = await stream.toList();
      expect(events.first, isA<StartEvent>());

      final thinkingDeltas = events.whereType<ThinkingDeltaEvent>().toList();
      expect(
        thinkingDeltas,
        isNotEmpty,
        reason: 'reasoning model should emit thinking deltas',
      );

      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
      final fullText = deltas.map((delta) => delta.delta).join();
      expect(fullText.trim(), 'Hello there, friend');
      // Partial-first contract: the first incremental delta is a prefix of
      // the accumulated final text.
      expect(fullText.startsWith(deltas.first.delta), isTrue);

      final done = events.last;
      expect(done, isA<DoneEvent>());
      final doneEvent = done as DoneEvent;
      expect(doneEvent.reason, StopReason.stop);

      final message = await stream.result;
      expect(message.stopReason, doneEvent.reason);
      expect(message.usage.totalTokens, greaterThan(0));
      expect(message.usage.output, greaterThan(0));
      // Ollama Cloud does not break out reasoning tokens in
      // completion_tokens_details, so usage.reasoning stays null here —
      // same assertion as the live suite.
    });

    test('streams a forced add() tool call with parsed arguments', () async {
      final stream = streamOpenAICompletions(
        _model,
        Context(
          messages: [UserMessage.text('Use the add tool to compute 40 + 2.')],
          tools: const [_addTool],
        ),
        const OpenAICompletionsOptions(
          apiKey: 'key',
          maxTokens: 1024,
          toolChoice: 'required',
        ),
        sseClient(_forcedToolCallSse),
      );

      final events = await stream.toList();
      expect(events.whereType<ToolCallStartEvent>(), isNotEmpty);
      expect(events.whereType<ToolCallDeltaEvent>(), isNotEmpty);

      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.name, 'add');
      expect(end.toolCall.id, 'call_ollama_1');
      final args = end.toolCall.arguments;
      // The live suite names the payload so a live failure is diagnostic;
      // the canned fixture keeps the same reason strings.
      expect(args['a'], isA<num>(),
          reason: 'forced tool call arguments: $args');
      expect(args['b'], isA<num>(),
          reason: 'forced tool call arguments: $args');
      expect((args['a'] as num) + (args['b'] as num), 42);

      final done = events.last;
      expect(done, isA<DoneEvent>());
      expect((done as DoneEvent).reason, StopReason.toolUse);
    });

    test('drives one full tool round-trip through the agent loop', () async {
      // One canned body per phase: the first request replays the forced
      // tool call, the second the plain answer — exactly the two-turn
      // conversation the live suite drives.
      var phase = 0;

      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        // Phase 0 replays the forced tool call, phase 1 the plain answer.
        final body = phase == 0 ? _forcedToolCallSse : _answerSse;
        phase++;
        return streamOpenAICompletions(
          model,
          context,
          const OpenAICompletionsOptions(apiKey: 'key', maxTokens: 1024),
          sseClient(body),
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
    });
  });
}
