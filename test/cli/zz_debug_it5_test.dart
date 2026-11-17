import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'agent_cli_test_support.dart';

void main() {
  test('debug it5', timeout: const Timeout(Duration(minutes: 5)), () async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('zero-pass-receipt-target');
    await seed.appendMessage(UserMessage.text('TASK probe ${'t ' * 100}'));
    for (var i = 0; i < 40; i++) {
      await seed.appendMessage(UserMessage.text('filler$i ${'x' * 100}'));
    }
    await seed.appendMessage(AssistantMessage(
      content: const [TextContent(text: 'anchor turn')],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: const Usage(
        input: 50000, output: 5000, cacheRead: 0, cacheWrite: 0,
        totalTokens: 55000, cost: UsageCost(),
      ),
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    ));
    // What does the projection see after a full reload?
    final msgs = await seed.buildContextMessages();
    final est = estimateContextTokens(msgs);
    print('reloaded: msgs=${msgs.length} usageTokens=${est.usageTokens} '
        'tokens=${est.tokens} lastUsageIndex=${est.lastUsageIndex}');

    final io = FakeCliIO();
    var calls = 0;
    final agent = AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model', api: 'test-api', provider: 'test-provider',
          baseUrl: 'https://example.test', contextWindow: 60000,
          maxTokens: 4096,
        ),
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        sessionName: 'zero-pass-receipt-target',
        homeDir: '/home',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionSettings: const CompactionSettings(
          enabled: true, reserveTokens: 15000, keepRecentTokens: 750,
        ),
      ),
      io: io,
      streamFunction: (m, c, {cancelToken}) {
        calls++;
        final system = c.systemPrompt ?? '';
        final reply = system.contains('context-hygiene judge')
            ? '[]'
            : (system.contains('checkpoint') || calls > 2)
                ? 'CHECKPOINT: folded summary.'
                : 'ok';
        final full = AssistantMessage(
          content: [TextContent(text: reply)],
          api: 'test-api', provider: 'test-provider', model: 'test-model',
          usage: Usage.zero, stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        );
        final s = AssistantMessageEventStream()
          ..push(StartEvent(partial: full))
          ..push(DoneEvent(reason: StopReason.stop, message: full))
          ..end();
        return s;
      },
    );
    final run = agent.run();
    io.sendLine('go');
    for (var i = 0; i < 5000; i++) {
      if (!agent.isBusy) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    io.sendLine('/stats');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    io.sendLine('/exit');
    await run;
    final log = (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull;
    print('=== COMPACT LINES ===');
    for (final l in (log ?? '').split('\n')) {
      if (l.contains('auto-compact') || l.contains('compact')) print(l);
    }
    print('calls=$calls');
    print('=== IO TAIL ===');
    print(io.out.toString().split('\n').where((l) => l.toLowerCase().contains('token') || l.toLowerCase().contains('context') || l.toLowerCase().contains('%')).join('\n'));
  });
}
