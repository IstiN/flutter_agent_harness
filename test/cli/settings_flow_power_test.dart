import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A runner that records acquisitions without spawning anything — the
/// test-runtime stand-in for `hostPowerRunner` (no real caffeinate).
class FakePowerRunner implements PowerAssertionRunner {
  final acquisitions = <PowerAssertionOptions>[];
  final handles = <FakePowerHandle>[];

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    acquisitions.add(options);
    final handle = FakePowerHandle();
    handles.add(handle);
    return handle;
  }
}

class FakePowerHandle implements PowerAssertionHandle {
  var released = 0;

  @override
  String get description => 'fake-caffeinate -i';

  @override
  bool get held => released == 0;

  @override
  Future<void> release() async => released++;
}

/// The interactive `power:` settings flow (issue #397) — split out of
/// settings_flow_test.dart to keep that file under the repo's
/// 2800-line gate.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    String? homeDir,
    PowerAssertionLevel? powerSleepPrevention,
    PowerAssertionHold? powerSleepPreventionHold,
    PowerAssertionRunner? powerRunner,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      homeDir: homeDir,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      powerSleepPrevention: powerSleepPrevention ?? PowerAssertionLevel.idle,
      powerSleepPreventionHold:
          powerSleepPreventionHold ?? PowerAssertionHold.perRun,
      powerRunner: powerRunner,
    ),
    io: io,
    streamFunction: streamFunction,
  );
  group('power settings flow (issue #397)', () {
    Future<void> seed(String text) =>
        env.writeFile('/home/u/.fah/config.yaml', text);

    test(
      'AC1: hub picker row and line-mode summary carry the effective value',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          homeDir: '/home/u',
          powerSleepPrevention: PowerAssertionLevel.display,
        );
        final run = cli.run();

        io.sendLine('/settings');
        await waitForIt(() => io.out.toString().contains('power:'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(
          output,
          contains('power: display · per-run · no runner on this host'),
        );
        final row = cli.settingsHubItems().firstWhere(
          (item) => item.key == 'power',
        );
        expect(row.label, 'Power');
        expect(row.description, 'display · per-run · no runner on this host');
        expect(
          cli.settingsPickerHandlerKeysForTest(),
          contains('power'),
          reason: 'a hub row without a handler is a dead menu entry',
        );
        expect(fake.calls, 0);
      },
    );

    test(
      'AC2: level and hold round-trip every field; other sections intact',
      () async {
        await seed(
          'provider: openrouter\nmodel: m1\npower:\n'
          '  sleepPrevention: off\n  hold: per-run\nmemory:\n'
          '  projectPath: ./mem\n',
        );
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startPowerFlow();
        await waitForIt(
          () => io.out.toString().contains('Sleep prevention level'),
        );
        io.sendLine('1'); // the level
        await waitForIt(
          () => io.out.toString().contains(
            'sleepPrevention off|idle|display|system (empty keeps',
          ),
        );
        io.sendLine('display');
        await waitForIt(
          () => io.out.toString().contains('power.sleepPrevention = display'),
        );
        io.sendLine('2'); // the hold toggle: per-run → session
        await waitForIt(
          () => io.out.toString().contains('power.hold = session'),
        );
        io.sendLine('3'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        // Surgical: everything outside the power block is byte-identical.
        expect(written!, startsWith('provider: openrouter\nmodel: m1\npower:'));
        expect(written, endsWith('memory:\n  projectPath: ./mem\n'));
        // The real boot parser re-reads the file.
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        expect(
          parsed.powerSleepPrevention,
          PowerAssertionLevel.display,
          reason: 'the level answer landed',
        );
        expect(
          parsed.powerHold,
          PowerAssertionHold.session,
          reason: 'the hold toggle landed',
        );
        expect(fake.calls, 0);
      },
    );

    test(
      'AC3: the write re-arms the live assertion and names when it lands',
      () async {
        await seed(
          'provider: openrouter\npower:\n'
          '  sleepPrevention: idle\n  hold: session\n',
        );
        final runner = FakePowerRunner();
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          homeDir: '/home/u',
          powerSleepPreventionHold: PowerAssertionHold.session,
          powerRunner: runner,
        );
        final run = cli.run();
        await waitForIt(
          () => runner.acquisitions.isNotEmpty,
          reason: 'the session hold acquires at boot',
        );

        final flow = cli.startPowerFlow();
        await waitForIt(
          () => io.out.toString().contains('Sleep prevention level'),
        );
        io.sendLine('1'); // the level
        await waitForIt(() => io.out.toString().contains('(empty keeps'));
        io.sendLine('display');
        await waitForIt(() => io.out.toString().contains('(applies live'));
        await waitForIt(() => runner.acquisitions.length == 2);
        // The boot assertion released; the re-armed session hold keeps
        // the new level held while the flow is still open.
        expect(runner.acquisitions.first.idle, isTrue);
        expect(runner.acquisitions.last.display, isTrue);
        expect(runner.handles.first.released, 1);
        expect(
          cli.powerAssertionsForTesting!.status().level,
          PowerAssertionLevel.display,
        );
        expect(cli.powerAssertionsForTesting!.status().held, isTrue);
        io.sendLine('3'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        expect(fake.calls, 0);
      },
    );

    test('AC4: an invalid level shows the parser error, writes nothing; '
        'an empty answer keeps the value', () async {
      const seedText =
          'provider: openrouter\npower:\n  sleepPrevention: idle\n';
      await seed(seedText);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startPowerFlow();
      await waitForIt(
        () => io.out.toString().contains('Sleep prevention level'),
      );
      io.sendLine('1'); // the level
      await waitForIt(() => io.out.toString().contains('(empty keeps'));
      io.sendLine('turbo'); // invalid → the parser's verbatim message
      await waitForIt(
        () =>
            io.out.toString().contains('not saved:') &&
            io.out.toString().contains(
              '"power.sleepPrevention" must be off, idle, display or '
              'system, got: turbo',
            ),
      );
      // An empty answer keeps the current value (no write, no error).
      final promptsBefore = '(empty keeps'.allMatches(io.out.toString()).length;
      io.sendLine('1');
      await waitForIt(
        () =>
            '(empty keeps'.allMatches(io.out.toString()).length > promptsBefore,
      );
      io.sendLine(''); // empty keeps
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(
        (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
        seedText,
        reason: 'nothing may be written',
      );
      expect(fake.calls, 0);
    });

    test(
      'E1: absent section offers defaults and writes a fresh block',
      () async {
        await seed('provider: openrouter\nmodel: m1\n');
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startPowerFlow();
        await waitForIt(
          () => io.out.toString().contains('Sleep prevention level'),
        );
        // The parser defaults are offered.
        expect(io.out.toString(), contains("now 'idle'"));
        expect(io.out.toString(), contains('per-run → session'));
        io.sendLine('2'); // hold toggle → a fresh block lands at the end
        await waitForIt(
          () => io.out.toString().contains('power.hold = session'),
        );
        io.sendLine('3'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written!, startsWith('provider: openrouter\nmodel: m1\n'));
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        expect(parsed.powerHold, PowerAssertionHold.session);
        expect(
          parsed.powerSleepPrevention,
          isNull,
          reason: 'the key stays unset — the host applies idle at boot',
        );
        expect(fake.calls, 0);
      },
    );

    test('E2: an unreadable config file refuses with a clear error', () async {
      await env.createDir('/home/u/.fah/config.yaml');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startPowerFlow();
      await waitForIt(
        () => io.out.toString().contains('Sleep prevention level'),
      );
      io.sendLine('2'); // the hold toggle → the write path reads the config
      await waitForIt(
        () =>
            io.out.toString().contains('cannot read /home/u/.fah/config.yaml'),
      );
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('no user config on this host prints and writes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call); // no homeDir → no user config path
      final run = cli.run();

      final flow = cli.startPowerFlow();
      await waitForIt(
        () => io.out.toString().contains('Sleep prevention level'),
      );
      io.sendLine('2');
      await waitForIt(
        () => io.out.toString().contains('no user config on this host'),
      );
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('E3: a concurrent power edit survives the write', () async {
      await seed('provider: openrouter\npower:\n  sleepPrevention: idle\n');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startPowerFlow();
      await waitForIt(
        () => io.out.toString().contains('Sleep prevention level'),
      );
      io.sendLine('1'); // the level
      await waitForIt(() => io.out.toString().contains('(empty keeps'));
      // A concurrent edit lands while the prompt sits open.
      await env.writeFile(
        '/home/u/.fah/config.yaml',
        'provider: openrouter\npower:\n  sleepPrevention: idle\n'
            '  hold: session\n',
      );
      io.sendLine('display');
      await waitForIt(
        () => io.out.toString().contains('power.sleepPrevention = display'),
      );
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.powerSleepPrevention, PowerAssertionLevel.display);
      expect(
        parsed.powerHold,
        PowerAssertionHold.session,
        reason: 'the concurrent hold edit survives',
      );
      expect(fake.calls, 0);
    });

    test('cancelled at the menu writes nothing', () async {
      const seedText = 'provider: openrouter\n';
      await seed(seedText);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startPowerFlow();
      await waitForIt(
        () => io.out.toString().contains('Sleep prevention level'),
      );
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(
        (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
        seedText,
      );
      expect(fake.calls, 0);
    });
  });
}
