/// gh-1556 AC6: the per-turn `time-left:` budget line rides every LLM
/// request payload when (and ONLY when) a deadline is armed — the same
/// scripted-loop harness the FinalizeGate suite uses. Payload-only: the
/// transcript (and therefore the session records) is never touched, and a
/// disarmed deadline keeps the outbound payloads byte-for-byte.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../support/scripted_stream_harness.dart';

void main() {
  /// Runs one scripted turn sequence and returns every recorded request
  /// payload. The tool turn first so the run makes two provider calls.
  Future<List<Context>> runScripted(
    List<List<AssistantMessageEvent>> turns, {
    required AgentLoopConfig config,
  }) async {
    final fake = FakeStreamFunction(turns);
    final stream = agentLoop(
      prompts: [UserMessage.text('fixture task')],
      context: Context(messages: const [], tools: const []),
      config: config,
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('ok'),
    );
    await stream.toList();
    return fake.contexts;
  }

  List<String> payloadLines(List<Context> contexts) => [
    for (final context in contexts)
      context.messages
          .map((m) => m is UserMessage ? messageText(m) : '<${m.role}>')
          .join('\n'),
  ];

  test('armed: every request payload carries the trailing time-left line',
      () async {
    final contexts = await runScripted(
      [toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]), textTurn('done')],
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () => 'time-left: 5min',
      ),
    );
    expect(contexts, hasLength(2));
    for (final context in contexts) {
      final last = context.messages.last;
      expect(last, isA<UserMessage>());
      expect(messageText(last as UserMessage), 'time-left: 5min');
    }
  });

  test('armed: the line refreshes per request (live provider per turn)',
      () async {
    var remaining = '10min';
    final contexts = await runScripted(
      [toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]), textTurn('done')],
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () {
          final line = 'time-left: $remaining';
          remaining = '9min';
          return line;
        },
      ),
    );
    expect(
      messageText(contexts[0].messages.last as UserMessage),
      'time-left: 10min',
    );
    expect(
      messageText(contexts[1].messages.last as UserMessage),
      'time-left: 9min',
    );
  });

  test('disarmed: payloads are byte-for-byte the provider-less shape', () async {
    final baseline = await runScripted(
      [toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]), textTurn('done')],
      config: AgentLoopConfig(model: testModel),
    );
    // Provider present but returning null (deadline cleared mid-session)
    // must equal NO provider at all.
    final cleared = await runScripted(
      [toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]), textTurn('done')],
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () => null,
      ),
    );
    expect(payloadLines(cleared), payloadLines(baseline));
  });

  test('the line is payload-only: the recorded transcript never sees it',
      () async {
    final fake = FakeStreamFunction([textTurn('done')]);
    final stream = agentLoop(
      prompts: [UserMessage.text('fixture task')],
      context: Context(messages: const [], tools: const []),
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () => 'time-left: 5min',
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('ok'),
    );
    final events = await stream.toList();
    // The request saw the line…
    expect(
      messageText(fake.contexts.single.messages.last as UserMessage),
      'time-left: 5min',
    );
    // …the transcript events did not: every recorded assistant/user text
    // is the scripted content, with no budget line anywhere.
    final texts = [
      for (final event in events)
        if (event is MessageEndEvent && event.message is AssistantMessage)
          [
            for (final block
                in (event.message as AssistantMessage).content)
              if (block is TextContent) block.text,
          ].join(),
    ];
    expect(texts, ['done']);
    expect(
      events.where((e) => e.toString().contains('time-left')),
      isEmpty,
    );
  });

  test('Agent.budgetLineProvider threads into the loop config', () async {
    final agent = Agent(
      model: testModel,
      streamFunction: FakeStreamFunction([textTurn('done')]).call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('ok'),
      budgetLineProvider: () => 'time-left: 1h',
    );
    final done = Completer<void>();
    agent.subscribe((event, _) {
      if (event is AgentEndEvent) done.complete();
    });
    await agent.prompt('hello');
    await done.future;
    final last = agent.state.messages.last as AssistantMessage;
    expect(
      [for (final block in last.content) if (block is TextContent) block.text],
      ['done'],
    );
  });
}
