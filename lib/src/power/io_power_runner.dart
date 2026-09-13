/// `dart:io`-backed power assertions (issue #325) — reached only through
/// the `lib/io.dart` barrel, never the core library:
///
/// - macOS: `caffeinate -i [-d] [-s] [-u] -w <pid>` — caffeinate watches
///   the fa pid and self-exits when fa dies, so the assertion can never
///   outlive the session (no orphan leak even on a crash). `caffeinate`
///   has no reason flag; the reason surfaces on Linux and in `/power`.
/// - Linux: `systemd-inhibit --what=idle[:sleep] ... sh -c <watchdog>`
///   where the watchdog exits once the fa pid is gone — best-effort
///   (systems without systemd fail the spawn, which warns and continues).
/// - Everything else (Windows `SetThreadExecutionState` is a documented
///   later stub): a clean no-op.
///
/// The launcher seam ([PowerProcessLauncher]) keeps unit tests from ever
/// spawning a real helper process.
library;

import 'dart:io';

import '../power_config.dart';
import '../power_runner.dart';

/// Spawns a helper process; `Process.start` in production, a fake in
/// tests.
typedef PowerProcessLauncher = Future<Process> Function(
  String executable,
  List<String> arguments,
);

Future<Process> _defaultLauncher(String executable, List<String> arguments) =>
    Process.start(executable, arguments);

/// macOS runner: one `caffeinate` child per session, bound to the fa pid
/// by `-w`. Kill-safe: [ProcessPowerAssertionHandle.release] terminates
/// the child even though `-w` would also end it at process exit.
final class CaffeinatePowerRunner implements PowerAssertionRunner {
  CaffeinatePowerRunner({required this.pid, PowerProcessLauncher? launcher})
    : _launcher = launcher ?? _defaultLauncher;

  /// The fa process id caffeinate watches (`-w`).
  final int pid;
  final PowerProcessLauncher _launcher;

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    final arguments = caffeinateArguments(options, pid: pid);
    final process = await _launcher('caffeinate', arguments);
    return ProcessPowerAssertionHandle(
      process: process,
      description: 'caffeinate ${arguments.join(' ')}',
    );
  }
}

/// Linux runner (best-effort): `systemd-inhibit` holding idle (and, at
/// the `system` level, sleep) inhibition while its watchdog command
/// lives — the watchdog polls the fa pid, so the assertion dies with the
/// session even if fa is SIGKILLed.
final class SystemdInhibitPowerRunner implements PowerAssertionRunner {
  SystemdInhibitPowerRunner({required this.pid, PowerProcessLauncher? launcher})
    : _launcher = launcher ?? _defaultLauncher;

  /// The fa process id the watchdog polls (`kill -0`).
  final int pid;
  final PowerProcessLauncher _launcher;

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    final arguments = systemdInhibitArguments(options, pid: pid);
    final process = await _launcher('systemd-inhibit', arguments);
    return ProcessPowerAssertionHandle(
      process: process,
      description: 'systemd-inhibit ${arguments.join(' ')}',
    );
  }
}

/// One spawned helper process holding an assertion. `release` kills the
/// child (dropping the assertion immediately) and reaps its exit code;
/// an unexpected helper death flips [held] so `/power` never reports a
/// dead assertion as live.
final class ProcessPowerAssertionHandle implements PowerAssertionHandle {
  ProcessPowerAssertionHandle({
    required Process process,
    required this.description,
  }) : _process = process {
    _exit = process.exitCode.whenComplete(() {
      _done = true;
    });
  }

  final Process _process;
  late final Future<int> _exit;
  var _done = false;
  var _released = false;

  @override
  final String description;

  @override
  bool get held => !_released && !_done;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    // SIGTERM the helper: caffeinate drops its assertion, systemd-inhibit
    // ends the inhibition. kill() on an already-dead child is a no-op.
    _process.kill();
    await _exit;
  }
}

/// The platform runner: caffeinate on macOS, systemd-inhibit on Linux, a
/// no-op with an explicit note everywhere else. [os] overrides the
/// detected platform (tests); [launcher] overrides the spawn (tests).
PowerAssertionRunner hostPowerRunner({
  required int pid,
  String? os,
  PowerProcessLauncher? launcher,
}) => switch (os ?? Platform.operatingSystem) {
  'macos' => CaffeinatePowerRunner(pid: pid, launcher: launcher),
  'linux' => SystemdInhibitPowerRunner(pid: pid, launcher: launcher),
  final other => NoopPowerAssertionRunner(
    'sleep prevention is not implemented on $other yet',
  ),
};
