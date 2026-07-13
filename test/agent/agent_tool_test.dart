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
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted turn ending with tool calls.
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

/// Fake [StreamFunction]: replays scripted turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

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

ToolCall _call(String id, String name, [Map<String, dynamic> args = const {}]) {
  return ToolCall(id: id, name: name, arguments: args);
}

AgentTool _echoTool({
  Map<String, dynamic> parameters = const {},
  AgentToolExecute? execute,
}) {
  return AgentTool(
    name: 'echo',
    description: 'echoes arguments',
    parameters: parameters,
    execute:
        execute ??
        (args, cancelToken, onUpdate) async => ToolExecutionResult.text(
          args.entries.map((e) => '${e.key}=${e.value}').join(','),
        ),
  );
}

void main() {
  group('Agent + ToolRegistry integration', () {
    test('Agent(toolRegistry:) wires tools and executor', () async {
      final registry = ToolRegistry([_echoTool()]);
      final fake = _FakeStreamFunction([
        _toolTurn([
          _call('c1', 'echo', {'text': 'hi'}),
        ]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
      );
      await agent.prompt('go');

      // The provider saw the registered tool in the context.
      expect(fake.contexts.first.tools!.single.name, 'echo');

      // Transcript: user, assistant(tool call), tool result, assistant(text).
      final messages = agent.state.messages;
      expect(messages, hasLength(4));
      final toolResult = messages[2] as ToolResultMessage;
      expect(toolResult.toolCallId, 'c1');
      expect(toolResult.toolName, 'echo');
      expect(toolResult.isError, isFalse);
      expect((toolResult.content.single as TextContent).text, 'text=hi');
    });

    test('explicit toolExecutor wins over toolRegistry', () async {
      var executorCalled = false;
      final registry = ToolRegistry([_echoTool()]);
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'echo')]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorCalled = true;
          return ToolExecutionResult.text('custom');
        },
      );
      await agent.prompt('go');
      expect(executorCalled, isTrue);
      final toolResult = agent.state.messages[2] as ToolResultMessage;
      expect((toolResult.content.single as TextContent).text, 'custom');
    });

    test(
      'unknown tool call yields error tool result, not an exception',
      () async {
        final registry = ToolRegistry([_echoTool()]);
        final fake = _FakeStreamFunction([
          _toolTurn([
            _call('c1', 'ghost', {'a': 1}),
          ]),
          _textTurn('recovered'),
        ]);
        final agent = Agent(
          model: _model,
          toolRegistry: registry,
          streamFunction: fake.call,
        );
        await agent.prompt('go');

        final toolResult = agent.state.messages[2] as ToolResultMessage;
        expect(toolResult.isError, isTrue);
        expect(toolResult.toolName, 'ghost');
        expect(agent.state.errorMessage, isNull);
        // The loop continued and produced the final text turn.
        expect(agent.state.messages.last, isA<AssistantMessage>());
      },
    );

    test(
      'invalid arguments yield error tool result; tool not executed',
      () async {
        var executed = false;
        final registry = ToolRegistry([
          _echoTool(
            parameters: const {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
              'required': ['path'],
            },
            execute: (args, cancelToken, onUpdate) async {
              executed = true;
              return ToolExecutionResult.text('ok');
            },
          ),
        ]);
        final fake = _FakeStreamFunction([
          _toolTurn([
            _call('c1', 'echo', {'wrong': 1}),
          ]),
          _textTurn('recovered'),
        ]);
        final agent = Agent(
          model: _model,
          toolRegistry: registry,
          streamFunction: fake.call,
        );
        await agent.prompt('go');

        expect(executed, isFalse);
        final toolResult = agent.state.messages[2] as ToolResultMessage;
        expect(toolResult.isError, isTrue);
        final text = (toolResult.content.single as TextContent).text;
        expect(text, contains('path'));
        expect(text, contains('echo'));
      },
    );

    test('stringly-typed arguments are coerced before execute', () async {
      Map<String, dynamic>? received;
      final registry = ToolRegistry([
        _echoTool(
          parameters: const {
            'type': 'object',
            'properties': {
              'count': {'type': 'integer'},
            },
            'required': ['count'],
          },
          execute: (args, cancelToken, onUpdate) async {
            received = args;
            return ToolExecutionResult.text('ok');
          },
        ),
      ]);
      final fake = _FakeStreamFunction([
        _toolTurn([
          _call('c1', 'echo', {'count': '7'}),
        ]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
      );
      await agent.prompt('go');
      expect(received, {'count': 7});
      final toolResult = agent.state.messages[2] as ToolResultMessage;
      expect(toolResult.isError, isFalse);
    });

    test('cancelToken reaches tool execute', () async {
      CancelToken? seenToken;
      final registry = ToolRegistry([
        _echoTool(
          execute: (args, cancelToken, onUpdate) async {
            seenToken = cancelToken;
            return ToolExecutionResult.text('ok');
          },
        ),
      ]);
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'echo')]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
      );
      await agent.prompt('go');
      expect(seenToken, isNotNull);
      expect(identical(seenToken, agent.cancelToken), isFalse); // run ended
    });

    test('onUpdate streams partial results through loop events', () async {
      final registry = ToolRegistry([
        _echoTool(
          execute: (args, cancelToken, onUpdate) async {
            onUpdate?.call(ToolExecutionResult.text('half'));
            return ToolExecutionResult.text('full');
          },
        ),
      ]);
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'echo')]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
      );
      final updates = <ToolExecutionUpdateEvent>[];
      agent.subscribe((event, cancelToken) {
        if (event is ToolExecutionUpdateEvent) updates.add(event);
      });
      await agent.prompt('go');
      expect(updates, hasLength(1));
      expect(updates.single.partialResult.content, [
        isA<TextContent>().having((c) => c.text, 'text', 'half'),
      ]);
    });

    test('per-tool sequential executionMode forces sequential batch', () async {
      final log = <String>[];
      AgentTool tool(String name, {ToolExecutionMode? mode}) {
        return AgentTool(
          name: name,
          description: '$name tool',
          executionMode: mode,
          execute: (args, cancelToken, onUpdate) async {
            log.add('start $name');
            await Future<void>.delayed(const Duration(milliseconds: 10));
            log.add('end $name');
            return ToolExecutionResult.text(name);
          },
        );
      }

      final registry = ToolRegistry([
        tool('slow', mode: ToolExecutionMode.sequential),
        tool('fast'),
      ]);
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'slow'), _call('c2', 'fast')]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
        toolExecution: ToolExecutionMode.parallel,
      );
      await agent.prompt('go');
      // Sequential: fast must not start before slow ends.
      expect(log, ['start slow', 'end slow', 'start fast', 'end fast']);
    });

    test('parallel default overlaps executions', () async {
      final log = <String>[];
      AgentTool tool(String name) {
        return AgentTool(
          name: name,
          description: '$name tool',
          execute: (args, cancelToken, onUpdate) async {
            log.add('start $name');
            await Future<void>.delayed(const Duration(milliseconds: 10));
            log.add('end $name');
            return ToolExecutionResult.text(name);
          },
        );
      }

      final registry = ToolRegistry([tool('a'), tool('b')]);
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'a'), _call('c2', 'b')]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        streamFunction: fake.call,
      );
      await agent.prompt('go');
      expect(log.sublist(0, 2), ['start a', 'start b']);
    });

    test(
      'tools assigned to state are picked up by the registry executor',
      () async {
        final registry = ToolRegistry([_echoTool()]);
        final fake = _FakeStreamFunction([
          _toolTurn([_call('c1', 'echo')]),
          _textTurn('done'),
        ]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: registry.executor,
        );
        // No tools in context: the loop rejects the call before the executor.
        await agent.prompt('go');
        var toolResult = agent.state.messages[2] as ToolResultMessage;
        expect(toolResult.isError, isTrue);

        // Registering the tool into the state lets the next run execute it.
        agent.state.tools = registry.tools;
        fake.turns.addAll([
          _toolTurn([_call('c2', 'echo')]),
          _textTurn('done'),
        ]);
        await agent.prompt('again');
        final messages = agent.state.messages;
        toolResult = messages[messages.length - 2] as ToolResultMessage;
        expect(toolResult.isError, isFalse);
      },
    );
  });
}
