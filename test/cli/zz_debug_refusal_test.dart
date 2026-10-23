import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Future<void> main() async {
  test('debug: what actually happens on a refused turn', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final store = FakeSecureKeyStore()..map['KIMI_API_KEY'] = 'kimi-key';
    final cache = SecureKeyCache(store);
    final fake = FakeStreamFunction([
      textTurn('should-never-run'),
      textTurn('should-never-run-2'),
      textTurn('should-never-run-3'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'kimi-for-coding',
          api: 'openai-completions',
          provider: 'copilot',
          baseUrl: 'https://api.enterprise.githubcopilot.com',
          contextWindow: 1000000,
          maxTokens: 32768,
        ),
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: (name) => store.map[name],
        envVarIsSet: (name) => store.map.containsKey(name),
        secureKeys: cache,
        providerKind: 'copilot',
        catalogStreamOverride: (kind, key) => fake.call,
      ),
      io: io,
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('hello');
    for (var i = 0; i < 2000; i++) {
      if (!cli.isBusy) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('=== after first settle: fake.calls=${fake.calls} ===');
    // ignore: avoid_print
    print(io.out.toString());
    // ignore: avoid_print
    print('=== transcript ===');
    for (final m in cli.agent.state.messages) {
      // ignore: avoid_print
      print(
        '$m',
      );
    }
    io.sendLine('/exit');
    await run;
    await io.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
