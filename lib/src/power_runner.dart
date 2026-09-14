/// The power-assertion lifecycle seam (issue #325, reworked in #326):
/// a [PowerAssertionController] owns ONE assertion and applies the
/// configured [PowerAssertionHold] policy to the lifecycle events both
/// hosts (CLI, app) fire — run started / run settled / session opened /
/// session closed. Default policy is per-run (acquire at turn start,
/// release at settle); session-held is the explicit opt-in.
///
/// Pure Dart: hosts inject the platform runner (`lib/io.dart`'s
/// `hostPowerRunner`); tests inject a fake, so no unit test ever spawns a
/// real `caffeinate`/`systemd-inhibit`.
library;

import 'dart:async';

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

/// Acquires power assertions when the configured hold asks for one
/// (per-run at turn start by default, per-session as the opt-in, #326).
/// Implementations spawn the platform helper (macOS `caffeinate`, Linux
/// `systemd-inhibit`) or degrade to a no-op note on platforms without
/// one.
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
    required this.hold,
    required this.held,
    this.detail,
  });

  /// The effective `power.sleepPrevention` level.
  final PowerAssertionLevel level;

  /// The effective `power.hold` lifecycle.
  final PowerAssertionHold hold;

  /// Whether an assertion is currently held.
  final bool held;

  /// What is (or why nothing is) holding it.
  final String? detail;

  @override
  String toString() =>
      'sleepPrevention=${level.value} hold=${hold.value} '
      'held=${held ? 'yes' : 'no'}'
      '${detail == null ? '' : ' ($detail)'}';
}

/// Session-scoped owner of one power assertion. NOT a lifecycle-fidelity
/// port of oh-my-pi's `#acquirePowerAssertion`/`#releasePowerAssertion`:
/// oh-my-pi holds per session, but a session-open hold pins the machine
/// awake for whole idle hours between runs (issue #326) — so the DEFAULT
/// here is per-run ([PowerAssertionHold.perRun]): hosts fire
/// [onRunStarted]/[onRunSettled] around every run and the assertion
/// exists only while work is in flight. Session-held
/// ([PowerAssertionHold.session]) keeps oh-my-pi's behaviour as an
/// explicit opt-in via [onSessionOpened]/[onSessionClosed]. Both
/// directions stay idempotent and warn-not-crash: a failure on either
/// side is a WARNING — the run/session continues unguarded rather than
/// dying because the platform would not let us stay awake.
final class PowerAssertionController {
  PowerAssertionController({
    required this.runner,
    required this.level,
    this.hold = PowerAssertionHold.perRun,
    this.onWarn,
  });

  /// The platform runner (host-injected: real on the CLI/app, fake or
  /// absent in tests).
  final PowerAssertionRunner runner;

  /// The configured sleep-prevention level.
  final PowerAssertionLevel level;

  /// When the assertion is held (`power.hold`): per-run by default,
  /// session as the explicit opt-in.
  final PowerAssertionHold hold;

  /// Receives best-effort warning lines ("power: ...") — never fatal.
  final void Function(String message)? onWarn;
  PowerAssertionHandle? _handle;

  /// An acquire still awaiting the platform spawn, if any — [release]
  /// waits it out so a fast-settling run can never strand a helper that
  /// finishes spawning after the release already ran.
  Future<void>? _acquiring;

  /// Whether an assertion was acquired and not yet released.
  bool get acquired => _handle != null;

  /// Run-start hook ([PowerAssertionHold.perRun]): fires the acquisition
  /// without blocking the turn — sleep prevention is best-effort
  /// plumbing, never a reason to delay the first streamed byte.
  void onRunStarted() {
    if (hold != PowerAssertionHold.perRun) return;
    unawaited(acquire());
  }

  /// Run-settle hook ([PowerAssertionHold.perRun]): releases once the
  /// run has fully settled (post-run compaction included).
  Future<void> onRunSettled() async {
    if (hold != PowerAssertionHold.perRun) return;
    await release();
  }

  /// Session-open hook ([PowerAssertionHold.session]): the explicit
  /// opt-in that holds the machine awake for the whole session, runs and
  /// idle stretches alike.
  Future<void> onSessionOpened() async {
    if (hold != PowerAssertionHold.session) return;
    await acquire();
  }

  /// Session-close hook (BOTH modes): releases whatever is held — the
  /// per-run mode's safety net for an exit mid-run.
  Future<void> onSessionClosed() => release();

  /// Acquires the assertion for [level]. No-op for `off` and when already
  /// acquired; a spawn failure warns (via the injected
  /// [PowerAssertionController] `onWarn`) and leaves the session
  /// unguarded.
  Future<void> acquire() {
    if (_handle != null || _acquiring != null) return Future<void>.value();
    final options = powerAssertionOptions(level);
    if (options == null) return Future<void>.value();
    final done = Completer<void>();
    _acquiring = done.future;
    () async {
      try {
        _handle = await runner.acquire(options);
      } on Object catch (error) {
        _warn('sleep prevention unavailable: $error');
      } finally {
        _acquiring = null;
        done.complete();
      }
    }();
    return done.future;
  }

  /// Releases the assertion (idempotent; a failure warns, never throws).
  Future<void> release() async {
    // Wait out an in-flight acquire first: a run that settles before the
    // helper finished spawning must not leave the just-spawned handle
    // stranded until session close.
    final acquiring = _acquiring;
    if (acquiring != null) await acquiring;
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
      hold: hold,
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
