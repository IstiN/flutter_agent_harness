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

/// An exception with a clean toString: the error-result path must leave it be.
class _CleanError implements Exception {
  const _CleanError(this.message);

  final String message;

  @override
  String toString() => message;
}

List<Type> _types(List<AgentEvent> events) {
  return events.map((event) => event.runtimeType).toList();
}

void main() {
  group('agentLoop', () {
    test('an over-window outgoing context ends the run without a provider '
        'call', () async {
      final tinyWindow = const Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 100,
        maxTokens: 4096,
      );
      final fake = _FakeStreamFunction([_textTurn('never')]);
      final prompt = UserMessage.text('x' * 800);
      final stream = agentLoop(
        prompts: [prompt],
        context: const Context(messages: []),
        config: AgentLoopConfig(model: tinyWindow),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final messages = await stream.result as List<dynamic>;
      expect(fake.calls, 0);
      final assistant = messages.whereType<AssistantMessage>().single;
      expect(assistant.stopReason, StopReason.error);
      expect(assistant.errorMessage, contains('Context window'));
      // Hosts recognize the guard (to auto-compact + continue the turn)
      // via the shared marker, not by parsing numbers out of the text.
      expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
      expect(isContextWindowExhaustedError(assistant.errorMessage), isTrue);
      expect(isContextWindowExhaustedError('provider exploded'), isFalse);
      expect(isContextWindowExhaustedError(null), isFalse);
    });
    test('the over-window guard trips at the capped window, not the model '
        'window (issue #273)', () async {
      // A huge-window model run under a tiny owner cap: the guard must
      // measure against [effectiveContextWindow] — the cap — so the run
      // stops BEFORE the request that would blow the owner's budget.
      final bigWindowModel = const Model(
        id: 'big-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      final fake = _FakeStreamFunction([_textTurn('never')]);
      final prompt = UserMessage.text('x' * 800);
      final stream = agentLoop(
        prompts: [prompt],
        context: const Context(messages: []),
        config: AgentLoopConfig(model: bigWindowModel, contextWindowCap: 100),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final messages = await stream.result as List<dynamic>;
      expect(fake.calls, 0);
      final assistant = messages.whereType<AssistantMessage>().single;
      expect(assistant.stopReason, StopReason.error);
      expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
      expect(assistant.errorMessage, contains('effective window is 100'));
    });
    test('IT-W2 (#729): a cap above the catalog window raises the guard '
        'basis — an over-catalog branch keeps flowing', () async {
      // The repro: a 200k-catalog model whose endpoint serves ~1M. With
      // the owner override raised to 1M, a 347k branch (the #729 resume)
      // no longer trips the guard at the catalog value.
      final catalog200k = const Model(
        id: 'glm-catalog',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 200000,
        maxTokens: 4096,
      );
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final prompt = UserMessage.text('x' * 800);
      final stream = agentLoop(
        prompts: [prompt],
        context: const Context(messages: []),
        config: AgentLoopConfig(model: catalog200k, contextWindowCap: 1000000),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final messages = await stream.result as List<dynamic>;
      // The provider was actually called: no false over-window stop.
      expect(fake.calls, 1);
      final assistant = messages.whereType<AssistantMessage>().single;
      expect(assistant.stopReason, isNot(StopReason.error));
      expect(
        assistant.errorMessage,
        isNull,
        reason: 'the raised cap must keep the over-catalog branch flowing',
      );
    });
    test('the over-window guard counts the system prompt and tool schemas '
        'when no usage anchor covers them', () async {
      final tinyWindow = const Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 100,
        maxTokens: 4096,
      );
      final fake = _FakeStreamFunction([_textTurn('never')]);
      // 10 estimated transcript tokens — far under the window on its own…
      final prompt = UserMessage.text('x' * 40);
      // …but the wire request also carries a ~200-token system prompt plus
      // the tool schema, which a transcript-only estimate drops (the
      // resumed-session bug: the meter read 64% while the request was
      // already over the window).
      final stream = agentLoop(
        prompts: [prompt],
        context: Context(
          systemPrompt: 's' * 800,
          messages: const [],
          tools: [
            Tool(name: 'read', description: 'd' * 40, parameters: const {}),
          ],
        ),
        config: AgentLoopConfig(model: tinyWindow),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final messages = await stream.result as List<dynamic>;
      expect(fake.calls, 0);
      final assistant = messages.whereType<AssistantMessage>().single;
      expect(assistant.stopReason, StopReason.error);
      expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
    });
    test('the over-window guard does not double-count the system prompt '
        'when provider usage anchors the estimate', () async {
      final tinyWindow = const Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 100,
        maxTokens: 4096,
      );
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      // A 50-token anchor: the provider's reported total already includes
      // the system prompt and tool schemas of that request. Adding the
      // overhead again would push 50 + ~200 over the 100-token window and
      // trip the guard on a request that fits.
      final anchor = AssistantMessage(
        content: [TextContent(text: 'hi')],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero.copyWith(input: 40, output: 10, totalTokens: 50),
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      final stream = agentLoop(
        prompts: [UserMessage.text('x' * 40)],
        context: Context(systemPrompt: 's' * 800, messages: [anchor]),
        config: AgentLoopConfig(model: tinyWindow),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      await stream.result;
      expect(fake.calls, 1);
    });
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
        ModelRequestEvent, // outbound request summary
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
        ModelRequestEvent,
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
        ModelRequestEvent, // second request
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
      // gh-1393 AC9: structured, never a bare leaked exception string.
      expect(
        (end.result.content.single as TextContent).text,
        startsWith('Tool error (weather): disk exploded\n'),
      );
      final toolResult = events
          .whereType<MessageEndEvent>()
          .map((e) => e.message)
          .whereType<ToolResultMessage>()
          .single;
      expect(toolResult.isError, isTrue);
    });

    test(
      'core exception prefixes are stripped from error tool results',
      () async {
        Future<String> textOf(Object Function() makeError) async {
          final fake = _FakeStreamFunction([
            _toolTurn([_call('call-1', 'weather')]),
            _textTurn('handled'),
          ]);
          final stream = agentLoop(
            prompts: [UserMessage.text('hi')],
            context: Context(messages: [], tools: [_tool('weather')]),
            config: const AgentLoopConfig(model: _model),
            streamFunction: fake.call,
            toolExecutor: (_, _, _) async => throw makeError(),
          );
          final events = await stream.toList();
          return (events
                      .whereType<ToolExecutionEndEvent>()
                      .single
                      .result
                      .content
                      .single
                  as TextContent)
              .text;
        }

        // StateError is the bash tool's non-zero-exit carrier (issue #118).
        // The stripped message rides INSIDE the structured wrapper
        // (gh-1393 AC9) — `startsWith` asserts the wrapper, the message
        // body keeps its exact shape. A routine non-zero exit is a REAL
        // command failure, so the uncaught-harness-exception hint must
        // NOT ride along (gh-1393 rework: the hint is reserved for errors
        // that are not the harness's own operational carriers).
        expect(
          await textOf(
            () => StateError('total 12\nCommand exited with code 2'),
          ),
          'Tool error (weather): total 12\nCommand exited with code 2',
        );
        expect(
          await textOf(() => StateError('partial output\nCommand aborted')),
          'Tool error (weather): partial output\nCommand aborted',
        );
        // A genuinely uncaught exception keeps the hint.
        final genericState = await textOf(() => StateError('disk exploded'));
        expect(genericState, startsWith('Tool error (weather): disk exploded'));
        expect(genericState, contains('uncaught exception'));
        expect(
          await textOf(() => ArgumentError('args must be a map')),
          startsWith('Tool error (weather): args must be a map\n'),
        );
        expect(
          await textOf(() => const FormatException('unexpected character')),
          startsWith('Tool error (weather): unexpected character\n'),
        );
      },
    );

    test(
      'operational carriers never carry the uncaught-exception hint',
      () async {
        Future<String> textOf(Object Function() makeError) async {
          final fake = _FakeStreamFunction([
            _toolTurn([_call('call-1', 'weather')]),
            _textTurn('handled'),
          ]);
          final stream = agentLoop(
            prompts: [UserMessage.text('hi')],
            context: Context(messages: [], tools: [_tool('weather')]),
            config: const AgentLoopConfig(model: _model),
            streamFunction: fake.call,
            toolExecutor: (_, _, _) async => throw makeError(),
          );
          final events = await stream.toList();
          return (events
                      .whereType<ToolExecutionEndEvent>()
                      .single
                      .result
                      .content
                      .single
                  as TextContent)
              .text;
        }

        // ToolValidationException / ToolNotFoundException rejections are
        // the registry's own operational shape errors — the model must
        // hear "your arguments are wrong", not "the tool may be
        // unavailable; skip it" (gh-1393 rework).
        final validation = await textOf(
          () => const ToolValidationException('weather', 'args must be a map'),
        );
        expect(validation, startsWith('Tool error (weather): '));
        expect(validation, contains('args must be a map'));
        expect(validation, isNot(contains('uncaught exception')));

        final notFound = await textOf(() => ToolNotFoundException('weather'));
        expect(notFound, startsWith('Tool error (weather): '));
        expect(notFound, isNot(contains('uncaught exception')));

        // gh-1444 AC5: a shell timeout is the command's verdict — the
        // honest "timed out after Ns" carrier (partial output + status
        // line) must never wear the "uncaught exception" hint.
        final timeout = await textOf(
          () => StateError(
            '--- partial stdout ---\nsome lines\n\nCommand timed out '
            'after 30 seconds',
          ),
        );
        expect(timeout, contains('Command timed out after 30 seconds'));
        expect(timeout, isNot(contains('uncaught exception')));
      },
    );

    test('nested core exception prefixes are stripped recursively', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('handled'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('weather')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async =>
            throw ArgumentError(StateError('boom')),
      );

      final events = await stream.toList();
      final end = events.whereType<ToolExecutionEndEvent>().single;
      // "Invalid argument(s): Bad state: boom" — both prefixes go, and the
      // result is STRUCTURED (gh-1393 AC9): tool name + stripped message +
      // the uncaught-exception hint, never a bare leaked exception string.
      expect(
        (end.result.content.single as TextContent).text,
        startsWith('Tool error (weather): boom\n'),
      );
      expect(
        (end.result.content.single as TextContent).text,
        contains('uncaught exception'),
      );
    });

    test(
      'an empty error message still renders the structured wrapper',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([_call('call-1', 'weather')]),
          _textTurn('handled'),
        ]);
        final stream = agentLoop(
          prompts: [UserMessage.text('hi')],
          context: Context(messages: [], tools: [_tool('weather')]),
          config: const AgentLoopConfig(model: _model),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => throw StateError(''),
        );

        final events = await stream.toList();
        final end = events.whereType<ToolExecutionEndEvent>().single;
        expect(end.isError, isTrue);
        final text = (end.result.content.single as TextContent).text;
        expect(text, startsWith('Tool error (weather): <no error message>'));
      },
    );

    test('errors with clean toString are wrapped, not leaked bare', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'memory_search')]),
        _textTurn('handled'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: Context(messages: [], tools: [_tool('memory_search')]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async =>
            throw const _CleanError('rewind blocked'),
      );

      final events = await stream.toList();
      final end = events.whereType<ToolExecutionEndEvent>().single;
      // gh-1393 AC9: the clean message survives verbatim inside the
      // structured wrapper (name + hint) — the memory_search iOS crash
      // shape (`Isolate.resolvePackageUriSync …`) can never reach the
      // model as a bare exception string again.
      final text = (end.result.content.single as TextContent).text;
      expect(text, startsWith('Tool error (memory_search): rewind blocked'));
      expect(text, contains('not a command failure'));
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

  group('steering cap', () {
    test('run settles after maxSteeringTurns extensions; over-cap batches '
        'wait for the next run', () async {
      const maxSteeringTurns = 3;
      const offeredBatches = maxSteeringTurns + 5;
      final queue = [
        for (var i = 0; i < offeredBatches; i++) UserMessage.text('steer-$i'),
      ];
      var steeringPolls = 0;
      // Always returns a turn: without the cap the loop would chase every
      // queued batch (and never stop for an endless source).
      final fake = _FakeStreamFunction([
        for (var i = 0; i < offeredBatches; i++) _textTurn('reply-$i'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: () async {
            steeringPolls++;
            return queue.isEmpty ? const <Message>[] : [queue.removeAt(0)];
          },
          maxSteeringTurns: maxSteeringTurns,
        ),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final messages = await stream.result;
      // Exactly maxSteeringTurns batches were consumed — one model turn per
      // batch, i.e. the loop-internal steeringExtensions counter incremented
      // exactly maxSteeringTurns times before the run settled.
      expect(fake.calls, maxSteeringTurns);
      expect(
        messages.whereType<UserMessage>().map((m) => m.content as String),
        ['hi', 'steer-0', 'steer-1', 'steer-2'],
      );
      // The loop polls one initial + maxSteeringTurns extension times; the
      // last poll is short-circuited by the cap before reaching the source,
      // so the source itself was hit exactly maxSteeringTurns times — NOT
      // once per queued batch.
      expect(steeringPolls, maxSteeringTurns);
      // The over-cap batches were never consumed: they stay queued.
      expect(queue, hasLength(offeredBatches - maxSteeringTurns));

      // The next run's poll picks the queued batches up under its own cap.
      final nextFake = _FakeStreamFunction([
        for (var i = 0; i < offeredBatches; i++) _textTurn('next-$i'),
      ]);
      final next = await agentLoop(
        prompts: [UserMessage.text('again')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: () async =>
              queue.isEmpty ? const <Message>[] : [queue.removeAt(0)],
          maxSteeringTurns: maxSteeringTurns,
        ),
        streamFunction: nextFake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      ).result;
      expect(nextFake.calls, maxSteeringTurns);
      expect(next.whereType<UserMessage>().map((m) => m.content as String), [
        'again',
        'steer-3',
        'steer-4',
        'steer-5',
      ]);
      expect(queue, hasLength(2));
    });
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
        ModelRequestEvent,
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

  group('tool pairing integrity (issue #85)', () {
    ToolResultMessage result(String id, String name) => ToolResultMessage(
      toolCallId: id,
      toolName: name,
      content: [TextContent(text: 'ok')],
      isError: false,
      timestamp: DateTime.utc(2026),
    );

    /// AC3 (deep review PR #93): EACH gateway signature family must drive
    /// exactly one repair-and-retry through a scripted failing stream —
    /// matcher-level pinning alone is not enough.
    const pairingWedges = <String, String>{
      'anthropic':
          'messages.0.content.1: unexpected tool_use_id found in tool_result '
          'blocks: bash_198. Each tool_result block must have a corresponding '
          'tool_use block in the previous message',
      'litellm':
          'litellm.badrequest: Invalid request: expected toolresult '
          'blocks, but the previous message contains none',
      'openai':
          'Invalid parameter: tool_call_id is not found: bash_198. '
          'Every tool message must follow a tool_calls message',
      'google':
          '400 Bad Request: Please ensure that the number of function '
          'response parts is equal to the number of function call parts of '
          'the function call turn.',
      'openai-unanswered':
          "An assistant message with 'tool_calls' must be "
          "followed by tool messages responding to each 'tool_call_id'. "
          "The following tool_call_ids did not have response messages: "
          'bash_198',
    };

    AssistantMessage errorTurn(String message) =>
        _assistant(stopReason: StopReason.error, errorMessage: message);

    test('a wedged context is repaired pre-request without a provider call '
        'knowing (UT-repair through the loop)', () async {
      // Production shape: compaction left a summary + an orphaned result.
      final wedgeContext = Context(
        messages: [
          UserMessage.text('summary of earlier work'),
          result('bash_198', 'bash'),
        ],
      );
      final inputJson = wedgeContext.messages.map((m) => m.toJson()).toList();
      final fake = _FakeStreamFunction([_textTurn('recovered')]);
      final stream = agentLoop(
        prompts: const [],
        context: wedgeContext,
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final events = await stream.toList();
      expect((await stream.result as List).last.stopReason, StopReason.stop);
      expect(fake.calls, 1);
      // The provider NEVER saw the orphan.
      expect(
        fake.contexts.single.messages.whereType<ToolResultMessage>(),
        isEmpty,
      );
      expect(fake.contexts.single.messages.first, isA<UserMessage>());
      // The repair is surfaced as an event with the audit trail.
      final repairEvents = events.whereType<ToolPairingRepairEvent>().toList();
      expect(repairEvents, hasLength(1));
      expect(repairEvents.single.providerError, isNull);
      expect(repairEvents.single.report.droppedResultIds, ['bash_198']);
      // The transcript itself is never modified.
      expect(wedgeContext.messages.map((m) => m.toJson()).toList(), inputJson);
    });

    pairingWedges.forEach((gateway, wedge) {
      test('a $gateway pairing 400 triggers exactly one self-healing repair '
          'and retry', () async {
        final wedgeContext = Context(
          messages: [
            UserMessage.text('summary of earlier work'),
            result('bash_198', 'bash'),
          ],
        );
        final fake = _FakeStreamFunction([
          [DoneEvent(reason: StopReason.error, message: errorTurn(wedge))],
          _textTurn('recovered'),
        ]);
        final stream = agentLoop(
          prompts: const [],
          context: wedgeContext,
          config: const AgentLoopConfig(model: _model),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        );

        final events = await stream.toList();
        final messages = await stream.result as List;
        expect((messages.last as AssistantMessage).stopReason, StopReason.stop);
        expect(fake.calls, 2);
        final repairEvents = events
            .whereType<ToolPairingRepairEvent>()
            .toList();
        // The detection event carries the raw provider error; the repair
        // itself is surfaced separately.
        expect(
          repairEvents.any((event) => event.providerError == wedge),
          isTrue,
        );
        expect(
          repairEvents
              .where((event) => event.providerError == null)
              .where((event) => event.report.isNotEmpty),
          isNotEmpty,
        );
        // The retry's context is wire-valid.
        expect(validateToolPairing(fake.contexts[1].messages), isEmpty);
      });
    });

    test(
      'unrelated provider errors do not trigger the pairing retry',
      () async {
        final fake = _FakeStreamFunction([
          [
            DoneEvent(
              reason: StopReason.error,
              message: errorTurn('rate limit exceeded'),
            ),
          ],
        ]);
        final stream = agentLoop(
          prompts: [UserMessage.text('hi')],
          context: const Context(messages: []),
          config: const AgentLoopConfig(model: _model),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        );

        await stream.toList();
        expect(fake.calls, 1);
      },
    );

    test('per-run position-counter ids stay unique across runs sharing a '
        'context (UT-ids)', () async {
      final first = _FakeStreamFunction([
        _toolTurn([_call('bash_198', 'bash')]),
        _textTurn('done one'),
      ]);
      final history1 =
          (await agentLoop(
                prompts: [UserMessage.text('hi')],
                context: const Context(messages: []),
                config: const AgentLoopConfig(model: _model),
                streamFunction: first.call,
                toolExecutor: (_, _, _) async => ToolExecutionResult.text('r1'),
              ).result)
              as List;

      // A shared context that ALREADY holds `bash_198_2` (plus the fresh
      // text+call mixed message shape) forces the stamper down its whole
      // rename chain: bash_198 → _2 (taken) → _3.
      final seeded = <Message>[
        _assistant(
          content: [
            TextContent(text: 'earlier'),
            _call('bash_198_2', 'bash'),
          ],
          stopReason: StopReason.toolUse,
        ),
        result('bash_198_2', 'bash'),
        ...history1.cast<Message>(),
      ];
      final mixedCallTurn = [
        StartEvent(partial: _assistant()),
        ToolCallStartEvent(contentIndex: 0, partial: _assistant()),
        ToolCallEndEvent(
          contentIndex: 0,
          toolCall: _call('bash_198', 'bash'),
          partial: _assistant(
            content: [
              TextContent(text: 'working'),
              _call('bash_198', 'bash'),
            ],
            stopReason: StopReason.toolUse,
          ),
        ),
        DoneEvent(
          reason: StopReason.toolUse,
          message: _assistant(
            content: [
              TextContent(text: 'working'),
              _call('bash_198', 'bash'),
            ],
            stopReason: StopReason.toolUse,
          ),
        ),
      ];
      final second = _FakeStreamFunction([
        mixedCallTurn,
        _textTurn('done two'),
      ]);
      final history2 =
          (await agentLoop(
                prompts: [UserMessage.text('again')],
                context: Context(messages: seeded),
                config: const AgentLoopConfig(model: _model),
                streamFunction: second.call,
                toolExecutor: (_, _, _) async => ToolExecutionResult.text('r2'),
              ).result)
              as List;

      List<String> callIds(List<Message> messages) => [
        for (final m in messages)
          if (m is AssistantMessage)
            for (final block in m.content)
              if (block is ToolCall) block.id,
      ];
      final ids1 = callIds(history1.cast<Message>());
      final ids2 = callIds(history2.cast<Message>());
      expect(ids1, ['bash_198']);
      // The seeded bash_198_2 forces the fresh bash_198 to _3; the run's
      // own result carries the renamed id (call/result stay paired).
      expect(ids2, ['bash_198_3']);
      expect(ids1.toSet().intersection(ids2.toSet()), isEmpty);
      // Results follow their (renamed) calls.
      final resultIds2 = [
        for (final m in history2.cast<Message>())
          if (m is ToolResultMessage) m.toolCallId,
      ];
      expect(resultIds2, contains('bash_198_3'));
    });

    test('a terminal event without a start still stamps and appends the '
        'message (skipLast=false path)', () async {
      final first = _FakeStreamFunction([
        _toolTurn([_call('bash_198', 'bash')]),
        _textTurn('done'),
      ]);
      final history1 =
          (await agentLoop(
                prompts: [UserMessage.text('hi')],
                context: const Context(messages: []),
                config: const AgentLoopConfig(model: _model),
                streamFunction: first.call,
                toolExecutor: (_, _, _) async => ToolExecutionResult.text('r1'),
              ).result)
              as List;

      final second = _FakeStreamFunction([
        // No StartEvent: the partial was never added, so the finished
        // message lands via add() and the used-id scan covers everything.
        [
          DoneEvent(
            reason: StopReason.toolUse,
            message: _assistant(
              content: [_call('bash_198', 'bash')],
              stopReason: StopReason.toolUse,
            ),
          ),
        ],
        _textTurn('done two'),
      ]);
      final history2 =
          (await agentLoop(
                prompts: [UserMessage.text('again')],
                context: Context(messages: List.of(history1.cast<Message>())),
                config: const AgentLoopConfig(model: _model),
                streamFunction: second.call,
                toolExecutor: (_, _, _) async => ToolExecutionResult.text('r2'),
              ).result)
              as List;

      final ids2 = [
        for (final m in history2.cast<Message>())
          if (m is AssistantMessage)
            for (final block in m.content)
              if (block is ToolCall) block.id,
      ];
      expect(ids2, contains('bash_198_2'));
      expect(
        history2.cast<Message>().whereType<ToolResultMessage>().map(
          (r) => r.toolCallId,
        ),
        contains('bash_198_2'),
      );
    });

    test('an already-cancelled token short-circuits before the provider '
        'call', () async {
      final fake = _FakeStreamFunction([_textTurn('never')]);
      final source = CancelTokenSource();
      source.cancel('user left');
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: source.token,
      );

      await stream.toList();
      expect(fake.calls, 0);
      final messages = await stream.result as List;
      expect(
        (messages.last as AssistantMessage).stopReason,
        StopReason.aborted,
      );
    });

    test('a stream that closes without a terminal event surfaces an '
        'error turn', () async {
      final partial = _assistant(content: [TextContent(text: 'cut')]);
      final fake = _FakeStreamFunction([
        [
          StartEvent(partial: partial),
          TextStartEvent(contentIndex: 0, partial: partial),
          TextDeltaEvent(contentIndex: 0, delta: 'cut', partial: partial),
        ],
      ]);
      final messages =
          (await agentLoop(
                prompts: [UserMessage.text('hi')],
                context: const Context(messages: []),
                config: const AgentLoopConfig(model: _model),
                streamFunction: fake.call,
                toolExecutor: (_, _, _) async => ToolExecutionResult.text(''),
              ).result)
              as List;
      expect(fake.calls, 1);
      final last = messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('terminal'));
    });
  });

  group('degenerate empty completions', () {
    List<AssistantMessageEvent> emptyTurn() => [
      DoneEvent(reason: StopReason.stop, message: _assistant()),
    ];

    test(
      'an empty completion is retried once, the real answer lands',
      () async {
        final fake = _FakeStreamFunction([
          emptyTurn(),
          _textTurn('real answer'),
        ]);
        final stream = agentLoop(
          prompts: [UserMessage.text('hi')],
          context: const Context(messages: []),
          config: const AgentLoopConfig(model: _model),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        );

        await stream.toList();
        expect(fake.calls, 2);
        final messages = await stream.result;
        expect((messages.last as AssistantMessage).content, [
          isA<TextContent>().having((c) => c.text, 'text', 'real answer'),
        ]);
      },
    );

    test('retries are bounded by maxEmptyRetries', () async {
      final fake = _FakeStreamFunction([
        emptyTurn(),
        emptyTurn(),
        _textTurn('never reached'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      await stream.toList();
      // One retry (the default), then the blank answer is accepted.
      expect(fake.calls, 2);
      final messages = await stream.result;
      expect((messages.last as AssistantMessage).content, isEmpty);
    });

    test('maxEmptyRetries: 0 keeps the old accept-blank behavior', () async {
      final fake = _FakeStreamFunction([
        emptyTurn(),
        _textTurn('never reached'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model, maxEmptyRetries: 0),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      await stream.toList();
      expect(fake.calls, 1);
    });

    test('a completion with tool calls continues normally (no empty-retry '
        '— the next call carries the tool result)', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'noop')], reason: StopReason.toolUse),
        _textTurn('after tools'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
      );

      await stream.toList();
      expect(fake.calls, 2);
      // The second call is the post-tool continuation (its context has the
      // tool result), not an empty-completion retry of the same context.
      expect(
        fake.contexts[1].messages.whereType<ToolResultMessage>(),
        isNotEmpty,
      );
    });

    test('whitespace-only text counts as degenerate and is retried', () async {
      final wsTurn = [
        DoneEvent(
          reason: StopReason.stop,
          message: _assistant(content: [TextContent(text: '   ')]),
        ),
      ];
      final fake = _FakeStreamFunction([wsTurn, _textTurn('real answer')]);
      final stream = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      await stream.toList();
      expect(fake.calls, 2);
      expect(((await stream.result).last as AssistantMessage).content, [
        isA<TextContent>().having((c) => c.text, 'text', 'real answer'),
      ]);
    });
  });

  group('empty completion after partial content (gh-1577)', () {
    final emptyTurn = [
      DoneEvent(reason: StopReason.stop, message: _assistant()),
    ];
    final truncatedFlaggedTurn = [
      DoneEvent(
        reason: StopReason.stop,
        message: _assistant(
          errorMessage:
              'stream ended without finish_reason — the reply may be '
              'truncated',
        ),
      ),
    ];
    final lengthEmptyTurn = [
      // The loop consumes the MESSAGE's stopReason (DoneEvent.reason is not
      // merged) — a real length cut flags the message itself.
      DoneEvent(
        reason: StopReason.length,
        message: _assistant(stopReason: StopReason.length),
      ),
    ];

    /// CLI-shaped loop config: the CLI's own nudge owns clean empties
    /// (`maxEmptyRetries: 0`), the hiccup budget is the loop's.
    AgentLoopConfig cliShapeConfig() => const AgentLoopConfig(
      model: _model,
      maxEmptyRetries: 0,
      emptyHiccupBaseDelay: Duration.zero,
    );

    test(
      'IT-1: empty after tool activity retries and the healthy answer lands',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([_call('c1', 'noop')]),
          emptyTurn,
          _textTurn('task finished for real'),
        ]);
        final stream = agentLoop(
          prompts: [UserMessage.text('do the task')],
          context: const Context(messages: []),
          config: cliShapeConfig(),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
        );

        await stream.toList();
        expect(fake.calls, 3, reason: 'partial + hiccup retry + recovery');
        expect(
          (await stream.result).last as AssistantMessage,
          _text('task finished for real'),
        );
      },
    );

    test('IT-2/E3/AC7: a persistent-empty storm fires exactly N retries then '
        'ends with a loud run error — no storm', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'noop')]),
        emptyTurn,
        emptyTurn,
        emptyTurn,
        emptyTurn,
        _textTurn('never reached'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: const Context(messages: []),
        config: cliShapeConfig(),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
      );

      final events = await stream.toList();
      // partial + 1 original empty + exactly 3 retries = 5 requests.
      expect(fake.calls, 5);
      final last = (await stream.result).last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('empty'));
      expect(last.errorMessage, contains('3 retries'));
      expect(last.errorMessage, contains('4 attempts'));
      expect(last.errorMessage, contains('stop'));
      // The exhaustion verdict is the run's terminal outcome.
      final turnEnds = events.whereType<TurnEndEvent>().toList();
      expect(turnEnds.last.message.stopReason, StopReason.error);
    });

    test('invariant 3: retried empty messages stay in the transcript (truthful '
        'record)', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'noop')]),
        emptyTurn,
        emptyTurn,
        _textTurn('recovered'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: const Context(messages: []),
        config: cliShapeConfig(),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
      );

      final events = await stream.toList();
      await stream.result;
      final ended = events
          .whereType<MessageEndEvent>()
          .where((e) => e.message is AssistantMessage)
          .toList();
      final empties = ended
          .map((e) => e.message as AssistantMessage)
          .where((m) => m.content.isEmpty && m.stopReason == StopReason.stop)
          .length;
      expect(empties, 2, reason: 'both retried empties were emitted');
    });

    test(
      'UT-2/E6: silent-truncation-flagged and length empties follow the same '
      'hiccup path to the loud error (REG-2 family)',
      () async {
        for (final scripted in [truncatedFlaggedTurn, lengthEmptyTurn]) {
          final fake = _FakeStreamFunction([
            _toolTurn([_call('c1', 'noop')]),
            scripted,
            scripted,
            scripted,
            scripted,
          ]);
          final stream = agentLoop(
            prompts: [UserMessage.text('do the task')],
            context: const Context(messages: []),
            config: cliShapeConfig(),
            streamFunction: fake.call,
            toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
          );

          await stream.toList();
          final last = (await stream.result).last as AssistantMessage;
          expect(last.stopReason, StopReason.error);
          expect(fake.calls, 5);
        }
      },
    );

    test('UT-4/E2: a cancel between attempts suppresses the next attempt — no '
        'retry after abort, and the run settles aborted', () async {
      final source = CancelTokenSource();
      final token = source.token;
      final fake = _CancelAfterEmptyStreamFunction([
        _toolTurn([_call('c1', 'noop')]),
        emptyTurn,
      ], source);
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: const Context(messages: []),
        config: cliShapeConfig(),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
        cancelToken: token,
      );

      final events = await stream.toList();
      // The empty turn's request went out; the cancel fires with it; no
      // third request may leave.
      expect(fake.calls, 2);
      final last = (await stream.result).last as AssistantMessage;
      expect(last.stopReason, StopReason.aborted);
      final turnEnds = events.whereType<TurnEndEvent>().toList();
      expect(turnEnds.last.message.stopReason, StopReason.aborted);
    });

    test(
      'AC2: a clean empty keeps the generic budget only — no hiccup retries, '
      'no error conversion',
      () async {
        final fake = _FakeStreamFunction([emptyTurn, _textTurn('nudged')]);
        final stream = agentLoop(
          prompts: [UserMessage.text('hi')],
          context: const Context(messages: []),
          config: cliShapeConfig(),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        );

        await stream.toList();
        expect(fake.calls, 1, reason: 'clean empty: the CLI nudge owns it');
        expect(
          ((await stream.result).last as AssistantMessage).content,
          isEmpty,
        );
      },
    );

    test('gh-1603: the first hiccup retry stays plain; the second and third '
        'carry the continuation nudge — and the recovery lands', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'noop')]),
        emptyTurn,
        emptyTurn,
        emptyTurn,
        _textTurn('recovered after the nudge'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: const Context(messages: []),
        config: cliShapeConfig(),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
      );

      await stream.toList();
      // req0 tool turn, req1 post-tool empty, req2/3/4 = the 3 hiccup
      // retries, last one answered.
      expect(fake.calls, 5);
      bool hasNudge(Context c) => c.messages.any(
        (m) => m is UserMessage && m.content == emptyContinuationNudge,
      );
      expect(
        hasNudge(fake.contexts[2]),
        isFalse,
        reason: 'the first retry re-streams the plain request',
      );
      expect(
        hasNudge(fake.contexts[3]),
        isTrue,
        reason: 'still empty → the continuation nudge rides retry 2',
      );
      expect(
        hasNudge(fake.contexts[4]),
        isTrue,
        reason: 'still empty → the continuation nudge rides retry 3',
      );
      expect(
        (await stream.result).last as AssistantMessage,
        _text('recovered after the nudge'),
      );
    });

    test('gh-1603 AC2: a thinking-only output-truncated first response (the '
        'HT6UsCc shape) reaches a tool call on the next turn', () async {
      final thinkingTruncatedTurn = [
        DoneEvent(
          reason: StopReason.length,
          message: _assistant(
            content: [
              const ThinkingContent(thinking: 'deriving the algorithm…'),
            ],
            stopReason: StopReason.length,
          ),
        ),
      ];
      final fake = _FakeStreamFunction([
        thinkingTruncatedTurn,
        _toolTurn([_call('c1', 'noop')]),
        _textTurn('task complete'),
      ]);
      var toolRan = false;
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: Context(messages: [], tools: [_tool('noop')]),
        config: cliShapeConfig(),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          toolRan = true;
          return ToolExecutionResult.text('done');
        },
      );

      await stream.toList();
      // req0 thinking-truncated empty, req1 the plain first retry (the
      // message itself carries the length signal → no nudge yet), req2 the
      // post-tool-result stream.
      expect(fake.calls, 3);
      expect(
        fake.contexts[1].messages.any(
          (m) => m is UserMessage && m.content == emptyContinuationNudge,
        ),
        isFalse,
        reason: 'the first retry is a plain re-stream',
      );
      expect(toolRan, isTrue, reason: 'the next turn reached a tool call');
      expect(
        (await stream.result).last as AssistantMessage,
        _text('task complete'),
      );
    });

    test('UT: emptyHiccupRetries: 0 is not an escape hatch — the exhaustion '
        'error fires after the maxEmptyRetries budget', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'noop')]),
        emptyTurn,
        _textTurn('never reached'),
      ]);
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(
          model: _model,
          maxEmptyRetries: 0,
          emptyHiccupRetries: 0,
          emptyHiccupBaseDelay: Duration.zero,
        ),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
      );

      await stream.toList();
      final last = (await stream.result).last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(fake.calls, 2, reason: 'the original blank only — no retries');
      expect(last.errorMessage, contains('0 retries'));
      expect(last.errorMessage, contains('1 attempts'));
    });

    test('E5/E2: an abort racing the FINAL hiccup retry wins over any empty '
        'shape — a length-flagged empty settles aborted, never escapes as a '
        'silent final (headless would exit 0 on an aborted run)', () async {
      final source = CancelTokenSource();
      final token = source.token;
      final fake = _CancelAfterEmptyStreamFunction([
        _toolTurn([_call('c1', 'noop')]),
        emptyTurn,
        lengthEmptyTurn,
      ], source);
      final stream = agentLoop(
        prompts: [UserMessage.text('do the task')],
        context: const Context(messages: []),
        config: cliShapeConfig(),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
        cancelToken: token,
      );

      final events = await stream.toList();
      final last = (await stream.result).last as AssistantMessage;
      expect(
        last.stopReason,
        StopReason.aborted,
        reason:
            'the cancel landed with the last retry; a length-flagged '
            'empty must take the explicit aborted terminal, never settle '
            'as the run final',
      );
      // The empty must not escape as a settled turn either: no TurnEnd
      // may carry the length-flagged empty as its outcome (an aborted
      // run settling a turn on a silent empty is the gh-1577 class).
      final turnEnds = events.whereType<TurnEndEvent>().toList();
      expect(turnEnds, isNotEmpty);
      for (final turnEnd in turnEnds) {
        expect(
          turnEnd.message.stopReason,
          isNot(StopReason.length),
          reason:
              'an aborted run must never settle a turn on a '
              'truncation-flagged empty',
        );
      }
    });

    test(
      'E7: the backoff sleep is cancellation-aware — a cancel landing during '
      'the backoff does not wait out the delay',
      () async {
        final source = CancelTokenSource();
        final token = source.token;
        // The empty's request goes out; the abort fires 50ms into the 5s
        // backoff sleep that follows the classification.
        final fake = _CancelDuringBackoffStreamFunction(
          [
            _toolTurn([_call('c1', 'noop')]),
            emptyTurn,
          ],
          source,
          const Duration(milliseconds: 50),
        );
        final stream = agentLoop(
          prompts: [UserMessage.text('do the task')],
          context: const Context(messages: []),
          config: const AgentLoopConfig(
            model: _model,
            maxEmptyRetries: 0,
            emptyHiccupBaseDelay: Duration(seconds: 5),
            emptyHiccupMaxBackoff: Duration(seconds: 5),
          ),
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async => ToolExecutionResult.text('done'),
          cancelToken: token,
        );

        final sw = Stopwatch()..start();
        await stream.toList();
        sw.stop();
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'Ctrl+C during a hiccup storm must not stall for the '
              'backoff window',
        );
        expect(
          ((await stream.result).last as AssistantMessage).stopReason,
          StopReason.aborted,
        );
      },
    );
  });
}

/// Matches an assistant message whose single text block equals [text].
Matcher _text(String text) => isA<AssistantMessage>().having(
  (m) => m.content.whereType<TextContent>().toList(),
  'text blocks',
  [isA<TextContent>().having((c) => c.text, 'text', text)],
);

/// A scripted stream that cancels the run token while replaying the turn at
/// [cancelOnTurn] (0-based): models the abort landing with the empty
/// completion, before the loop classifies it.
class _CancelAfterEmptyStreamFunction {
  _CancelAfterEmptyStreamFunction(this.turns, this.source)
    : cancelOnTurn = turns.length - 1;

  final List<List<AssistantMessageEvent>> turns;
  final CancelTokenSource source;
  final int cancelOnTurn;

  CancelToken get token => source.token;

  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final index = contexts.length;
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
    if (index == cancelOnTurn) source.cancel('test abort');
    return stream;
  }
}

/// A scripted stream that arms the abort timer when it serves the LAST
/// turn: the cancel lands while the loop sits in the between-attempts
/// backoff sleep (after the classification, before the next request).
class _CancelDuringBackoffStreamFunction {
  _CancelDuringBackoffStreamFunction(this.turns, this.source, this.cancelAfter);

  final List<List<AssistantMessageEvent>> turns;
  final CancelTokenSource source;
  final Duration cancelAfter;

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
    final isLast = turns.length == 1;
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    if (isLast) Timer(cancelAfter, () => source.cancel('test abort'));
    return stream;
  }
}
