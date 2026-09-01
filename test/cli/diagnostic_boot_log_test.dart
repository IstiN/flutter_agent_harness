import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The boot marker in the shared diagnostics log: every wedge post-mortem
/// starts with "which BUILD held the busy row?" — parallel fa processes
/// share `~/.fah/logs/fa.log`, so the first lifecycle line must name the
/// version next to the session id.
void main() {
  test('boot writes version + session id to the diagnostics log', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
      version: '9.9.9-test',
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('/exit');
    await run;

    final result = await env.readTextFile('/home/.fah/logs/fa.log');
    final log = result.valueOrNull ?? '';
    final boot = log
        .split('\n')
        .where((line) => line.contains('fa boot'))
        .toList();
    expect(boot, hasLength(1), reason: 'exactly one boot line per process');
    expect(boot.single, contains('version=9.9.9-test'));
    expect(
      boot.single,
      contains(RegExp(r'sid=[0-9a-f]{8}')),
      reason: 'the boot line names its session like every lifecycle line',
    );
  });
}
