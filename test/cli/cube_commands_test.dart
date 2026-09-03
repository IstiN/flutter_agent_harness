/// `/cube` command family (fa_cube Phase 1 wiring): status when off, live
/// use/switch from `.fah/cubes/`, boot-time spec status, off, list, cache
/// status, and the shell policy enforcement (a denied command never reaches
/// the inner shell and reports `fa_cube[<name>]` with exit 127).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    String? homeDir,
    Future<void> Function()? onCubeSettingsChanged,
    http.Client? cubeRegistryClient,
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
        homeDir: homeDir,
        onCubeSettingsChanged: onCubeSettingsChanged,
        cubeRegistryClient: cubeRegistryClient,
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

  group('Cube sandbox settings flow', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-cube-flow-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    /// A cli whose cube default persists to `<tmp>/.fah/config.yaml` —
    /// the same saveCliConfig round-trip bin/fah.dart's persistConfig
    /// performs for the real host.
    AgentCli persistingCli(StreamFunction streamFunction) {
      late final AgentCli cli;
      cli = cliFor(
        streamFunction,
        homeDir: tmp.path,
        onCubeSettingsChanged: () async {
          await saveCliConfig(
            tmp.path,
            CliConfig(cube: cli.config.cubeSettings),
          );
        },
      );
      return cli;
    }

    test(
      'the picker lists disabled, project manifests, presets, custom path',
      () async {
        await writeCube('dev', devCube);
        await writeCube('strict', strictCube);
        final fake = FakeStreamFunction([]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        final flow = cli.startCubeSandboxFlow();
        await waitFor(() => io.out.toString().contains('custom path...'));
        io.sendLine('2'); // dev
        await waitFor(() => io.out.toString().contains('cube: dev active'));
        await flow;
        io.sendLine('/exit');
        await run;

        final out = io.out.toString();
        expect(out, contains('cube sandbox'));
        expect(out, contains('1) disabled (full host access) — current'));
        expect(out, contains('2) dev — project cube manifest'));
        expect(out, contains('3) strict — project cube manifest'));
        // The built-in security-level presets sit between the project
        // manifests and the custom path.
        expect(out, contains('4) L1 · core apps — L1 — reads and writes'));
        expect(out, contains('5) L1 · full system apps'));
        expect(out, contains('6) L2 · core apps'));
        expect(out, contains('7) L2 · full system apps'));
        expect(out, contains('8) L3 · core apps'));
        expect(out, contains('9) L3 · full system apps'));
        expect(out, contains('10) custom path...'));
        expect(fake.calls, 0);
      },
    );

    test('picking a built-in preset applies and persists it', () async {
      final fake = FakeStreamFunction([]);
      final cli = persistingCli(fake.call);
      final run = cli.run();

      final flow = cli.startCubeSandboxFlow();
      await waitFor(() => io.out.toString().contains('custom path...'));
      io.sendLine('5'); // L2 · full system apps
      await waitFor(() => io.out.toString().contains('cube: l2-full active'));
      await flow;
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), contains('cube: l2-full active'));
      final saved = loadCliConfig(tmp.path);
      expect(saved.cube?.configPath, 'l2-full');
    });

    test(
      'picking a cube applies it live and persists the startup default',
      () async {
        await writeCube('dev', devCube);
        final fake = FakeStreamFunction([]);
        final cli = persistingCli(fake.call);
        final run = cli.run();

        final flow = cli.startCubeSandboxFlow();
        await waitFor(() => io.out.toString().contains('custom path...'));
        io.sendLine('2'); // dev
        await waitFor(() => io.out.toString().contains('cube: saved default'));
        await flow;
        io.sendLine('/exit');
        await run;

        // Live: the session sandbox now clamps to dev.
        io.sendLine('/cube');
        // Persisted: the config round-trips the new default.
        final reloaded = loadCliConfig(tmp.path);
        expect(reloaded.cube?.enabled, isTrue);
        expect(reloaded.cube?.configPath, '.fah/cubes/dev.yaml');
        expect(cli.config.cubeSettings?.configPath, '.fah/cubes/dev.yaml');
      },
    );

    test(
      'picking disabled turns the sandbox off and persists enabled: false',
      () async {
        await writeCube('dev', devCube);
        final fake = FakeStreamFunction([]);
        final cli = persistingCli(fake.call);
        final run = cli.run();

        io.sendLine('/cube use dev');
        await waitFor(() => io.out.toString().contains('cube: dev active'));
        final flow = cli.startCubeSandboxFlow();
        await waitFor(() => io.out.toString().contains('currently dev'));
        io.sendLine('1'); // disabled
        await waitFor(() => io.out.toString().contains('cube: saved default'));
        await flow;
        io.sendLine('/exit');
        await run;

        final out = io.out.toString();
        expect(out, contains('cube: off (full host access)'));
        final reloaded = loadCliConfig(tmp.path);
        expect(reloaded.cube?.enabled, isFalse);
        expect(reloaded.cube?.configPath, isNull);
      },
    );

    test('the custom path applies and persists the typed manifest', () async {
      await writeCube('dev', devCube);
      await writeCube('strict', strictCube);
      final fake = FakeStreamFunction([]);
      final cli = persistingCli(fake.call);
      final run = cli.run();

      final flow = cli.startCubeSandboxFlow();
      await waitFor(() => io.out.toString().contains('custom path...'));
      io.sendLine('10'); // custom path
      await waitFor(() => io.out.toString().contains('cube manifest path'));
      io.sendLine('.fah/cubes/dev.yaml');
      await waitFor(() => io.out.toString().contains('cube: saved default'));
      await flow;
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('cube: dev active'));
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.cube?.configPath, '.fah/cubes/dev.yaml');
    });

    test('an empty custom path cancels without persisting', () async {
      await writeCube('dev', devCube);
      await writeCube('strict', strictCube);
      final fake = FakeStreamFunction([]);
      final cli = persistingCli(fake.call);
      final run = cli.run();

      final flow = cli.startCubeSandboxFlow();
      await waitFor(() => io.out.toString().contains('custom path...'));
      io.sendLine('10'); // custom path
      await waitFor(() => io.out.toString().contains('cube manifest path'));
      io.sendLine('');
      await flow;
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), isNot(contains('saved default')));
      expect(loadCliConfig(tmp.path).cube, isNull);
    });
  });

  group('cube registry commands', () {
    final manifest = '''
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
spec:
  tools:
    allow: [curl]
''';
    final manifestSha = sha256.convert(utf8.encode(manifest)).toString();

    AgentCli registryCli(StreamFunction streamFunction, String catalog) {
      final mock = MockClient((request) async {
        if (request.url.toString() == 'https://fa1.dev/cubes/templates.json') {
          return http.Response(catalog, 200);
        }
        if (request.url.toString() ==
            'https://fa1.dev/cubes/web-scraper.yaml') {
          return http.Response(manifest, 200);
        }
        return http.Response('not found', 404);
      });
      return cliFor(streamFunction, cubeRegistryClient: mock);
    }

    test('/cube templates lists the registry catalog', () async {
      final cli = registryCli(
        FakeStreamFunction([]).call,
        '{"templates":[{"id":"web-scraper","name":"Web scraper",'
        '"description":"curl egress","file":"web-scraper.yaml",'
        '"sha256":"$manifestSha"}]}',
      );
      final run = cli.run();
      io.sendLine('/cube templates');
      await waitFor(() => io.out.toString().contains('Web scraper'));
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('cube registry (https://fa1.dev): 1 template'));
      expect(out, contains('web-scraper — Web scraper: curl egress'));
    });

    test('/cube install downloads, verifies and writes the manifest', () async {
      final cli = registryCli(
        FakeStreamFunction([]).call,
        '{"templates":[{"id":"web-scraper","name":"Web scraper",'
        '"description":"curl egress","file":"web-scraper.yaml",'
        '"sha256":"$manifestSha"}]}',
      );
      final run = cli.run();
      io.sendLine('/cube install web-scraper');
      await waitFor(
        () => io.out.toString().contains(
          'installed /work/.fah/cubes/web-scraper.yaml',
        ),
      );
      io.sendLine('/exit');
      await run;

      final read = await env.readTextFile('/work/.fah/cubes/web-scraper.yaml');
      expect(read, isA<Ok>());
      expect((read as Ok).value, manifest);
      // `/cube list` now shows it.
      io.sendLine('/cube list');
      expect(io.out.toString(), contains('web-scraper'));
    });

    test('/cube install of an unknown template prints a clean note', () async {
      final cli = registryCli(FakeStreamFunction([]).call, '{"templates":[]}');
      final run = cli.run();
      io.sendLine('/cube install no-such');
      await waitFor(() => io.out.toString().contains('no template "no-such"'));
      io.sendLine('/exit');
      await run;
    });

    test('/cube install without an id prints usage', () async {
      final cli = registryCli(FakeStreamFunction([]).call, '{"templates":[]}');
      final run = cli.run();
      io.sendLine('/cube install');
      await waitFor(
        () => io.out.toString().contains('usage: /cube install <template-id>'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/cube reload re-resolves the remembered source', () async {
      await writeCube('dev', devCube);
      final cli = cliFor(FakeStreamFunction([]).call);
      final run = cli.run();
      io.sendLine('/cube use dev');
      await waitFor(() => io.out.toString().contains('cube: dev active'));
      io.sendLine('/cube reload');
      await waitFor(() => io.out.toString().contains('cube: dev reloaded'));
      io.sendLine('/exit');
      await run;
    });

    test('a registry HTTP failure prints a clean line', () async {
      final failing = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          osName: 'linux',
          cubeRegistryClient: MockClient(
            (request) async => http.Response('boom', 500),
          ),
        ),
        io: io,
        streamFunction: FakeStreamFunction([]).call,
      );
      final run = failing.run();
      io.sendLine('/cube templates');
      await waitFor(() => io.out.toString().contains('HTTP 500'));
      io.sendLine('/exit');
      await run;
    });
  });

  test('/settings line mode prints the current cube state', () async {
    await writeCube('dev', devCube);
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('/settings');
    await waitFor(
      () => io.out.toString().contains('cube: disabled (full host access)'),
    );
    io.sendLine('/cube use dev');
    await waitFor(() => io.out.toString().contains('cube: dev active'));
    io.sendLine('/settings');
    await waitFor(() => 'cube: dev'.allMatches(io.out.toString()).length == 2);
    io.sendLine('/exit');
    await run;

    final out = io.out.toString();
    expect(out, contains('cube: disabled (full host access)'));
    expect(
      out,
      contains(
        'change via /provider, /model, /approval, /mode, '
        '/key, /mcp, /cube',
      ),
    );
  });
}
