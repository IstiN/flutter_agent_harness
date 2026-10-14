import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../test/cli/agent_cli_test_support.dart';

/// Probe: how many requests does the IT-4 exhaustion shape make?
void main() {
  test('probe IT-4 request count', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final emptyTurn = [
      DoneEvent(reason: StopReason.stop, message: testAssistant()),
    ];
    final truncatedToolCallTurn = toolTurn([
      const ToolCall(
        id: 'c1',
        name: 'bash',
        arguments: {'command': 'python3 - <<"unsigned long N = strtoull'},
      ),
    ]);
    final stream = FakeStreamFunction([
      truncatedToolCallTurn,
      emptyTurn,
      emptyTurn,
      emptyTurn,
      emptyTurn,
      textTurn('fresh answer'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'k',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        emptyHiccupBaseDelay: Duration.zero,
      ),
      io: io,
      streamFunction: stream.call,
    );
    final run = cli.run();
    io.sendLine('do the task');
    for (var i = 0; i < 400; i++) {
      if (stream.calls >= 5 && !cli.isBusy) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final buf = StringBuffer();
    buf.writeln('CALLS after first settle: ${stream.calls}');
    for (var i = 0; i < stream.contexts.length; i++) {
      final roles = [
        for (final m in stream.contexts[i].messages)
          '${m.role}(${_brief(m)})',
      ];
      buf.writeln('req#$i: $roles');
    }
    // ignore: avoid_print
    print(buf);
    io.sendLine('/exit');
    await run;
    expect(stream.calls, greaterThan(0));
  });
}

String _brief(Message m) {
  if (m is AssistantMessage) return 'stop=${m.stopReason.name}';
  if (m is ToolResultMessage) return 'tool=${m.toolName}';
  if (m is UserMessage) {
    final c = m.content;
    return 'text=${c is String ? c.substring(0, c.length.clamp(0, 20)) : "blocks"}';
  }
  return '';
}
