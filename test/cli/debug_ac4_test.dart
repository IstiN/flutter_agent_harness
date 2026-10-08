import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;

Model get _model => const Model(
  id: 'test-model', api: 'test-api', provider: 'test-provider',
  baseUrl: 'https://example.test', contextWindow: _window, maxTokens: 4096,
);

void main() {
  test('debug ac4 fixed settings', timeout: const Timeout(Duration(minutes: 3)), () async {
    final io = FakeCliIO();
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    await env.writeFile('big.txt', List.filled(1000, 'x' * 24).join('\n'));
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('restore-budget-target');
    for (var i = 0; i < 11; i++) {
      await seed.appendMessage(UserMessage.text('seed$i ${'a' * 4000}'));
    }
    final stream = FakeStreamFunction([
      toolTurn([const ToolCall(id: 'c1', name: 'checkpoint', arguments: {'goal': 'detour'})]),
      textTurn('detour started'),
      textTurn('no findings yet'),
      toolTurn([const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'})]),
      toolTurn([const ToolCall(id: 'c2', name: 'checkpoint', arguments: {'goal': 'close it out'})]),
      textTurn('restore budget compaction summary'),
      textTurn('final answer after restore budget cap'),
    ]);
    final agent = AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'restore-budget-target',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
        compactionSettings: const CompactionSettings(
          enabled: true,
          reserveTokens: 8192,
          keepRecentTokens: 4096,
        ),
      ),
      io: io,
      streamFunction: stream.call,
    );
    final run = agent.run();
    io.sendLine('start the detour');
    await waitForIt(() => stream.calls >= 2 && !agent.isBusy, reason: 'run1');
    io.sendLine('any luck?');
    await waitForIt(() => stream.calls >= 3 && !agent.isBusy, reason: 'run2');
    io.sendLine('wrap it up');
    for (var i = 0; i < 3000; i++) {
      if (!agent.isBusy && stream.calls >= 7) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    print('CALLS=${stream.calls}');
    final out = io.out.toString();
    final idx = out.indexOf('wrap it up');
    print(out.substring(idx < 0 ? 0 : idx));
    io.sendLine('/exit');
    await run;
  });
}
