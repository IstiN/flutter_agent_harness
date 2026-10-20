import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  test('debug: call trace of the learned-cap heal', timeout: const Timeout(Duration(seconds: 120)), () async {
    final tempHome = Directory.systemTemp.createTempSync('fa_dbg_');
    final env = MemoryExecutionEnv(cwd: '/work');
    env.writeFile('note.txt', 'small note\n');
    final io = FakeCliIO();
    const model = Model(id: 'cap-model', api: 'test-api', provider: 'test-provider', baseUrl: 'https://example.test', contextWindow: 1000000, maxTokens: 4096);
    List<AssistantMessageEvent> refusal(String error) {
      final msg = testAssistant(stopReason: StopReason.error, errorMessage: error);
      return [StartEvent(partial: msg), ErrorEvent(reason: StopReason.error, error: msg)];
    }
    final turns = <List<AssistantMessageEvent>>[
      for (var i = 1; i <= 8; i++)
        toolTurn([ToolCall(id: 't$i', name: 'read', arguments: {'path': 'note.txt'})]),
      refusal('400 messages: array length 25 exceeds limit 24'),
      textTurn('summary of the earlier notes'),
      textTurn('recovered — task complete'),
    ];
    final fake = FakeStreamFunction(turns);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'k',
        env: env,
        homeDir: tempHome.path,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        compactionEngine: CompactionEngine.classic,
        compactionSettings: const CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 200),
      ),
      io: io,
      streamFunction: fake.call,
    );
    final exitCode = await cli.runHeadless('read the notes');
    await io.close();
    stderr.writeln('exit=$exitCode calls=${fake.calls}');
    for (var i = 0; i < fake.contexts.length; i++) {
      final msgs = fake.contexts[i].messages;
      final kinds = msgs.map((m) {
        if (m is UserMessage) return 'user';
        if (m is AssistantMessage) return 'asst(${m.stopReason.name})';
        return m.runtimeType.toString();
      }).toList();
      stderr.writeln('call $i: ${msgs.length} msgs: $kinds');
    }
    stderr.writeln('--- output ---');
    stderr.writeln(io.out.toString());
    tempHome.deleteSync(recursive: true);
  });
}
