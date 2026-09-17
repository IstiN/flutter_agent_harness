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

import 'dart:async';

import 'dart:io';

import '../power_config.dart';
import '../power_runner.dart';

/// Spawns a helper process; `Process.start` in production, a fake in
/// tests.
typedef PowerProcessLauncher =
    Future<Process> Function(String executable, List<String> arguments);

Future<Process> _defaultLauncher(String executable, List<String> arguments) =>
    Process.start(executable, arguments);

/// macOS runner: one `caffeinate` child per held assertion (per run by
/// default, per session at `power.hold: session`), bound to the fa pid
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
/// fa process even if fa is SIGKILLed.
///
/// Containers and systemd-less hosts have no `systemd-inhibit` (issue
/// #605): the spawn fails with ENOENT (errno 2), which this runner
/// caches and answers with a SILENT no-op from then on — the runner is
/// constructed once per host process, so the failed spawn happens at
/// most once instead of warning after every run. Other failures
/// propagate for the controller to warn about, as before.
final class SystemdInhibitPowerRunner implements PowerAssertionRunner {
  SystemdInhibitPowerRunner({required this.pid, PowerProcessLauncher? launcher})
    : _launcher = launcher ?? _defaultLauncher;

  /// The fa process id the watchdog polls (`kill -0`).
  final int pid;
  final PowerProcessLauncher _launcher;

  /// Set once the spawn reports ENOENT — no `systemd-inhibit` here (#605).
  var _helperMissing = false;

  static const _silentNoop = NoopPowerAssertionHandle(
    'systemd-inhibit unavailable (container or no systemd)',
  );

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    if (_helperMissing) return _silentNoop;
    final arguments = systemdInhibitArguments(options, pid: pid);
    try {
      final process = await _launcher('systemd-inhibit', arguments);
      return ProcessPowerAssertionHandle(
        process: process,
        description: 'systemd-inhibit ${arguments.join(' ')}',
      );
    } on ProcessException catch (error) {
      // errno 2 = ENOENT: helper absent (containers, systemd-less hosts).
      if (error.errorCode != 2) rethrow;
      _helperMissing = true;
      return _silentNoop;
    }
  }
}

/// One spawned helper process holding an assertion. `release` kills the
/// child (dropping the assertion immediately) and waits for its exit —
/// BOUNDED by [killTimeout] (5s default): a helper that ignores SIGTERM
/// gets one follow-up SIGKILL and release proceeds anyway (issue #326:
/// an unbounded await on a stuck helper would hang the run's settle).
/// An unexpected helper death flips [held] so `/power` never reports a
/// dead assertion as live.
final class ProcessPowerAssertionHandle implements PowerAssertionHandle {
  ProcessPowerAssertionHandle({
    required Process process,
    required this.description,
    this.killTimeout = defaultKillTimeout,
  }) : _process = process {
    _exit = process.exitCode.whenComplete(() {
      _done = true;
    });
  }

  /// How long [release] waits for the helper to die after SIGTERM before
  /// escalating to SIGKILL and proceeding anyway.
  static const defaultKillTimeout = Duration(seconds: 5);

  /// Per-handle override of [defaultKillTimeout] (tests).
  final Duration killTimeout;

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
    try {
      await _exit.timeout(killTimeout);
    } on TimeoutException {
      // The helper ignored SIGTERM: escalate to SIGKILL, then proceed —
      // release must return even when the helper refuses to die.
      _process.kill(ProcessSignal.sigkill);
    }
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
