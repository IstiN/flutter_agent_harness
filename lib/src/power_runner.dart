/// The power-assertion lifecycle seam (issue #325): a [PowerAssertionRunner]
/// acquires one assertion per session and its [PowerAssertionHandle]
/// releases it — idempotently, warn-not-crash — from
/// [PowerAssertionController], which both hosts (CLI, app) share.
///
/// Pure Dart: hosts inject the platform runner (`lib/io.dart`'s
/// `hostPowerRunner`); tests inject a fake, so no unit test ever spawns a
/// real `caffeinate`/`systemd-inhibit`.
library;

import 'power_config.dart';

/// One held power assertion. `release` is idempotent and never throws for
/// an already-gone helper process; [held] flips false once released or
/// when the helper died on its own, so status surfaces stay honest.
abstract interface class PowerAssertionHandle {
  /// What is holding the machine awake (e.g. `caffeinate -i -w 4242`) —
  /// shown by `/power` and diagnostics.
  String get description;

  /// Whether the assertion is currently held.
  bool get held;

  /// Drops the assertion. Safe to call more than once.
  Future<void> release();
}

/// Acquires power assertions for a session start. Implementations spawn
/// the platform helper (macOS `caffeinate`, Linux `systemd-inhibit`) or
/// degrade to a no-op note on platforms without one.
abstract interface class PowerAssertionRunner {
  /// Starts holding an assertion with [options]; throws when the helper
  /// cannot be spawned (the caller warns and continues).
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options);
}

/// A handle that never held anything: the clean degradation for
/// platforms without a power-inhibition helper (the documented Windows
/// stub, exotic hosts).
final class NoopPowerAssertionHandle implements PowerAssertionHandle {
  const NoopPowerAssertionHandle(this.description);

  @override
  final String description;

  @override
  bool get held => false;

  @override
  Future<void> release() async {}
}

/// The platform runner of last resort: "acquires" a no-op handle whose
/// description explains why. Sleep prevention is best-effort everywhere —
/// never a boot blocker.
final class NoopPowerAssertionRunner implements PowerAssertionRunner {
  const NoopPowerAssertionRunner(this.note);

  /// Why no assertion can be held here (surfaced by `/power`).
  final String note;

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async =>
      NoopPowerAssertionHandle(note);
}

/// `/power`'s one-line answer: the configured level, whether an
/// assertion is held right now, and what is holding it.
final class PowerAssertionStatus {
  const PowerAssertionStatus({
    required this.level,
    required this.held,
    this.detail,
  });

  /// The effective `power.sleepPrevention` level.
  final PowerAssertionLevel level;

  /// Whether an assertion is currently held.
  final bool held;

  /// What is (or why nothing is) holding it.
  final String? detail;

  @override
  String toString() =>
      'sleepPrevention=${level.value} held=${held ? 'yes' : 'no'}'
      '${detail == null ? '' : ' ($detail)'}';
}

/// Session-scoped owner of one power assertion (oh-my-pi's
/// `#acquirePowerAssertion`/`#releasePowerAssertion`, ported):
/// acquire on session start, release on exit, both idempotent, and a
/// failure on either side is a WARNING — the session continues unguarded
/// rather than dying because the platform would not let us stay awake.
final class PowerAssertionController {
  PowerAssertionController({
    required this.runner,
    required this.level,
    this.onWarn,
  });

  /// The platform runner (host-injected: real on the CLI/app, fake or
  /// absent in tests).
  final PowerAssertionRunner runner;

  /// The configured sleep-prevention level.
  final PowerAssertionLevel level;

  /// Receives best-effort warning lines ("power: ...") — never fatal.
  final void Function(String message)? onWarn;
  PowerAssertionHandle? _handle;

  /// Whether an assertion was acquired and not yet released.
  bool get acquired => _handle != null;

  /// Acquires the assertion for [level]. No-op for `off` and when already
  /// acquired; a spawn failure warns (via the injected [PowerAssertionController]
  /// `onWarn`) and leaves the session unguarded.
  Future<void> acquire() async {
    if (_handle != null) return;
    final options = powerAssertionOptions(level);
    if (options == null) return;
    try {
      _handle = await runner.acquire(options);
    } on Object catch (error) {
      _warn('sleep prevention unavailable: $error');
    }
  }

  /// Releases the assertion (idempotent; a failure warns, never throws).
  Future<void> release() async {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    try {
      await handle.release();
    } on Object catch (error) {
      _warn('sleep prevention release failed: $error');
    }
  }

  /// The `/power` status line.
  PowerAssertionStatus status() {
    final handle = _handle;
    return PowerAssertionStatus(
      level: level,
      held: handle?.held ?? false,
      detail:
          handle?.description ??
          switch (level) {
            PowerAssertionLevel.off => 'disabled by config',
            _ => 'not acquired',
          },
    );
  }

  void _warn(String message) => onWarn?.call('power: $message');
}
