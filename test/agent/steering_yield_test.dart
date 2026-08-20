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

Tool _tool(String name) {
  return Tool(name: name, description: '$name tool', parameters: const {});
}

void main() {
  group('steer soft-yield', () {
    test('a steer mid-tool cancels the phase yield token, the yield-aware '
        'tool ends early untouched, and the message is delivered at the '
        'boundary', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([ToolCall(id: 'c1', name: 'bash', arguments: const {})]),
        _textTurn('answering the user now'),
      ]);
      final executorStarted = Completer<void>();
      CancelToken? seenYield;
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          seenYield = currentYieldToken();
          // A yield-aware long tool: on yield it returns early WITHOUT
          // stopping its (fictional) work, exactly like the bash/task tools.
          await seenYield!.onCancel;
          return ToolExecutionResult.text('moved to background job sh-1');
        },
      );
      agent.state.tools = [_tool('bash')];

      final run = agent.prompt('run the long thing');
      await executorStarted.future;
      expect(seenYield, isNotNull);
      expect(seenYield!.isCancelled, isFalse);

      agent.steer(UserMessage.text('what is the status?'));
      await run;

      expect(fake.calls, 2);
      final secondCallRoles = fake.contexts[1].messages.map((m) => m.role);
      expect(secondCallRoles, ['user', 'assistant', 'toolResult', 'user']);
      expect(
        (fake.contexts[1].messages.last as UserMessage).content,
        'what is the status?',
      );
    });

    test(
      'the external probe also triggers the yield (inbox mail mid-tool)',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([ToolCall(id: 'c1', name: 'bash', arguments: const {})]),
          _textTurn('done'),
        ]);
        final executorStarted = Completer<void>();
        var inboxHasMail = false;
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            executorStarted.complete();
            final yieldToken = currentYieldToken();
            await yieldToken!.onCancel;
            return ToolExecutionResult.text('moved to background job sh-1');
          },
        );
        agent.state.tools = [_tool('bash')];
        agent.externalSteeringSource = () async {
          if (!inboxHasMail) return const <Message>[];
          inboxHasMail = false;
          return [UserMessage.text('from explore:a1: ping')];
        };
        agent.externalSteeringProbe = () async => inboxHasMail;

        final run = agent.prompt('run the long thing');
        await executorStarted.future;
        inboxHasMail = true; // the 2s probe poll picks it up
        await run.timeout(const Duration(seconds: 10));

        expect(fake.calls, 2);
        expect(
          (fake.contexts[1].messages.last as UserMessage).content,
          'from explore:a1: ping',
        );
      },
    );

    test('a tool that ignores the yield token runs to completion (classic '
        'boundary delivery)', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([ToolCall(id: 'c1', name: 'slow', arguments: const {})]),
        _textTurn('done'),
      ]);
      final executorStarted = Completer<void>();
      final executorGate = Completer<void>();
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          // Yield-unaware tool: never consults the token.
          await executorGate.future;
          return ToolExecutionResult.text('tool done');
        },
      );
      agent.state.tools = [_tool('slow')];

      final run = agent.prompt('go');
      await executorStarted.future;
      agent.steer(UserMessage.text('hello?'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The phase is still blocked on the tool — no second provider call.
      expect(fake.calls, 1);
      executorGate.complete();
      await run;
      expect(fake.calls, 2);
      expect((fake.contexts[1].messages.last as UserMessage).content, 'hello?');
    });
  });
}
