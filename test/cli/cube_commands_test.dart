/// `/cube` command family (fa_cube Phase 1 wiring): status when off, live
/// use/switch from `.fah/cubes/`, boot-time spec status, off, list, cache
/// status, and the shell policy enforcement (a denied command never reaches
/// the inner shell and reports `fa_cube[<name>]` with exit 127).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  const devCube = '''
apiVersion: fa/v1
kind: Cube
metadata:
  name: dev
  description: dev sandbox
spec:
  tools:
    allow: [ls, echo]
''';

  const strictCube = '''
apiVersion: fa/v1
kind: Cube
metadata:
  name: strict
spec:
  tools:
    allow: [ls]
''';

  /// Writes a cube manifest under `<cwd>/.fah/cubes/`.
  Future<void> writeCube(String name, String yaml) async {
    await env.writeFile('/work/.fah/cubes/$name.yaml', yaml);
  }

  AgentCli cliFor(
    StreamFunction streamFunction, {
    ExecutionEnv? envOverride,
    CubeSpec? cubeSpec,
    String? cubeSource,
    String? osName = 'linux',
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: envOverride ?? env,
        sessionRoot: '/sessions',
        cubeSpec: cubeSpec,
        cubeSource: cubeSource,
        osName: osName,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// Polls an async condition (REPL output arrives off-thread).
  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 200; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for condition');
  }

  test('/cube when off reports full host access', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube');
    await waitFor(() => io.out.toString().contains('cube:'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('cube: disabled (full host access)'));
  });

  test(
    '/cube use applies a named cube and status shows its policies',
    () async {
      await writeCube('dev', devCube);
      final fake = FakeStreamFunction([]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      io.sendLine('/cube use dev');
      io.sendLine('/cube');
      await waitFor(() => io.out.toString().contains('tools allow:'));
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('cube: dev active'));
      expect(out, contains('cube: dev — dev sandbox'));
      expect(out, contains('backend: '));
      expect(out, contains('tools allow: echo, ls'));
      expect(out, contains('network allow: (none — all network denied)'));
      expect(out, contains('cache:'));
    },
  );

  test('/cube status at boot shows the spec passed via config', () async {
    const spec = CubeSpec(name: 'booted', description: 'from the config');
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call, cubeSpec: spec);
    final run = cli.run();
    io.sendLine('/cube');
    await waitFor(() => io.out.toString().contains('booted'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('cube: booted — from the config'));
  });

  test('/cube off restores full host access', () async {
    await writeCube('dev', devCube);
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube use dev');
    io.sendLine('/cube off');
    io.sendLine('/cube');
    await waitFor(() => io.out.toString().contains('cube: off'));
    io.sendLine('/exit');
    await run;
    final out = io.out.toString();
    expect(out, contains('cube: dev active'));
    expect(out, contains('cube: off (full host access)'));
    expect(out, contains('cube: disabled (full host access)'));
  });

  test('/cube use of a missing cube prints the resolver error', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube use nope');
    await waitFor(() => io.out.toString().contains('cube: file not found'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('cube: file not found'));
  });

  test('/cube list shows the project manifests', () async {
    await writeCube('dev', devCube);
    await writeCube('strict', strictCube);
    await env.writeFile('/work/.fah/cubes/notes.txt', 'not a cube');
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube list');
    await waitFor(() => io.out.toString().contains('strict'));
    io.sendLine('/exit');
    await run;
    final out = io.out.toString();
    expect(out, contains('  dev'));
    expect(out, contains('  strict'));
    expect(out, isNot(contains('notes')));
  });

  test('/cube cache status without a cube says none is active', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube cache status');
    await waitFor(() => io.out.toString().contains('no cube active'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('cube: no cube active'));
  });

  test('/cube cache clear works while a cube is active', () async {
    await writeCube('dev', devCube);
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube use dev');
    io.sendLine('/cube cache clear');
    await waitFor(() => io.out.toString().contains('cube cache cleared'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('cube cache cleared'));
  });

  test('an unknown /cube subcommand prints usage', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/cube bogus');
    await waitFor(() => io.out.toString().contains('usage: /cube'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('usage: /cube'));
  });

  test(
    'a denied command never reaches the shell and reports fa_cube',
    () async {
      final shell = FakeShell(stdout: 'inner-shell-ran');
      final guardedEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
      await guardedEnv.writeFile('/work/.fah/cubes/dev.yaml', devCube);
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: const {'command': 'git push'},
          ),
        ]),
        textTurn('done'),
      ]);
      final cli = cliFor(fake.call, envOverride: guardedEnv);
      final run = cli.run();
      io.sendLine('/cube use dev');
      io.sendLine('go');
      await waitFor(() => fake.calls == 2 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      // The inner shell was never reached — the policy layer denied it.
      expect(shell.commands, isEmpty);
      // The denial feeds back to the model as a `fa_cube[<name>]` tool error.
      final result = fake.contexts[1].messages
          .whereType<ToolResultMessage>()
          .single;
      expect(result.isError, isTrue);
      final text = result.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
      expect(text, contains('fa_cube[dev]'));
      expect(text, contains('127'));
    },
  );
}
