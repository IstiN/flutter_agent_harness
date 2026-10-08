import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'support/scripted_stream_harness.dart';

void main() {
  test('probe: terminate result ends run — what events?', () async {
    const ledgerText = '''
Task complete.
\`\`\`task-ledger
- requirement: r
  status: pass
\`\`\`
''';
    final partial = testAssistant(
      content: [
        TextContent(text: ledgerText),
        ToolCall(id: 't1', name: 'bash', arguments: const {}),
      ],
      stopReason: StopReason.toolUse,
    );
    final events = await agentLoop(
      prompts: [UserMessage.text('fixture task')],
      context: const Context(messages: []),
      config: AgentLoopConfig(model: testModel, finalizeGate: true),
      streamFunction: FakeStreamFunction([
        [
          StartEvent(partial: testAssistant()),
          ToolCallStartEvent(contentIndex: 1, partial: testAssistant()),
          ToolCallEndEvent(
            contentIndex: 1,
            toolCall: ToolCall(id: 't1', name: 'bash', arguments: const {}),
            partial: partial,
          ),
          DoneEvent(reason: StopReason.toolUse, message: partial),
        ],
      ]).call,
      toolExecutor: (_, _, _) async =>
          ToolExecutionResult.text('done', terminate: true),
    ).toList();
    for (final e in events) {
      // ignore: avoid_print
      print('EVENT ${e.runtimeType}');
    }
  });
}
