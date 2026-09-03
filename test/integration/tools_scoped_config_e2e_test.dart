/// Scoped `tools:` config end-to-end (issue #19 AC6–AC9, fakes only):
/// global (`~/.fah/config.yaml` via [AgentCliConfig.homeDir]), project
/// (`<cwd>/.fah/config.yaml`), and session (`tools.yaml` next to the
/// session file) scopes stack with deepest-wins precedence; `/tools
/// reload` picks up file edits; a broken project file keeps the last good
/// resolution with one warning and recovers once fixed; session overrides
/// never leak into global/project files.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  Future<AgentCli> boot({
    String? sessionName,
    String sessionRoot = '/sessions-a',
    FakeCliIO? cliIo,
  }) {
    final fake = FakeStreamFunction([textTurn('one'), textTurn('two')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: sessionRoot,
        sessionName: sessionName,
        homeDir: '/home/u',
        webSearchConfig: WebSearchConfig(),
        providerKind: 'openai-completions',
      ),
      io: cliIo ?? io,
      streamFunction: fake.call,
    );
    return Future.value(cli);
  }

  Set<String> offeredTools(AgentCli cli) =>
      cli.agent.state.tools.map((tool) => tool.name).toSet();

  /// Local poller: waits for a NEW occurrence of [expected] on [target]
  /// (the string may already be in the transcript from an earlier command).
  Future<void> settleOn(FakeCliIO target, String line, String expected) async {
    int count(String out) => expected.allMatches(out).length;
    final before = count(target.out.toString());
    target.sendLine(line);
    for (var i = 0; i < 300; i++) {
      if (count(target.out.toString()) > before) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for: $expected');
  }

  Future<void> settle(String line, String expected) =>
      settleOn(io, line, expected);

  /// Deterministically waits out the unawaited boot resolution.
  Future<void> bootSettled() =>
      settle('/tools reload', 'availability reloaded');

  test('scopes stack deepest-wins per key (AC6)', () async {
    await env.writeFile(
      '/home/u/.fah/config.yaml',
      'provider: x\ntools:\n  web_search: false\n',
    );
    await env.writeFile('/work/.fah/config.yaml', 'tools:\n  bash: false\n');
    final cli = await boot();
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa>'));

    final tools = offeredTools(cli);
    expect(
      tools,
      isNot(contains('web_search')),
      reason: 'global off wins (project silent)',
    );
    expect(tools, isNot(contains('bash')), reason: 'project off wins');
    expect(tools, contains('edit'));

    io.sendLine('/exit');
    await run;
  });

  test('removing a deeper key falls back after /tools reload (AC7)', () async {
    await env.writeFile('/work/.fah/config.yaml', 'tools:\n  bash: false\n');
    final cli = await boot();
    final run = cli.run();
    await bootSettled();
    expect(offeredTools(cli), isNot(contains('bash')));

    await env.writeFile('/work/.fah/config.yaml', 'memory: kept\n');
    await settle('/tools reload', 'availability reloaded');
    expect(offeredTools(cli), contains('bash'));

    io.sendLine('/exit');
    await run;
  });

  test('broken project yaml keeps the last good resolution and recovers '
      '(AC8)', () async {
    await env.writeFile('/work/.fah/config.yaml', 'tools:\n  bash: false\n');
    final cli = await boot();
    final run = cli.run();
    await bootSettled();
    expect(offeredTools(cli), isNot(contains('bash')));

    // Break the file: the project scope is skipped with one warning, the
    // resolution keeps the previously resolved state (bash still off).
    await env.writeFile('/work/.fah/config.yaml', 'tools: [broken\n');
    final outBefore = io.out.toString();
    await settle('/tools reload', 'availability reloaded');
    expect(
      io.out.toString().substring(outBefore.length),
      contains('project scope'),
    );
    expect(offeredTools(cli), isNot(contains('bash')));

    // Fix it: the new section applies.
    await env.writeFile('/work/.fah/config.yaml', 'tools:\n  ls: false\n');
    await settle('/tools reload', 'availability reloaded');
    expect(offeredTools(cli), contains('bash'));
    expect(offeredTools(cli), isNot(contains('ls')));

    io.sendLine('/exit');
    await run;
  });

  test('a session override does not leak across sessions or into the '
      'global/project files (AC9)', () async {
    const globalYaml = 'tools:\n  web_search: false\n';
    const projectYaml = 'tools:\n  bash: true\n';
    await env.writeFile('/home/u/.fah/config.yaml', globalYaml);
    await env.writeFile('/work/.fah/config.yaml', projectYaml);

    // Session A: disable ls in the session scope.
    final ioA = FakeCliIO();
    final cliA = await boot(
      sessionName: 'alpha',
      sessionRoot: '/sessions-a',
      cliIo: ioA,
    );
    final runA = cliA.run();
    Future<void> settleA(String line, String expected) =>
        settleOn(ioA, line, expected);
    await settleA('/tools reload', 'availability reloaded');
    expect(offeredTools(cliA), contains('ls'));
    await settleA('/tools disable ls session', 'disabled ls (scope: session)');
    expect(offeredTools(cliA), isNot(contains('ls')));
    ioA.sendLine('/exit');
    // Bound the exit lifecycle (see mcp_disable_runtime_test.dart).
    await runA.timeout(const Duration(seconds: 5), onTimeout: () {});

    // Session B: a NEW session in the SAME session root and workspace —
    // session scope files are per-session (.tools/<sessionId>.yaml), so
    // A's override must not apply here.
    final ioB = FakeCliIO();
    final cliB = await boot(
      sessionName: 'beta',
      sessionRoot: '/sessions-a',
      cliIo: ioB,
    );
    final runB = cliB.run();
    Future<void> settleB(String line, String expected) =>
        settleOn(ioB, line, expected);
    await settleB('/tools reload', 'availability reloaded');
    final tools = offeredTools(cliB);
    expect(tools, contains('ls'), reason: 'session A override must not leak');
    expect(
      tools,
      isNot(contains('web_search')),
      reason: 'the global scope still applies',
    );
    ioB.sendLine('/exit');
    // Bound the exit lifecycle (background timers keep the zone alive).
    await runB.timeout(const Duration(seconds: 5), onTimeout: () {});

    // Session A's override file is keyed by ITS session id only.
    final cwdDir = (await env.listDir('/sessions-a')).valueOrNull!.single.path;
    final dotTools = (await env.listDir('$cwdDir/.tools')).valueOrNull!;
    expect(dotTools, hasLength(1), reason: 'one scope file: session A');
    expect(dotTools.single.name, endsWith('.yaml'));
    expect(
      (await env.readTextFile(dotTools.single.path)).valueOrNull,
      contains('ls: false'),
    );

    // The persisted scope files are untouched by session toggles.
    expect(
      (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
      globalYaml,
    );
    expect(
      (await env.readTextFile('/work/.fah/config.yaml')).valueOrNull,
      projectYaml,
    );
  });
}
