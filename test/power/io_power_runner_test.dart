import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/src/power/io_power_runner.dart';
import 'package:flutter_agent_harness/src/power_config.dart';
import 'package:flutter_agent_harness/src/power_runner.dart';
import 'package:test/test.dart';

/// A [Process] stand-in: only `exitCode`/`kill` are real members; every
/// other Process member would fail loudly via noSuchMethod (the runners
/// never touch stdio). No real process is ever spawned in this suite.
class _FakeProcess implements Process {
  final _exit = Completer<int>();
  var killCalls = 0;

  /// Simulates the helper exiting on its own (crash / fa pid gone).
  void die() => _complete(0);

  void _complete(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    _complete(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records every spawn request; optionally throws (helper missing).
class _RecordingLauncher {
  _RecordingLauncher([this.error]);

  final Object? error;
  final spawns = <(String, List<String>)>[];
  final processes = <_FakeProcess>[];

  Future<Process> call(String executable, List<String> arguments) async {
    if (error != null) throw error!;
    spawns.add((executable, arguments));
    final process = _FakeProcess();
    processes.add(process);
    return process;
  }
}

PowerAssertionOptions _options(PowerAssertionLevel level) =>
    powerAssertionOptions(level)!;

void main() {
  test('CaffeinatePowerRunner spawns caffeinate with the level flags and -w pid', () async {
    final launcher = _RecordingLauncher();
    final runner = CaffeinatePowerRunner(pid: 4242, launcher: launcher.call);
    final handle = await runner.acquire(_options(PowerAssertionLevel.display));
    expect(launcher.spawns.single.$1, 'caffeinate');
    expect(launcher.spawns.single.$2, ['-i', '-d', '-w', '4242']);
    expect(handle.description, 'caffeinate -i -d -w 4242');
    expect(handle.held, isTrue);
  });

  test('release kills the helper once and reaps it (kill-safe, idempotent)', () async {
    final launcher = _RecordingLauncher();
    final runner = CaffeinatePowerRunner(pid: 1, launcher: launcher.call);
    final handle = await runner.acquire(_options(PowerAssertionLevel.idle));
    final process = launcher.processes.single;
    await handle.release();
    await handle.release();
    expect(process.killCalls, 1);
    expect(handle.held, isFalse);
  });

  test('a helper that dies on its own is no longer "held"', () async {
    final launcher = _RecordingLauncher();
    final runner = SystemdInhibitPowerRunner(pid: 1, launcher: launcher.call);
    final handle = await runner.acquire(_options(PowerAssertionLevel.idle));
    launcher.processes.single.die();
    // The exitCode future resolves on the next microtask turn.
    await Future<void>.delayed(Duration.zero);
    expect(handle.held, isFalse);
    await handle.release(); // still safe
  });

  test('SystemdInhibitPowerRunner spawns systemd-inhibit with a watchdog', () async {
    final launcher = _RecordingLauncher();
    final runner = SystemdInhibitPowerRunner(pid: 77, launcher: launcher.call);
    await runner.acquire(_options(PowerAssertionLevel.system));
    expect(launcher.spawns.single.$1, 'systemd-inhibit');
    expect(launcher.spawns.single.$2.first, '--what=idle:sleep');
    expect(launcher.spawns.single.$2.join(' '), contains('kill -0 77'));
  });

  test('a spawn failure propagates (the controller warns upstream)', () async {
    final launcher = _RecordingLauncher(
      ProcessException('caffeinate', const [], 'No such file'),
    );
    final runner = CaffeinatePowerRunner(pid: 1, launcher: launcher.call);
    await expectLater(
      runner.acquire(_options(PowerAssertionLevel.idle)),
      throwsA(isA<ProcessException>()),
    );
  });

  test('hostPowerRunner picks the platform runner', () async {
    final launcher = _RecordingLauncher();
    expect(
      hostPowerRunner(pid: 1, os: 'macos', launcher: launcher.call),
      isA<CaffeinatePowerRunner>(),
    );
    expect(
      hostPowerRunner(pid: 1, os: 'linux', launcher: launcher.call),
      isA<SystemdInhibitPowerRunner>(),
    );
    // The documented Windows stub degrades to a no-op note.
    final stub = hostPowerRunner(pid: 1, os: 'windows');
    expect(stub, isA<NoopPowerAssertionRunner>());
    final handle = await stub.acquire(_options(PowerAssertionLevel.idle));
    expect(handle.description, contains('not implemented on windows yet'));
    // Without an os override the host platform decides — any answer is a
    // runner, never a crash.
    expect(
      hostPowerRunner(pid: 1, launcher: launcher.call),
      isA<PowerAssertionRunner>(),
    );
  });
}
