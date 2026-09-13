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

/// Sleep-prevention wiring (issue #325): the session acquires one
/// assertion at start and releases it on exit; `/power` shows the state.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli buildCli({PowerAssertionLevel level = PowerAssertionLevel.display,
    _FakeRunner? runner,}) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      powerSleepPrevention: level,
      powerRunner: runner,
    ),
    io: io,
  );

  test(
    'a full run acquires at session start and releases on exit',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final runner = _FakeRunner();
      final cli = buildCli(runner: runner);
      final run = cli.run();
      for (var i = 0; i < 5000 && runner.acquisitions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Acquired once, with the configured level's cumulative options.
      expect(runner.acquisitions, hasLength(1));
      expect(runner.acquisitions.single.idle, isTrue);
      expect(runner.acquisitions.single.display, isTrue);
      expect(runner.handles.single.held, isTrue);

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
        contains('sleepPrevention=display held=yes (fake-caffeinate -i)'),
      );

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      // Teardown released the assertion exactly once.
      expect(runner.handles.single.released, 1);
      await io.close();
    },
  );

  test(
    'a spawn failure warns and the session continues',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final runner = _FakeRunner()..error = Exception('caffeinate missing');
      final cli = buildCli(runner: runner);
      final run = cli.run();
      for (
        var i = 0;
        i < 5000 && !io.out.toString().contains('sleep prevention');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(io.out.toString(), contains('power: sleep prevention unavailable'));
      expect(runner.acquisitions, isEmpty);

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
        contains('sleepPrevention=off held=no (no runner on this host)'),
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
