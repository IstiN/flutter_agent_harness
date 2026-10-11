import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../support/scripted_stream_harness.dart';

/// gh-1412: the loop parses the FinalizeGate ledger out of the run's final
/// assistant message and emits [TaskLedgerEvent] — but only when the run's
/// config opted in ([AgentLoopConfig.finalizeGate], the unattended/bench
/// flag). AC2's engine half: the record the hosts persist exists as an
/// event by the time the run ends.
void main() {
  AssistantMessage assistant(List<ContentBlock> content) => AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );

  List<AssistantMessageEvent> textTurn(String text) {
    final empty = testAssistant();
    final partial = assistant([TextContent(text: text)]);
    return [
      StartEvent(partial: empty),
      TextStartEvent(contentIndex: 0, partial: empty),
      TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
      DoneEvent(reason: StopReason.stop, message: partial),
    ];
  }

  List<AssistantMessageEvent> toolTurn(List<ToolCall> calls) {
    final empty = testAssistant();
    final partial = AssistantMessage(
      content: calls,
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.toolUse,
      timestamp: DateTime.utc(2026),
    );
    final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
    for (var i = 0; i < calls.length; i++) {
      events
        ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
        ..add(
          ToolCallEndEvent(
            contentIndex: i,
            toolCall: calls[i],
            partial: partial,
          ),
        );
    }
    events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
    return events;
  }

  const ledgerText = '''
Task complete.
```task-ledger
- requirement: create script.py
  command: test -f script.py
  expected: exit 0
  actual: exit 0
  status: pass
- requirement: script.py is executable
  command: test -x script.py
  expected: exit 0
  actual: exit 1
  status: fixed
```
''';

  Future<List<AgentEvent>> runTurns(
    List<List<AssistantMessageEvent>> turns, {
    required bool finalizeGate,
    ToolExecutor? toolExecutor,
    List<Tool>? tools,
  }) async {
    final fake = FakeStreamFunction(turns);
    final stream = agentLoop(
      prompts: [UserMessage.text('fixture task')],
      context: Context(messages: const [], tools: tools),
      config: AgentLoopConfig(model: testModel, finalizeGate: finalizeGate),
      streamFunction: fake.call,
      toolExecutor:
          toolExecutor ?? (_, _, _) async => ToolExecutionResult.text('ok'),
    );
    return stream.toList();
  }

  test(
    'finalizeGate on + ledger in the final answer emits TaskLedgerEvent',
    () async {
      final events = await runTurns([
        toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]),
        textTurn(ledgerText),
      ], finalizeGate: true);
      final ledgerEvents = events.whereType<TaskLedgerEvent>().toList();
      expect(ledgerEvents, hasLength(1));
      final ledger = ledgerEvents.single.ledger;
      expect(ledger.items, hasLength(2));
      expect(ledger.verifiedCount, 2);
      expect(ledger.items[1].status, TaskLedgerItemStatus.fixed);
    },
  );

  test(
    'the event lands after the final message and before agent end',
    () async {
      final events = await runTurns([
        toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]),
        textTurn(ledgerText),
      ], finalizeGate: true);
      final types = events.map((event) => event.runtimeType).toList();
      expect(types.last, AgentEndEvent);
      expect(types[types.length - 2], TaskLedgerEvent);
    },
  );

  test('gh-1516: a produced-state turn emits the event AND strips the ledger '
      'from the final message (the transcript never shows it)', () async {
    final events = await runTurns([
      toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]),
      textTurn(ledgerText),
    ], finalizeGate: true);
    expect(events.whereType<TaskLedgerEvent>(), hasLength(1));
    final end = events.whereType<AgentEndEvent>().single;
    final lastAssistant =
        end.messages.lastWhere((message) => message is AssistantMessage)
            as AssistantMessage;
    final text = lastAssistant.content.whereType<TextContent>().map((block) {
      return block.text;
    }).join();
    expect(text, isNot(contains('task-ledger')));
    expect(text, isNot(contains('```')));
    expect(text, contains('Task complete.'));
  });

  test('gh-1516 review: the MessageEndEvent itself already carries the '
      'stripped message — hosts persist/render the event payload, so the '
      'strip must land BEFORE it, not at end-of-run', () async {
    final events = await runTurns([
      toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]),
      textTurn(ledgerText),
    ], finalizeGate: true);
    final messageEnds = events.whereType<MessageEndEvent>().toList();
    final assistantEnds = [
      for (final event in messageEnds)
        if (event.message is AssistantMessage)
          event.message as AssistantMessage,
    ];
    expect(assistantEnds, isNotEmpty);
    final text = assistantEnds.last.content.whereType<TextContent>().map((
      block,
    ) {
      return block.text;
    }).join();
    expect(text, isNot(contains('task-ledger')));
    expect(text, isNot(contains('```')));
    expect(text, contains('Task complete.'));
  });

  test('gh-1516: a trivial turn (no tool calls, pure Q&A) does not fire the '
      'gate — no event — and an over-eager ledger is still stripped', () async {
    final events = await runTurns([textTurn(ledgerText)], finalizeGate: true);
    // No produced state ⇒ nothing to verify ⇒ the gate does not fire.
    expect(events.whereType<TaskLedgerEvent>(), isEmpty);
    // …but the transcript must never show the ledger either way.
    final end = events.whereType<AgentEndEvent>().single;
    final lastAssistant =
        end.messages.lastWhere((message) => message is AssistantMessage)
            as AssistantMessage;
    final text = lastAssistant.content.whereType<TextContent>().map((block) {
      return block.text;
    }).join();
    expect(text, isNot(contains('task-ledger')));
    expect(text, contains('Task complete.'));
  });

  test('gh-1516: the unfenced near-miss ledger shape fires the gate and is '
      'stripped from the final message', () async {
    const unfenced = '''
Task complete.
## task-ledger
- requirement: create script.py
  command: test -f script.py
  expected: exit 0
  actual: exit 0
  status: pass
''';
    final events = await runTurns([
      toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]),
      textTurn(unfenced),
    ], finalizeGate: true);
    final ledgerEvents = events.whereType<TaskLedgerEvent>().toList();
    expect(ledgerEvents, hasLength(1));
    expect(
      ledgerEvents.single.ledger.items.single.requirement,
      'create script.py',
    );
    final end = events.whereType<AgentEndEvent>().single;
    final lastAssistant =
        end.messages.lastWhere((message) => message is AssistantMessage)
            as AssistantMessage;
    final text = lastAssistant.content.whereType<TextContent>().map((block) {
      return block.text;
    }).join();
    expect(text, isNot(contains('task-ledger')));
    expect(text.trimRight(), 'Task complete.');
  });

  test(
    'finalizeGate off: no TaskLedgerEvent even with a ledger present',
    () async {
      final events = await runTurns([
        textTurn(ledgerText),
      ], finalizeGate: false);
      expect(events.whereType<TaskLedgerEvent>(), isEmpty);
    },
  );

  test(
    'finalizeGate on + no ledger in the answer: no event (degrades clean)',
    () async {
      final events = await runTurns([
        textTurn('plain answer, no ledger'),
      ], finalizeGate: true);
      expect(events.whereType<TaskLedgerEvent>(), isEmpty);
    },
  );

  test(
    'a run that ends on tool calls without a final answer emits nothing',
    () async {
      final events = await runTurns([
        toolTurn([ToolCall(id: 't1', name: 'bash', arguments: const {})]),
      ], finalizeGate: true);
      // The run ends with tool results as the last messages; no assistant
      // ledger answer ever arrived.
      expect(events.whereType<TaskLedgerEvent>(), isEmpty);
    },
  );

  test('a ledger quoted in an earlier turn never satisfies the gate when the '
      'run ends on tool calls (gh-1412 review)', () async {
    // Over-eager contract compliance: the model quotes its ledger
    // MID-RUN (text + a tool call in the same turn), then the run ends
    // on the tool batch (a terminate:true result ends the loop with the
    // tool results as the last messages). That ledger describes state
    // the subsequent tool activity may have changed — only a TERMINAL
    // answer satisfies the gate.
    const bashTool = Tool(name: 'bash', description: 'shell', parameters: {});
    final events = await runTurns(
      [
        [
          StartEvent(partial: testAssistant()),
          TextStartEvent(contentIndex: 0, partial: testAssistant()),
          TextDeltaEvent(
            contentIndex: 0,
            delta: ledgerText,
            partial: testAssistant(content: [TextContent(text: ledgerText)]),
          ),
          ToolCallStartEvent(contentIndex: 1, partial: testAssistant()),
          ToolCallEndEvent(
            contentIndex: 1,
            toolCall: ToolCall(id: 't1', name: 'bash', arguments: const {}),
            partial: testAssistant(
              content: [
                TextContent(text: ledgerText),
                ToolCall(id: 't1', name: 'bash', arguments: const {}),
              ],
              stopReason: StopReason.toolUse,
            ),
          ),
          DoneEvent(
            reason: StopReason.toolUse,
            message: testAssistant(
              content: [
                TextContent(text: ledgerText),
                ToolCall(id: 't1', name: 'bash', arguments: const {}),
              ],
              stopReason: StopReason.toolUse,
            ),
          ),
        ],
      ],
      finalizeGate: true,
      toolExecutor: (_, _, _) async {
        return ToolExecutionResult.text('done', terminate: true);
      },
      tools: const [bashTool],
    );
    expect(events.whereType<TaskLedgerEvent>(), isEmpty);
  });
}
