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

const _otherModel = Model(
  id: 'other-model',
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
List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// A scripted provider error turn.
List<AssistantMessageEvent> _errorTurn(String errorMessage) {
  return [
    StartEvent(partial: _assistant()),
    ErrorEvent(
      reason: StopReason.error,
      error: _assistant(
        stopReason: StopReason.error,
        errorMessage: errorMessage,
      ),
    ),
  ];
}

/// Fake [StreamFunction]: replays scripted turns, records every model and
/// context it was called with.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];
  final models = <Model>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    models.add(model);
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

ToolCall _call(String id, String name, [Map<String, dynamic>? args]) {
  return ToolCall(id: id, name: name, arguments: args ?? const {});
}

Tool _tool(String name) {
  return Tool(name: name, description: '$name tool', parameters: const {});
}

Future<ToolExecutionResult> _unusedExecutor(_, _, _) async {
  return ToolExecutionResult.text('unused');
}

Agent _agentWith(_FakeStreamFunction fake, {ToolExecutor? toolExecutor}) {
  return Agent(
    model: _model,
    streamFunction: fake.call,
    toolExecutor: toolExecutor ?? _unusedExecutor,
  );
}

List<Type> _types(List<AgentEvent> events) {
  return events.map((event) => event.runtimeType).toList();
}

void main() {
  group('lifecycle', () {
    test('prompt while idle emits full lifecycle and updates state', () async {
      final fake = _FakeStreamFunction([_textTurn('hello')]);
      final agent = _agentWith(fake);
      final events = <AgentEvent>[];
      agent.subscribe((event, _) => events.add(event));

      await agent.prompt('hi');

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

      expect(agent.state.isStreaming, isFalse);
      expect(agent.state.streamingMessage, isNull);
      expect(agent.state.errorMessage, isNull);
      expect(agent.state.messages, hasLength(2));
      expect(agent.state.messages.first, isA<UserMessage>());
      expect(agent.state.messages.last, isA<AssistantMessage>());
      await agent.waitForIdle();
    });

    test('isStreaming and streamingMessage track the active run', () async {
      final gate = Completer<void>();
      final agent = Agent(
        model: _model,
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: _assistant()));
          unawaited(
            gate.future.then((_) {
              stream.push(
                DoneEvent(
                  reason: StopReason.stop,
                  message: _assistant(content: [const TextContent(text: 'x')]),
                ),
              );
              stream.end();
            }),
          );
          return stream;
        },
        toolExecutor: _unusedExecutor,
      );

      final run = agent.prompt('hi');
      await Future<void>.delayed(Duration.zero);
      expect(agent.state.isStreaming, isTrue);
      expect(agent.state.streamingMessage, isA<AssistantMessage>());
      expect(agent.cancelToken, isNotNull);

      gate.complete();
      await run;
      expect(agent.state.isStreaming, isFalse);
      expect(agent.state.streamingMessage, isNull);
      expect(agent.cancelToken, isNull);
    });

    test('prompt throws while a run is active', () async {
      final gate = Completer<void>();
      final agent = Agent(
        model: _model,
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: _assistant()));
          unawaited(gate.future.then((_) => stream.end()));
          return stream;
        },
        toolExecutor: _unusedExecutor,
      );

      final run = agent.prompt('hi');
      await Future<void>.delayed(Duration.zero);
      expect(agent.state.isStreaming, isTrue);
      expect(() => agent.prompt('again'), throwsA(isA<StateError>()));

      gate.complete();
      await run;
      // After the run finished, prompting works again.
      expect(agent.state.isStreaming, isFalse);
    });

    test(
      'waitForIdle resolves only after agent_end listeners settle',
      () async {
        final fake = _FakeStreamFunction([_textTurn('ok')]);
        final agent = _agentWith(fake);
        final settle = Completer<void>();
        var agentEndSeen = false;
        agent.subscribe((event, _) async {
          if (event is AgentEndEvent) {
            agentEndSeen = true;
            await settle.future;
          }
        });

        final run = agent.prompt('hi');
        while (!agentEndSeen) {
          await Future<void>.delayed(Duration.zero);
        }
        // The agent_end event fired, but its listener has not settled: the run
        // is not idle yet (pi semantics).
        expect(agent.state.isStreaming, isTrue);

        settle.complete();
        await run;
        await agent.waitForIdle();
        expect(agent.state.isStreaming, isFalse);
      },
    );

    test('a second prompt after idle reuses the transcript', () async {
      final fake = _FakeStreamFunction([_textTurn('a1'), _textTurn('a2')]);
      final agent = _agentWith(fake);

      await agent.prompt('p1');
      await agent.prompt('p2');

      expect(fake.calls, 2);
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
      ]);
      expect(agent.state.messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
    });

    test('promptMessage starts a run from a single message', () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final agent = _agentWith(fake);

      await agent.promptMessage(UserMessage.text('seeded'));

      expect(fake.contexts.single.messages.single, isA<UserMessage>());
      expect(agent.state.messages.map((m) => m.role), ['user', 'assistant']);
    });

    test('continueRun throws while a run is active', () async {
      final gate = Completer<void>();
      final agent = Agent(
        model: _model,
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: _assistant()));
          unawaited(gate.future.then((_) => stream.end()));
          return stream;
        },
        toolExecutor: _unusedExecutor,
      );

      final run = agent.prompt('hi');
      await Future<void>.delayed(Duration.zero);
      await expectLater(agent.continueRun(), throwsA(isA<StateError>()));

      gate.complete();
      await run;
    });

    test('subscribe returns an unsubscribe function', () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final agent = _agentWith(fake);
      final events = <AgentEvent>[];
      final unsubscribe = agent.subscribe((event, _) => events.add(event));

      unsubscribe();
      await agent.prompt('hi');

      expect(events, isEmpty);
    });

    test('state.tools and state.messages copy assigned lists', () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final agent = _agentWith(fake);

      final tools = [_tool('weather')];
      agent.state.tools = tools;
      tools.add(_tool('extra'));
      expect(agent.state.tools, hasLength(1));

      agent.state.messages = [UserMessage.text('seed')];
      await agent.prompt('p');
      expect(fake.contexts.single.messages.map((m) => m.role), [
        'user',
        'user',
      ]);
    });
  });

  group('steering', () {
    test('steer mid-run is consumed at the next turn boundary without '
        'interrupting the current turn', () async {
      final executorStarted = Completer<void>();
      final executorGate = Completer<void>();
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('sunny'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          await executorGate.future;
          return ToolExecutionResult.text('22C');
        },
      );
      agent.state.tools = [_tool('weather')];
      final events = <AgentEvent>[];
      agent.subscribe((event, _) => events.add(event));

      final run = agent.prompt('weather?');
      await executorStarted.future;
      expect(agent.state.pendingToolCalls, {'call-1'});

      agent.steer(UserMessage.text('actually, in Berlin'));
      // The current turn is not interrupted: no second provider call yet.
      expect(fake.calls, 1);

      executorGate.complete();
      await run;

      expect(agent.state.pendingToolCalls, isEmpty);
      expect(fake.calls, 2);
      // The steered message is appended after the tool result and seen by the
      // next provider call.
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'toolResult',
        'user',
      ]);
      expect(
        (fake.contexts[1].messages.last as UserMessage).content,
        'actually, in Berlin',
      );

      // Event order: the steered message is announced after the turn
      // boundary (turn_end, then turn_start), not mid-turn.
      final turnEndIndex = _types(events).indexOf(TurnEndEvent);
      final steeredIndex = events.indexWhere(
        (event) =>
            event is MessageStartEvent &&
            event.message is UserMessage &&
            (event.message as UserMessage).content == 'actually, in Berlin',
      );
      expect(steeredIndex, greaterThan(turnEndIndex));
      expect(
        events.sublist(turnEndIndex, steeredIndex).whereType<TurnStartEvent>(),
        hasLength(1),
      );
    });

    test('one-at-a-time mode consumes one steering message per turn', () async {
      final fake = _FakeStreamFunction([_textTurn('a1'), _textTurn('a2')]);
      final agent = _agentWith(fake);

      agent.steer(UserMessage.text('s1'));
      agent.steer(UserMessage.text('s2'));
      await agent.prompt('p');

      expect(fake.calls, 2);
      expect(fake.contexts[0].messages.map((m) => m.role), ['user', 'user']);
      expect((fake.contexts[0].messages.last as UserMessage).content, 's1');
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'user',
        'assistant',
        'user',
      ]);
      expect((fake.contexts[1].messages.last as UserMessage).content, 's2');
    });

    test(
      'all mode drains every queued steering message at one boundary',
      () async {
        final fake = _FakeStreamFunction([_textTurn('a1')]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: _unusedExecutor,
          steeringMode: QueueMode.all,
        );
        expect(agent.steeringMode, QueueMode.all);

        agent.steer(UserMessage.text('s1'));
        agent.steer(UserMessage.text('s2'));
        await agent.prompt('p');

        expect(fake.calls, 1);
        expect(fake.contexts[0].messages.map((m) => m.role), [
          'user',
          'user',
          'user',
        ]);

        agent.steeringMode = QueueMode.oneAtATime;
        expect(agent.steeringMode, QueueMode.oneAtATime);
      },
    );

    test('steer after the run ended is picked up by the next run', () async {
      final fake = _FakeStreamFunction([_textTurn('a1'), _textTurn('a2')]);
      final agent = _agentWith(fake);

      await agent.prompt('p1');
      agent.steer(UserMessage.text('s1'));
      await agent.prompt('p2');

      expect(fake.calls, 2);
      // The steering poll at the start of the second run drains the queue.
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'user',
      ]);
      expect((fake.contexts[1].messages.last as UserMessage).content, 's1');
    });
  });

  group('follow-up', () {
    test('follow-up queued during a run is processed after the run would '
        'stop', () async {
      final fake = _FakeStreamFunction([_textTurn('a1'), _textTurn('a2')]);
      final agent = _agentWith(fake);
      final events = <AgentEvent>[];
      var queued = false;
      agent.subscribe((event, _) {
        events.add(event);
        if (event is TurnEndEvent && !queued) {
          queued = true;
          agent.followUp(UserMessage.text('one more thing'));
        }
      });

      await agent.prompt('p');

      expect(fake.calls, 2);
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
      ]);
      expect(
        (fake.contexts[1].messages.last as UserMessage).content,
        'one more thing',
      );

      // The follow-up message is announced after the first turn ended.
      final turnEndIndex = _types(events).indexOf(TurnEndEvent);
      final followUpIndex = events.indexWhere(
        (event) =>
            event is MessageStartEvent &&
            event.message is UserMessage &&
            (event.message as UserMessage).content == 'one more thing',
      );
      expect(followUpIndex, greaterThan(turnEndIndex));
    });

    test(
      'follow-up queued during follow-up processing extends the run',
      () async {
        final fake = _FakeStreamFunction([
          _textTurn('a1'),
          _textTurn('a2'),
          _textTurn('a3'),
        ]);
        final agent = _agentWith(fake);
        var turnEnds = 0;
        agent.subscribe((event, _) {
          if (event is TurnEndEvent) {
            turnEnds++;
            if (turnEnds == 1) agent.followUp(UserMessage.text('f1'));
            if (turnEnds == 2) agent.followUp(UserMessage.text('f2'));
          }
        });

        await agent.prompt('p');

        expect(fake.calls, 3);
        expect(fake.contexts[1].messages.map((m) => m.role), [
          'user',
          'assistant',
          'user',
        ]);
        expect(fake.contexts[2].messages.map((m) => m.role), [
          'user',
          'assistant',
          'user',
          'assistant',
          'user',
        ]);
        expect((fake.contexts[2].messages.last as UserMessage).content, 'f2');
      },
    );

    test('all mode drains every queued follow-up at once', () async {
      final fake = _FakeStreamFunction([_textTurn('a1'), _textTurn('a2')]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: _unusedExecutor,
        followUpMode: QueueMode.all,
      );
      expect(agent.followUpMode, QueueMode.all);
      var queued = false;
      agent.subscribe((event, _) {
        if (event is TurnEndEvent && !queued) {
          queued = true;
          agent.followUp(UserMessage.text('f1'));
          agent.followUp(UserMessage.text('f2'));
        }
      });

      await agent.prompt('p');

      expect(fake.calls, 2);
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'user',
      ]);

      agent.followUpMode = QueueMode.oneAtATime;
      expect(agent.followUpMode, QueueMode.oneAtATime);
    });
  });

  group('hooks', () {
    test(
      'beforeToolCall fires with pi context and can block with a reason',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([
            _call('call-1', 'weather', {'city': 'Berlin'}),
          ]),
          _textTurn('blocked handled'),
        ]);
        BeforeToolCallContext? seen;
        CancelToken? seenToken;
        CancelToken? executorToken;
        var executed = false;
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            executed = true;
            executorToken = cancelToken;
            return ToolExecutionResult.text('unused');
          },
          beforeToolCall: (context, cancelToken) {
            seen = context;
            seenToken = cancelToken;
            return const BeforeToolCallResult(block: true, reason: 'not today');
          },
        );
        agent.state.tools = [_tool('weather')];

        await agent.prompt('go');

        expect(executed, isFalse);
        expect(seen, isNotNull);
        expect(seen!.toolCall.id, 'call-1');
        expect(seen!.toolCall.arguments, {'city': 'Berlin'});
        expect(seen!.assistantMessage.stopReason, StopReason.toolUse);
        expect(seen!.context.tools, isNotNull);
        expect(seenToken, isNotNull);

        final toolResult = agent.state.messages
            .whereType<ToolResultMessage>()
            .single;
        expect(toolResult.isError, isTrue);
        expect((toolResult.content.single as TextContent).text, 'not today');
        // The blocked result goes back to the model, which answers next turn.
        expect(fake.calls, 2);

        // A later unblocked run shows the hook receives the run's cancel token.
        seen = null;
        final fake2 = _FakeStreamFunction([
          _toolTurn([_call('call-2', 'weather')]),
          _textTurn('ok'),
        ]);
        final agent2 = Agent(
          model: _model,
          streamFunction: fake2.call,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            executorToken = cancelToken;
            return ToolExecutionResult.text('ok');
          },
          beforeToolCall: (context, cancelToken) {
            seenToken = cancelToken;
            return null;
          },
        );
        agent2.state.tools = [_tool('weather')];
        await agent2.prompt('go');
        expect(seenToken, same(executorToken));
      },
    );

    test(
      'beforeToolCall block without a reason uses the default message',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([_call('call-1', 'weather')]),
          _textTurn('ok'),
        ]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: _unusedExecutor,
          beforeToolCall: (_, _) => const BeforeToolCallResult(block: true),
        );
        agent.state.tools = [_tool('weather')];

        await agent.prompt('go');

        final toolResult = agent.state.messages
            .whereType<ToolResultMessage>()
            .single;
        expect(
          (toolResult.content.single as TextContent).text,
          'Tool execution was blocked',
        );
      },
    );

    test('beforeToolCall throwing becomes an error tool result', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('handled'),
      ]);
      var executed = false;
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          executed = true;
          return ToolExecutionResult.text('unused');
        },
        beforeToolCall: (_, _) => throw StateError('hook broke'),
      );
      agent.state.tools = [_tool('weather')];

      await agent.prompt('go');

      expect(executed, isFalse);
      final toolResult = agent.state.messages
          .whereType<ToolResultMessage>()
          .single;
      expect(toolResult.isError, isTrue);
      expect(
        (toolResult.content.single as TextContent).text,
        contains('hook broke'),
      );
      expect(fake.calls, 2);
    });

    test(
      'beforeToolCall aborting the run yields an aborted tool result',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([_call('call-1', 'weather')]),
          _textTurn('unreachable'),
        ]);
        late final Agent agent;
        var executed = false;
        agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: (_, _, _) async {
            executed = true;
            return ToolExecutionResult.text('unused');
          },
          beforeToolCall: (context, cancelToken) {
            agent.abort();
            return null;
          },
        );
        agent.state.tools = [_tool('weather')];

        await agent.prompt('go');

        expect(executed, isFalse);
        final toolResult = agent.state.messages
            .whereType<ToolResultMessage>()
            .single;
        expect(toolResult.isError, isTrue);
        expect(
          (toolResult.content.single as TextContent).text,
          'Operation aborted',
        );
        // No further provider call: the next turn short-circuits on the
        // cancelled token.
        expect(fake.calls, 1);
      },
    );

    test('afterToolCall can replace content and force termination', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('unreachable'),
      ]);
      AfterToolCallContext? seen;
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('raw'),
        afterToolCall: (context, cancelToken) {
          seen = context;
          return const AfterToolCallResult(
            content: [TextContent(text: 'rewritten')],
            terminate: true,
          );
        },
      );
      agent.state.tools = [_tool('weather')];

      await agent.prompt('go');

      expect(seen, isNotNull);
      expect(seen!.toolCall.id, 'call-1');
      expect(seen!.isError, isFalse);
      expect((seen!.result.content.single as TextContent).text, 'raw');

      final toolResult = agent.state.messages
          .whereType<ToolResultMessage>()
          .single;
      expect(toolResult.isError, isFalse);
      expect((toolResult.content.single as TextContent).text, 'rewritten');
      // terminate: true stopped the loop after the tool batch.
      expect(fake.calls, 1);
    });

    test('afterToolCall can flip the error flag', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('ok'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => throw StateError('disk exploded'),
        afterToolCall: (context, cancelToken) {
          expect(context.isError, isTrue);
          return const AfterToolCallResult(isError: false);
        },
      );
      agent.state.tools = [_tool('weather')];

      await agent.prompt('go');

      final toolResult = agent.state.messages
          .whereType<ToolResultMessage>()
          .single;
      expect(toolResult.isError, isFalse);
    });

    test('afterToolCall throwing turns the result into an error', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('handled'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('raw'),
        afterToolCall: (_, _) => throw StateError('after broke'),
      );
      agent.state.tools = [_tool('weather')];

      await agent.prompt('go');

      final toolResult = agent.state.messages
          .whereType<ToolResultMessage>()
          .single;
      expect(toolResult.isError, isTrue);
      expect(
        (toolResult.content.single as TextContent).text,
        contains('after broke'),
      );
    });

    test(
      'transformContext rewrites provider input, not the transcript',
      () async {
        final fake = _FakeStreamFunction([_textTurn('ok')]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: _unusedExecutor,
          transformContext: (messages, cancelToken) async {
            return [...messages, UserMessage.text('INJECTED')];
          },
        );

        await agent.prompt('hi');

        // The provider saw the transformed messages.
        expect(
          (fake.contexts.single.messages.last as UserMessage).content,
          'INJECTED',
        );
        // The transcript is untouched.
        expect(
          agent.state.messages.whereType<UserMessage>().map((m) => m.content),
          ['hi'],
        );
      },
    );

    test('prepareNextTurn can swap the model for the next turn', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('done'),
      ]);
      final seenContexts = <NextTurnContext>[];
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('22C'),
        prepareNextTurn: (context) {
          seenContexts.add(context);
          if (context.message.stopReason == StopReason.toolUse) {
            return const AgentLoopTurnUpdate(model: _otherModel);
          }
          return null;
        },
      );
      agent.state.tools = [_tool('weather')];

      await agent.prompt('go');

      expect(fake.models, [_model, _otherModel]);
      // The hook fires after every turn with pi's context shape.
      expect(seenContexts, hasLength(2));
      expect(seenContexts.first.toolResults, hasLength(1));
      expect(seenContexts.first.newMessages, isNotEmpty);
      expect(seenContexts.first.context.messages, isNotEmpty);
      expect(seenContexts.last.toolResults, isEmpty);
    });

    test('prepareNextTurn can replace the context for the next turn', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('done'),
      ]);
      var replaced = false;
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('22C'),
        prepareNextTurn: (context) {
          if (!replaced) {
            replaced = true;
            return AgentLoopTurnUpdate(
              context: Context(messages: [UserMessage.text('reset')]),
            );
          }
          return null;
        },
      );
      agent.state.tools = [_tool('weather')];

      await agent.prompt('go');

      expect(fake.contexts[1].messages.single, isA<UserMessage>());
      expect(
        (fake.contexts[1].messages.single as UserMessage).content,
        'reset',
      );
    });
  });

  group('abort', () {
    test(
      'abort mid-stream ends with aborted semantics and idle state',
      () async {
        final agent = Agent(
          model: _model,
          streamFunction: (model, context, {cancelToken}) {
            final stream = AssistantMessageEventStream();
            stream.push(StartEvent(partial: _assistant()));
            unawaited(
              cancelToken!.onCancel.then((_) {
                stream.push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: _assistant(
                      stopReason: StopReason.aborted,
                      errorMessage: 'aborted',
                    ),
                  ),
                );
                stream.end();
              }),
            );
            return stream;
          },
          toolExecutor: _unusedExecutor,
        );
        final events = <AgentEvent>[];
        agent.subscribe((event, _) => events.add(event));

        final run = agent.prompt('hi');
        await Future<void>.delayed(Duration.zero);
        agent.abort();
        await run;

        expect(agent.state.isStreaming, isFalse);
        expect(agent.state.errorMessage, 'aborted');
        expect(events.last, isA<AgentEndEvent>());
        final last = agent.state.messages.last as AssistantMessage;
        expect(last.stopReason, StopReason.aborted);
      },
    );

    test('abort during tool execution: steering is consumed at the boundary, '
        'follow-ups stay queued', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('unreachable'),
      ]);
      late final Agent agent;
      agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          agent.steer(UserMessage.text('steered'));
          agent.abort();
          return ToolExecutionResult.text('partial');
        },
      );
      agent.state.tools = [_tool('weather')];
      agent.followUp(UserMessage.text('later'));

      await agent.prompt('go');

      // The next provider call was short-circuited by the cancelled token.
      expect(fake.calls, 1);
      final roles = agent.state.messages.map((m) => m.role).toList();
      expect(roles, ['user', 'assistant', 'toolResult', 'user', 'assistant']);
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.aborted);
      // The aborted run never polled follow-ups: the queue keeps its items.
      expect(agent.hasQueuedMessages(), isTrue);
    });

    test('abort with no active run is a no-op', () {
      final agent = _agentWith(_FakeStreamFunction([]));
      agent.abort();
      expect(agent.state.isStreaming, isFalse);
      expect(agent.cancelToken, isNull);
    });
  });

  group('errors', () {
    test(
      'provider error event sets errorMessage and completes the prompt',
      () async {
        final fake = _FakeStreamFunction([_errorTurn('HTTP 500')]);
        final agent = _agentWith(fake);
        final events = <AgentEvent>[];
        agent.subscribe((event, _) => events.add(event));

        await agent.prompt('hi');

        expect(agent.state.isStreaming, isFalse);
        expect(agent.state.errorMessage, 'HTTP 500');
        expect(events.last, isA<AgentEndEvent>());
        final last = agent.state.messages.last as AssistantMessage;
        expect(last.stopReason, StopReason.error);
      },
    );

    test('a throwing transformContext fails the run with a synthetic error '
        'message', () async {
      final fake = _FakeStreamFunction([_textTurn('unreachable')]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: _unusedExecutor,
        transformContext: (messages, cancelToken) {
          throw StateError('transform broke');
        },
      );
      final events = <AgentEvent>[];
      agent.subscribe((event, _) => events.add(event));

      await agent.prompt('hi');

      expect(fake.calls, 0);
      expect(agent.state.isStreaming, isFalse);
      expect(events.last, isA<AgentEndEvent>());
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('transform broke'));
    });
  });

  group('continueRun', () {
    test('throws with no messages', () async {
      final agent = _agentWith(_FakeStreamFunction([]));
      await expectLater(agent.continueRun(), throwsA(isA<StateError>()));
    });

    test('throws when the transcript ends with an assistant message and no '
        'queued messages', () async {
      final fake = _FakeStreamFunction([_textTurn('a1')]);
      final agent = _agentWith(fake);
      await agent.prompt('p');

      await expectLater(agent.continueRun(), throwsA(isA<StateError>()));
    });

    test('drains queued steering when the transcript ends with an assistant '
        'message', () async {
      final fake = _FakeStreamFunction([
        _textTurn('a1'),
        _textTurn('a2'),
        _textTurn('a3'),
      ]);
      final agent = _agentWith(fake);
      await agent.prompt('p1');

      agent.steer(UserMessage.text('m1'));
      agent.steer(UserMessage.text('m2'));
      await agent.continueRun();

      expect(fake.calls, 3);
      // continueRun() drains one steering message (one-at-a-time) and uses it
      // as the prompt; m2 waits for the next turn boundary instead of being
      // injected into the same first turn (pi's skipInitialSteeringPoll).
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
      ]);
      expect((fake.contexts[1].messages.last as UserMessage).content, 'm1');
      expect(fake.contexts[2].messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
        'user',
      ]);
      expect((fake.contexts[2].messages.last as UserMessage).content, 'm2');
    });

    test('continues from a tool-result message without new prompts', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([_call('call-1', 'weather')]),
        _textTurn('final answer'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async {
          return ToolExecutionResult.text('22C', terminate: true);
        },
      );
      agent.state.tools = [_tool('weather')];
      final events = <AgentEvent>[];
      agent.subscribe((event, _) => events.add(event));

      await agent.prompt('go');
      expect(agent.state.messages.last, isA<ToolResultMessage>());

      await agent.continueRun();

      expect(fake.calls, 2);
      expect(fake.contexts[1].messages.map((m) => m.role), [
        'user',
        'assistant',
        'toolResult',
      ]);
      // The continuation run's agent_end carries only its own messages.
      final agentEnds = events.whereType<AgentEndEvent>().toList();
      expect(agentEnds, hasLength(2));
      expect(agentEnds.last.messages.single, isA<AssistantMessage>());
    });
  });

  group('queue management', () {
    test('clearing queues removes pending messages', () async {
      final fake = _FakeStreamFunction([_textTurn('a1')]);
      final agent = _agentWith(fake);

      agent.steer(UserMessage.text('s1'));
      agent.followUp(UserMessage.text('f1'));
      expect(agent.hasQueuedMessages(), isTrue);

      agent.clearSteeringQueue();
      agent.clearFollowUpQueue();
      expect(agent.hasQueuedMessages(), isFalse);

      agent.steer(UserMessage.text('s2'));
      agent.followUp(UserMessage.text('f2'));
      agent.clearAllQueues();
      expect(agent.hasQueuedMessages(), isFalse);

      // Nothing queued: the run is a single turn.
      await agent.prompt('p');
      expect(fake.calls, 1);
    });

    test('reset clears transcript, runtime state, and queues', () async {
      final fake = _FakeStreamFunction([_errorTurn('boom'), _textTurn('a1')]);
      final agent = _agentWith(fake);
      await agent.prompt('p');
      expect(agent.state.errorMessage, 'boom');

      agent.steer(UserMessage.text('s'));
      agent.followUp(UserMessage.text('f'));
      agent.reset();

      expect(agent.state.messages, isEmpty);
      expect(agent.state.isStreaming, isFalse);
      expect(agent.state.streamingMessage, isNull);
      expect(agent.state.pendingToolCalls, isEmpty);
      expect(agent.state.errorMessage, isNull);
      expect(agent.hasQueuedMessages(), isFalse);
    });
  });
}
