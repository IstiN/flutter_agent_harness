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
        apiKey: '[REDACTED:Sensitive Value]',
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

  test('an oversized diagnostics log is rotated on the first write of a '
      'process', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.createDir('/home/.fah/logs', recursive: true);
    // Seed fa.log beyond the cap (the memory print sink can append
    // prompt-sized lines per memory op, so unbounded growth is real).
    await env.writeFile(
      '/home/.fah/logs/fa.log',
      'x' * (AgentCli.diagnosticLogMaxBytes + 1),
    );
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
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

    // MemoryExecutionEnv is renamable, so the production rename path runs:
    // the oversized log moves to fa.log.1 and the boot line lands in a
    // fresh fa.log.
    final rotated = await env.readTextFile('/home/.fah/logs/fa.log.1');
    expect(rotated.valueOrNull, contains('xxxx'));
    final result = await env.readTextFile('/home/.fah/logs/fa.log');
    final log = result.valueOrNull ?? '';
    expect(log, isNot(contains('xxxx')));
    expect(log, contains('fa boot'));
  });

  test('a diagnostics log under the cap is not rotated', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.createDir('/home/.fah/logs', recursive: true);
    await env.writeFile('/home/.fah/logs/fa.log', 'precious prior line\n');
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
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
    expect(log, contains('precious prior line'));
    expect(log, contains('fa boot'));
  });

  test('rotation on a backend without rename truncates the oversized log '
      'in place', () async {
    // SandboxedExecutionEnv (passthrough with a null spec) is an
    // ExecutionEnv WITHOUT the rename capability: CwdOverrideEnv reports
    // rename as notSupported, so the truncate fallback branch runs.
    final env = SandboxedExecutionEnv(MemoryExecutionEnv(cwd: '/work'), null);
    await env.createDir('/home/.fah/logs', recursive: true);
    await env.writeFile(
      '/home/.fah/logs/fa.log',
      'x' * (AgentCli.diagnosticLogMaxBytes + 1),
    );
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
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
    expect(
      log.length,
      lessThan(AgentCli.diagnosticLogMaxBytes),
      reason: 'the oversized log must not survive the truncate fallback',
    );
    expect(log, isNot(contains('xxxx')));
    expect(log, contains('fa boot'));
    final rotated = await env.exists('/home/.fah/logs/fa.log.1');
    expect(rotated.valueOrNull ?? false, isFalse);
  });
}
