import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A runner that records acquisitions without spawning anything — the
/// test-runtime stand-in for `hostPowerRunner` (no real caffeinate).
class _FakeRunner implements PowerAssertionRunner {
  final acquisitions = <PowerAssertionOptions>[];
  final handles = <_FakeHandle>[];
  Object? error;

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    if (error != null) throw error!;
    acquisitions.add(options);
    final handle = _FakeHandle();
    handles.add(handle);
    return handle;
  }
}

class _FakeHandle implements PowerAssertionHandle {
  var released = 0;

  @override
  String get description => 'fake-caffeinate -i';

  @override
  bool get held => released == 0;

  @override
  Future<void> release() async => released++;
}

/// Sleep-prevention wiring (issues #325/#326): the DEFAULT hold is
/// per-run — acquire at run start, release at settle — while
/// `power.hold: session` keeps the session-open hold as an explicit
/// opt-in; `/power` shows level, hold, and held-ness.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli buildCli({
    PowerAssertionLevel level = PowerAssertionLevel.display,
    PowerAssertionHold hold = PowerAssertionHold.perRun,
    _FakeRunner? runner,
    StreamFunction? streamFunction,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      powerSleepPrevention: level,
      powerSleepPreventionHold: hold,
      powerRunner: runner,
    ),
    io: io,
    streamFunction: streamFunction,
  );

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 5000 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'DEFAULT per-run hold: an idle session acquires nothing; a run '
    'acquires at start and releases at settle',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final runner = _FakeRunner();
      final cli = buildCli(
        runner: runner,
        streamFunction: FakeStreamFunction([textTurn('done')]).call,
      );
      final run = cli.run();
      // Give boot every chance to (wrongly) acquire at session open.
      await until(
        () =>
            io.out.toString().contains('fa boot') ||
            runner.acquisitions.isNotEmpty,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        runner.acquisitions,
        isEmpty,
        reason: 'per-run hold must NOT acquire at session open',
      );

      // One full turn: acquire with the run, release at settle.
      io.sendLine('do the thing');
      await until(() => runner.acquisitions.isNotEmpty);
      expect(runner.acquisitions.single.idle, isTrue);
      expect(runner.acquisitions.single.display, isTrue);
      await until(() => runner.handles.single.released == 1);
      expect(cli.powerAssertionsForTesting!.status().held, isFalse);

      // Idle again: /power reports not-held with the hold named.
      io.sendLine('/power');
      await until(() => io.out.toString().contains('sleepPrevention=display'));
      expect(
        io.out.toString(),
        contains(
          'sleepPrevention=display hold=per-run held=no '
          '(not acquired)',
        ),
      );

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      // Session close after the settle release is a clean no-op.
      expect(runner.handles.single.released, 1);
      await io.close();
    },
  );

  test(
    'power.hold: session (explicit opt-in) holds from session start to exit',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final runner = _FakeRunner();
      final cli = buildCli(
        hold: PowerAssertionHold.session,
        runner: runner,
        streamFunction: FakeStreamFunction([textTurn('done')]).call,
      );
      final run = cli.run();
      for (var i = 0; i < 5000 && runner.acquisitions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Acquired once at session open, with the configured level's
      // cumulative options.
      expect(runner.acquisitions, hasLength(1));
      expect(runner.acquisitions.single.display, isTrue);
      expect(runner.handles.single.held, isTrue);

      // A full run must neither re-acquire nor release the held one.
      io.sendLine('do the thing');
      await until(() => io.out.toString().contains('done'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(runner.acquisitions, hasLength(1));
      expect(runner.handles.single.released, 0);

      io.sendLine('/power');
      for (
        var i = 0;
        i < 5000 && !io.out.toString().contains('sleepPrevention=display');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        io.out.toString(),
        contains(
          'sleepPrevention=display hold=session held=yes (fake-caffeinate -i)',
        ),
      );

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      // Teardown released the assertion exactly once.
      expect(runner.handles.single.released, 1);
      await io.close();
    },
  );

  test(
    'a spawn failure during a run warns and the run continues',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final runner = _FakeRunner()..error = Exception('caffeinate missing');
      final cli = buildCli(
        runner: runner,
        streamFunction: FakeStreamFunction([textTurn('done')]).call,
      );
      final run = cli.run();
      // The per-run acquire fires with the run — so must the warning.
      io.sendLine('do the thing');
      for (
        var i = 0;
        i < 5000 && !io.out.toString().contains('sleep prevention');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        io.out.toString(),
        contains('power: sleep prevention unavailable'),
      );
      expect(runner.acquisitions, isEmpty);
      // The run itself completed despite the unguarded power state.
      expect(io.out.toString(), contains('done'));

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'no runner injected (test runtime) means no assertions — /power says so',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = buildCli(level: PowerAssertionLevel.off);
      final run = cli.run();
      io.sendLine('/power');
      for (
        var i = 0;
        i < 5000 && !io.out.toString().contains('sleepPrevention=off');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        io.out.toString(),
        contains(
          'sleepPrevention=off hold=per-run held=no (no runner on this host)',
        ),
      );
      expect(cli.powerAssertionsForTesting, isNull);

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test('the /power command is registered in the builtin slash menu', () {
    expect(builtinSlashCommands, contains('/power'));
    expect(builtinSlashCommands['/power'], contains('sleep prevention'));
  });
}
