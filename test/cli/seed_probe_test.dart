import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  test('probe the exact failing seed', () async {
    final io = FakeCliIO();
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('bench-trigger-target');
    await seed.appendMessage(
      UserMessage.text('TASK build the mips interpreter; keep the ledger obligations; ${'task ' * 120}'),
    );
    await seed.appendCustomEntry(
      customType: obligationsLedgerRecordType,
      data: [
        {
          'id': 'obl-test-1',
          'kind': 'owner-rule',
          'text': 'always run the full test suite before pushing',
          'sourceRecordId': 'rec-1',
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'status': 'open',
        },
      ],
    );
    await seed.appendMessage(
      AssistantMessage(
        content: [const ToolCall(id: 'call-seed-1', name: 'read', arguments: {})],
        api: 'test-api', provider: 'test-provider', model: 'test-model',
        usage: Usage.zero, stopReason: StopReason.toolUse, timestamp: DateTime.utc(2026),
      ),
    );
    await seed.appendMessage(
      ToolResultMessage(
        toolCallId: 'call-seed-1', toolName: 'read',
        content: [const TextContent(text: 'latest seed tool result')],
        isError: false, timestamp: DateTime.utc(2026),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await seed.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
    }
    final stream = FakeStreamFunction([textTurn('a1'), textTurn('a2'), textTurn('a3')]);
    final agent = AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model', api: 'test-api', provider: 'test-provider',
          baseUrl: 'https://example.test', contextWindow: 32768, maxTokens: 4096,
        ),
        apiKey: 'k',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'bench-trigger-target',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      environment: {'FAH_COMPACT_TRIGGER_TOKENS': '6000'},
      streamFunction: stream.call,
    );
    final run = agent.run();
    io.sendLine('go');
    for (var i = 0; i < 2000 && !(stream.calls >= 1 && !agent.isBusy); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // ignore: avoid_print
    print('calls after turn1: ${stream.calls}');
    final first = stream.contexts.first;
    // ignore: avoid_print
    print('first request msgs: ${first.messages.length}');
    var chars = 0;
    for (final m in first.messages) {
      final t = m is UserMessage ? messageText(m) : '';
      chars += t.length;
      // ignore: avoid_print
      print('  ${m.role}: ${t.length} :: ${t.substring(0, t.length > 50 ? 50 : t.length)}');
    }
    // ignore: avoid_print
    print('total user chars: $chars');
    // ignore: avoid_print
    print('IO OUT: ${io.out.toString().substring(0, io.out.toString().length > 2000 ? 2000 : io.out.toString().length)}');
    io.sendLine('/exit');
    await run;
  });
}
