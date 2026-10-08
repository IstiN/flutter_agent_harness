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
  }) async {
    final fake = FakeStreamFunction(turns);
    final stream = agentLoop(
      prompts: [UserMessage.text('fixture task')],
      context: const Context(messages: []),
      config: AgentLoopConfig(model: testModel, finalizeGate: finalizeGate),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('ok'),
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
      final events = await runTurns([textTurn(ledgerText)], finalizeGate: true);
      final types = events.map((event) => event.runtimeType).toList();
      expect(types.last, AgentEndEvent);
      expect(types[types.length - 2], TaskLedgerEvent);
    },
  );

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
}
