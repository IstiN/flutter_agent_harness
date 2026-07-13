import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted turn: stream start, text delta, done.
List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn that ends with tool calls.
List<AssistantMessageEvent> _toolTurn(
  List<ToolCall> calls, {
  StopReason reason = StopReason.toolUse,
}) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: reason);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: reason, message: partial));
  return events;
}

/// Fake [StreamFunction]: replays scripted turns, records every context it
/// was called with.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

class _ToolCallRecord {
  _ToolCallRecord(this.toolCall, this.cancelToken);

  final ToolCall toolCall;
  final CancelToken? cancelToken;
}

ToolCall _call(String id, String name, [Map<String, dynamic>? args]) {
  return ToolCall(id: id, name: name, arguments: args ?? const {});
}

Tool _tool(String name) {
  return Tool(name: name, description: '$name tool', parameters: const {});
}

List<Type> _types(List<AgentEvent> events) {
  return events.map((event) => event.runtimeType).toList();
}

void main() {
  group('agentLoop', () {
    test('single turn without tools emits full lifecycle in order', () async {
      final fake = _FakeStreamFunction([_textTurn('hello')]);
      final prompt = UserMessage.text('hi');
      final stream = agentLoop(
        prompts: [prompt],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final events = await stream.toList();
      expect(_types(events), [
        AgentStartEvent,
        TurnStartEvent,
        MessageStartEvent, // prompt
        MessageEndEvent,
        MessageStartEvent, // assistant partial
        MessageUpdateEvent, // text_start
        MessageUpdateEvent, // text_delta
        MessageEndEvent, // final assistant
        TurnEndEvent,
        AgentEndEvent,
      ]);

      final updates = events.whereType<MessageUpdateEvent>().toList();
      expect(updates.last.message.content, [
        isA<TextContent>().having((c) => c.text, 'text', 'hello'),
      ]);
      expect(updates.last.assistantMessageEvent, isA<TextDeltaEvent>());

      final turnEnd = events.whereType<TurnEndEvent>().single;
      expect(turnEnd.toolResults, isEmpty);
      expect(turnEnd.message.stopReason, StopReason.stop);

      final messages = await stream.result;
      expect(messages, [prompt, isA<AssistantMessage>()]);
    });

    test('prompts and caller context are not mutated', () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final contextMessages = <Message>[UserMessage.text('earlier')];
      await agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: contextMessages),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      ).result;

      expect(contextMessages, hasLength(1));
      // The provider saw the prior context plus the prompt.
      expect(fake.contexts.single.messages.map((m) => m.role), [
        'user',
        'user',
      ]);
    });

    test('multi-turn run executes tool call and accumulates context', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([
          _call('call-1', 'weather', {'city': 'Berlin'}),
        ]),
        _textTurn('It is sunny.'),
      ]);
      final executed = <_ToolCallRecord>[];
      final stream = agentLoop(
        prompts: [UserMessage.text('weather?')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, _) async {
          executed.add(_ToolCallRecord(toolCall, cancelToken));
          return ToolExecutionResult.text('sunny, 22C');
        },
      );

      final events = await stream.toList();
      expect(_types(events), [
        AgentStartEvent,
        TurnStartEvent,
        MessageStartEvent, // prompt
        MessageEndEvent,
        MessageStartEvent, // assistant partial
        MessageUpdateEvent, // toolcall_start
        MessageUpdateEvent, // toolcall_end
        MessageEndEvent, // final assistant (toolUse)
        ToolExecutionStartEvent,
        ToolExecutionEndEvent,
        MessageStartEvent, // tool result
        MessageEndEvent,
        TurnEndEvent,
        TurnStartEvent,
        MessageStartEvent, // second assistant partial
        MessageUpdateEvent,
        MessageUpdateEvent,
        MessageEndEvent,
        TurnEndEvent,
        AgentEndEvent,
      ]);

      expect(executed.single.toolCall.id, 'call-1');
      expect(executed.single.toolCall.arguments, {'city': 'Berlin'});

      final toolEnd = events.whereType<ToolExecutionEndEvent>().single;
      expect(toolEnd.toolName, 'weather');
      expect(toolEnd.isError, isFalse);

      // Second provider call saw prompt + assistant + tool result.
      expect(fake.calls, 2);
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'toolResult',
      ]);
      final toolResult = fake.contexts[1].messages.last as ToolResultMessage;
      expect(toolResult.toolCallId, 'call-1');
      expect(toolResult.content, [
        isA<TextContent>().having((c) => c.text, 'text', 'sunny, 22C'),
      ]);

      final messages = await stream.result;
      expect(messages.map((m) => m.role), [
        'user',
        'assistant',
        'toolResult',
        'assistant',
      ]);
    });

    test(
      'multiple tool calls in one message produce results in source order',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([_call('a', 'alpha'), _call('b', 'beta')]),
          _textTurn('done'),
        ]);
        final stream = agentLoop(
          prompts: [UserMessage.text('go')],
          context: Context(
            messages: [],
            tools: [_tool('alpha'), _tool('beta')],
          ),
          config: const AgentLoopConfig(model: _model),
          streamFunction: fake.call,
          toolExecutor: (toolCall, _, _) async {
            return ToolExecutionResult.text('${toolCall.name} result');
          },
        );

        final events = await stream.toList();
        final ends = events.whereType<ToolExecutionEndEvent>().toList();
        expect(ends.map((e) => e.toolName), ['alpha', 'beta']);

        final results = events
            .whereType<MessageEndEvent>()
            .map((e) => e.message)
            .whereType<ToolResultMessage>()
            .toList();
        expect(results.map((r) => r.toolCallId), ['a', 'b']);

        expect(fake.contexts[1].messages.map((m) => m.role), [
          'user',
          'assistant',
          'toolResult',
          'toolResult',
        ]);
      },
    );

    test('parallel mode: end events in completion order, results in source '
        'order', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('slow-id', 'slow'), _call('fast-id', 'fast')]),
        _textTurn('done'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('go')],
        context: Context(messages: [], tools: [_tool('slow'), _tool('fast')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (toolCall, _, _) async {
          if (toolCall.name == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          return ToolExecutionResult.text('${toolCall.name} done');
        },
      );

      final events = await stream.toList();
      final ends = events.whereType<ToolExecutionEndEvent>().toList();
      expect(ends.map((e) => e.toolName), ['fast', 'slow']);

      final results = events
          .whereType<MessageEndEvent>()
          .map((e) => e.message)
          .whereType<ToolResultMessage>()
          .toList();
      expect(results.map((r) => r.toolName), ['slow', 'fast']);
    });

    test('sequential mode runs one tool at a time', () async {
      final gate = Completer<void>();
      final started = <String>[];
      final fake = _FakeStreamFunction([
        _toolTurn([_call('1', 'first'), _call('2', 'second')]),
        _textTurn('done'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('go')],
        context: Context(
          messages: [],
          tools: [_tool('first'), _tool('second')],
        ),
        config: const AgentLoopConfig(
          model: _model,
          toolExecution: ToolExecutionMode.sequential,
        ),
        streamFunction: fake.call,
        toolExecutor: (toolCall, _, _) async {
          started.add(toolCall.name);
          if (toolCall.name == 'first') await gate.future;
          return ToolExecutionResult.text('ok');
        },
      );

      final events = <AgentEvent>[];
      final subscription = stream.listen(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(started, ['first']); // second has not started yet
      gate.complete();
      await subscription.asFuture<void>();

      expect(started, ['first', 'second']);
      expect(events.whereType<ToolExecutionEndEvent>().map((e) => e.toolName), [
        'first',
        'second',
      ]);
    });

    test('abort mid-stream ends the loop with aborted semantics', () async {
      final source = CancelTokenSource();
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: (model, context, {cancelToken}) {
          final events = AssistantMessageEventStream();
          events.push(StartEvent(partial: _assistant()));
          unawaited(
            cancelToken!.onCancel.then((_) {
              events.push(
                ErrorEvent(
                  reason: StopReason.aborted,
                  error: _assistant(
                    stopReason: StopReason.aborted,
                    errorMessage: 'aborted',
                  ),
                ),
              );
              events.end();
            }),
          );
          return events;
        },
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: source.token,
      );

      final events = <AgentEvent>[];
      final done = stream.listen(events.add).asFuture<void>();
      source.cancel();
      await done;

      expect(events.last, isA<AgentEndEvent>());
      final turnEnd = events.whereType<TurnEndEvent>().single;
      expect(turnEnd.message.stopReason, StopReason.aborted);
      expect(turnEnd.toolResults, isEmpty);

      final messages = await stream.result;
      expect(
        messages.last,
        isA<AssistantMessage>().having(
          (m) => m.stopReason,
          'stopReason',
          StopReason.aborted,
        ),
      );
    });

    test('abort during tool execution: no further provider call', () async {
      final source = CancelTokenSource();
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('unreachable'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('go')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, _) async {
          source.cancel();
          return ToolExecutionResult.text('partial result');
        },
        cancelToken: source.token,
      );

      final events = await stream.toList();
      expect(fake.calls, 1);

      final turnEnds = events.whereType<TurnEndEvent>().toList();
      expect(turnEnds, hasLength(2));
      expect(turnEnds.first.toolResults, hasLength(1));
      expect(turnEnds.last.message.stopReason, StopReason.aborted);

      final messages = await stream.result;
      expect(messages.map((m) => m.role), [
        'user',
        'assistant',
        'toolResult',
        'assistant',
      ]);
      expect(
        (messages.last as AssistantMessage).stopReason,
        StopReason.aborted,
      );
    });

    test('provider error event ends the loop without tool execution', () async {
      final fake = _FakeStreamFunction([
        [
          StartEvent(partial: _assistant()),
          ErrorEvent(
            reason: StopReason.error,
            error: _assistant(
              stopReason: StopReason.error,
              errorMessage: 'HTTP 500',
            ),
          ),
        ],
      ]);
      var toolCalls = 0;
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          toolCalls++;
          return ToolExecutionResult.text('unused');
        },
      );

      final events = await stream.toList();
      expect(toolCalls, 0);
      expect(events.last, isA<AgentEndEvent>());

      final messages = await stream.result;
      expect(messages, hasLength(2));
      final last = messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, 'HTTP 500');
    });

    test('length stop fails tool calls as truncated and continues', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')], reason: StopReason.length),
        _textTurn('retried'),
      ]);
      var toolCalls = 0;
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          toolCalls++;
          return ToolExecutionResult.text('unused');
        },
      );

      final events = await stream.toList();
      expect(toolCalls, 0);

      final end = events.whereType<ToolExecutionEndEvent>().single;
      expect(end.isError, isTrue);
      expect(
        (end.result.content.single as TextContent).text,
        contains('output token limit'),
      );

      // The failed result goes back to the model, which retries next turn.
      expect(fake.calls, 2);
      final toolResult = fake.contexts[1].messages[2] as ToolResultMessage;
      expect(toolResult.isError, isTrue);
      expect(await stream.result, hasLength(4));
    });

    test('unknown tool yields an error result without executing', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'missing')]),
        _textTurn('recovered'),
      ]);
      var toolCalls = 0;
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          toolCalls++;
          return ToolExecutionResult.text('unused');
        },
      );

      final events = await stream.toList();
      expect(toolCalls, 0);
      final end = events.whereType<ToolExecutionEndEvent>().single;
      expect(end.isError, isTrue);
      expect(
        (end.result.content.single as TextContent).text,
        'Tool missing not found',
      );
      expect(fake.calls, 2); // loop continues so the model can recover
    });

    test('executor throw becomes an error tool result', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('handled'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => throw StateError('disk exploded'),
      );

      final events = await stream.toList();
      final end = events.whereType<ToolExecutionEndEvent>().single;
      expect(end.isError, isTrue);
      expect(
        (end.result.content.single as TextContent).text,
        contains('disk exploded'),
      );
      final toolResult = events
          .whereType<MessageEndEvent>()
          .map((e) => e.message)
          .whereType<ToolResultMessage>()
          .single;
      expect(toolResult.isError, isTrue);
    });

    test(
      'partial tool updates are relayed; post-settle updates are dropped',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([_call('call-1', 'weather')]),
          _textTurn('done'),
        ]);
        final stream = agentLoop(
          prompts: [UserMessage.text('hi')],
          context: Context(messages: [], tools: [_tool('weather')]),
          config: const AgentLoopConfig(model: _model),
          streamFunction: fake.call,
          toolExecutor: (toolCall, _, onUpdate) async {
            onUpdate?.call(ToolExecutionResult.text('halfway'));
            // Scheduled after the executor future settles: must be ignored.
            unawaited(
              Future<void>(
                () => onUpdate?.call(ToolExecutionResult.text('late')),
              ),
            );
            return ToolExecutionResult.text('final');
          },
        );

        final events = await stream.toList();
        await Future<void>.delayed(Duration.zero); // let the late update fire

        final updates = events.whereType<ToolExecutionUpdateEvent>().toList();
        expect(updates, hasLength(1));
        expect(updates.single.toolCallId, 'call-1');
        expect(
          (updates.single.partialResult.content.single as TextContent).text,
          'halfway',
        );
      },
    );

    test('terminate hint stops the loop after the tool batch', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('unreachable'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          return ToolExecutionResult.text('final answer', terminate: true);
        },
      );

      final events = await stream.toList();
      expect(fake.calls, 1);
      expect(events.last, isA<AgentEndEvent>());
      final messages = await stream.result;
      expect(messages.map((m) => m.role), ['user', 'assistant', 'toolResult']);
    });

    test(
      'stream function throwing becomes an error turn, not a crash',
      () async {
        final stream = agentLoop(
          prompts: [UserMessage.text('hi')],
          context: const Context(messages: []),
          config: const AgentLoopConfig(model: _model),
          streamFunction: (model, context, {cancelToken}) {
            throw StateError('no api key');
          },
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        );

        final events = await stream.toList();
        expect(events.last, isA<AgentEndEvent>());
        final last = (await stream.result).last as AssistantMessage;
        expect(last.stopReason, StopReason.error);
        expect(last.errorMessage, contains('no api key'));
      },
    );
  });

  group('agentLoopContinue', () {
    test('rejects an empty context', () {
      expect(
        () => agentLoopContinue(
          context: const Context(messages: []),
          config: const AgentLoopConfig(model: _model),
          streamFunction: _FakeStreamFunction([_textTurn('x')]).call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a context ending with an assistant message', () {
      expect(
        () => agentLoopContinue(
          context: Context(messages: [_assistant()]),
          config: const AgentLoopConfig(model: _model),
          streamFunction: _FakeStreamFunction([_textTurn('x')]).call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('continues from a tool-result message without new prompts', () async {
      final prior = [
        UserMessage.text('weather?'),
        _assistant(
          content: [_call('call-1', 'weather')],
          stopReason: StopReason.toolUse,
        ),
        ToolResultMessage(
          toolCallId: 'call-1',
          toolName: 'weather',
          content: [const TextContent(text: 'sunny')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      ];
      final fake = _FakeStreamFunction([_textTurn('It is sunny.')]);
      final stream = agentLoopContinue(
        context: Context(messages: prior, tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final events = await stream.toList();
      expect(_types(events), [
        AgentStartEvent,
        TurnStartEvent,
        MessageStartEvent,
        MessageUpdateEvent,
        MessageUpdateEvent,
        MessageEndEvent,
        TurnEndEvent,
        AgentEndEvent,
      ]);

      // The provider saw the full prior context.
      expect(fake.contexts.single.messages, hasLength(3));

      // Result contains only messages produced by this run.
      final messages = await stream.result;
      expect(messages.single, isA<AssistantMessage>());
    });
  });
}
