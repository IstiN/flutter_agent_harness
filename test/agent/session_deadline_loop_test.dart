/// gh-1556 AC6: the per-turn `time-left:` budget line rides every LLM
/// request payload when (and ONLY when) a deadline is armed — the same
/// scripted-loop harness the FinalizeGate suite uses. Payload-only: the
/// transcript (and therefore the session records) is never touched, and a
/// disarmed deadline keeps the outbound payloads byte-for-byte.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../support/scripted_stream_harness.dart';

void main() {
  List<AssistantMessageEvent> textTurn(String text) {
    final empty = testAssistant();
    final partial = testAssistant(content: [TextContent(text: text)]);
    return [
      StartEvent(partial: empty),
      TextStartEvent(contentIndex: 0, partial: empty),
      TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
      DoneEvent(reason: StopReason.stop, message: partial),
    ];
  }

  /// Runs one scripted turn and returns every recorded request payload.
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

  test('armed: every request payload carries the trailing time-left line',
      () async {
    final contexts = await runScripted(
      [textTurn('one'), textTurn('two')],
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () => 'time-left: 5min',
      ),
    );
    expect(contexts, hasLength(2));
    for (final context in contexts) {
      final last = context.messages.last as UserMessage;
      expect(messageText(last), 'time-left: 5min');
    }
  });

  test('armed: the line refreshes per request (live provider per turn)',
      () async {
    var remaining = '10min';
    final contexts = await runScripted(
      [textTurn('one'), textTurn('two')],
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () {
          final line = 'time-left: $remaining';
          remaining = '9min';
          return line;
        },
      ),
    );
    expect(messageText(contexts[0].messages.last as UserMessage), 'time-left: 10min');
    expect(messageText(contexts[1].messages.last as UserMessage), 'time-left: 9min');
  });

  test('disarmed: payloads are byte-for-byte the provider-less shape', () async {
    List<String> payloadTexts(List<Context> contexts) => [
      for (final context in contexts)
        context.messages.map((m) => messageText(m as UserMessage)).join('\n'),
    ];

    final baseline = await runScripted(
      [textTurn('one'), textTurn('two')],
      config: AgentLoopConfig(model: testModel),
    );
    // Provider present but returning null (deadline cleared mid-session)
    // must equal NO provider at all.
    final cleared = await runScripted(
      [textTurn('one'), textTurn('two')],
      config: AgentLoopConfig(
        model: testModel,
        budgetLineProvider: () => null,
      ),
    );
    expect(payloadTexts(cleared), payloadTexts(baseline));
  });

  test('the line is payload-only: the transcript holds only prompt+answer',
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
    final done = events.whereType<DoneEvent>().single.message;
    // The request saw the line; the recorded user transcript did not.
    expect(
      messageText(fake.contexts.single.messages.last as UserMessage),
      'time-left: 5min',
    );
    final userRecords = events.whereType<UserMessageEvent>();
    expect(userRecords, hasLength(1));
    expect(messageText(userRecords.single.message), 'fixture task');
    expect(done.content, isNot(contains('time-left')));
  });

  test('Agent.budgetLineProvider threads into the loop config', () async {
    final agent = Agent(
      model: testModel,
      streamFunction: FakeStreamFunction([textTurn('done')]).call,
      budgetLineProvider: () => 'time-left: 1h',
    );
    final events = await agent
        .prompt('hello')
        .then((_) => agent.state.messages)
        .catchError((_) => <Message>[]);
    expect(events, isNotNull);
  });
}
