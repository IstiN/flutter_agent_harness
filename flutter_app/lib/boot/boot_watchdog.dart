// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Boot diagnostics (gh-1507): boot-step breadcrumbs + a first-frame
/// watchdog.
///
/// A TestFlight freeze report ("Just freezed", uptime 3000 ms) carried no
/// crash log and no clue which boot step wedged. [BootSteps] records every
/// completed boot step with its timestamp, and [BootWatchdog] watches the
/// boot in two phases: the first frame (when it does not land within
/// [BootWatchdog.threshold], a breadcrumb naming the uptime and the last
/// completed / in-flight boot step is logged) and, while a restore is in
/// flight ([BootWatchdog.beginRestore] → [BootWatchdog.restoreDone]), the
/// post-frame restore — a restore wedge, the reported freeze's most likely
/// shape, breadcrumbs the same way. Breadcrumbs ride the process-wide `debugPrint` tee (console +
/// `logs/app.log` + the Crashlytics breadcrumb trail — both tees are
/// installed by `bootWindow`/`bootTelemetry`, so the breadcrumb reaches
/// every sink without direct dependencies here).
///
/// The watchdog only ever LOGS — it must never change boot semantics.
///
/// Blind spot: the probe is a `Timer` + `addPostFrameCallback`, so it
/// detects stalls where the event loop still turns (an await-chain
/// deadlock or event-loop starvation). A synchronously blocked main
/// isolate suppresses both the probe and the breadcrumb — a silent
/// watchdog does not prove a healthy boot.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Process-wide boot-step ledger. Steps are short names in boot order
/// (`window`, `services`, `storage:sessionKeys`, …); each [mark] records
/// the step's completion together with the process uptime.
abstract final class BootSteps {
  /// Process uptime, started when this class is first touched — the
  /// earliest a Dart timestamp can be taken.
  static final Stopwatch uptime = Stopwatch()..start();

  /// Completed steps, oldest first: `'name@1234ms'`.
  static final List<String> _completed = <String>[];

  /// The step currently in flight (begun, not yet marked complete).
  static String? _current;

  /// Records the completion of [name] and makes it the latest step.
  static void mark(String name) {
    _completed.add('$name@${uptime.elapsedMilliseconds}ms');
    _current = null;
    // Bound the ledger — the breadcrumb only reports the tail anyway.
    if (_completed.length > 64) _completed.removeAt(0);
  }

  /// Names the in-flight step without claiming completion (for steps that
  /// can wedge mid-way; the breadcrumb then reports it as `in flight`).
  static void begin(String name) => _current = name;

  /// Clears the ledger — tests only.
  @visibleForTesting
  static void reset() {
    _completed.clear();
    _current = null;
    uptime.reset();
    uptime.start();
  }

  /// The diagnostic tail: last completed steps plus the in-flight one.
  @visibleForTesting
  static String describe() {
    final tail = _completed.length <= 6
        ? List<String>.of(_completed)
        : _completed.sublist(_completed.length - 6);
    final current = _current;
    return '[${tail.join(', ')}]'
        '${current == null ? '' : ' (in flight: $current)'}';
  }
}

/// Watches the boot in two phases: the first frame, then the post-frame
/// restore. [install] schedules the frame probe and arms the threshold
/// timer; while a phase does not complete, the timer re-arms at
/// [repeatInterval] and logs one breadcrumb per firing, up to
/// [_maxFirings] per phase — a permanently wedged boot then logs a final
/// "giving up" line instead of a breadcrumb every 30 s for the lifetime
/// of the process.
final class BootWatchdog {
  BootWatchdog({
    this.threshold = const Duration(
      milliseconds: _defaultThresholdMs,
    ),
    this.restoreThreshold = const Duration(
      milliseconds: _defaultRestoreThresholdMs,
    ),
    this.repeatInterval = const Duration(seconds: 30),
    void Function(String message)? onBreadcrumb,
    Stopwatch? uptime,
  }) : _onBreadcrumb =
           onBreadcrumb ??
           ((message) => debugPrint('[fah] BOOT-WATCHDOG $message')),
       _uptime = uptime ?? BootSteps.uptime;

  /// First-frame threshold. The freeze report landed at ~3 s uptime, so
  /// the default sits just above a healthy cold start on a fast device;
  /// overridable at build time (`--dart-define=FA_BOOT_WATCHDOG_MS=…`),
  /// 0 disables the watchdog entirely.
  static const int _defaultThresholdMs =
      int.fromEnvironment('FA_BOOT_WATCHDOG_MS', defaultValue: 4000);

  /// Restore-phase threshold, armed when the first frame lands and
  /// disarmed by [restoreDone]. The restore chain (env → session manager
  /// → `createOrResumeSession`) runs more awaited disk reads behind the
  /// boot spinner, and the reported freeze (~3 s uptime) plausibly
  /// wedged there — after the first frame, so a first-frame-only watchdog
  /// would have stayed silent. Overridable at build time
  /// (`--dart-define=FA_BOOT_RESTORE_WATCHDOG_MS=…`).
  static const int _defaultRestoreThresholdMs =
      int.fromEnvironment('FA_BOOT_RESTORE_WATCHDOG_MS', defaultValue: 10000);

  /// Cap on repeat firings per phase; a permanently wedged boot (or an
  /// app backgrounded mid-boot) stops at a final "giving up" line instead
  /// of growing the log and the Crashlytics breadcrumb trail without
  /// bound.
  static const int _maxFirings = 10;

  /// Time allowed for the first frame before the first breadcrumb fires.
  final Duration threshold;

  /// Time allowed for the post-frame restore (see [restoreDone]) before
  /// the first restore-phase breadcrumb fires.
  final Duration restoreThreshold;

  /// Re-arm interval while a phase has not completed (one breadcrumb per
  /// firing, up to [_maxFirings]).
  final Duration repeatInterval;

  final void Function(String message) _onBreadcrumb;
  final Stopwatch _uptime;
  Timer? _timer;
  bool _firstFrameSeen = false;
  bool _restoreArmed = false;
  int _firings = 0;
  int _restoreFirings = 0;

  /// Arms the watchdog and schedules the first-frame probe. Must be called
  /// with the widgets binding initialized (after `bootWindow`). Idempotent
  /// — a second install on an already-armed instance is a no-op.
  void install() {
    if (_defaultThresholdMs <= 0) return;
    if (_timer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => firstFrame());
    _arm(threshold, _fire);
  }

  /// Records that the first frame landed: cancels the pre-frame timer.
  /// Also wired by tests in place of a real frame. Does NOT arm the
  /// restore phase — that is [beginRestore]'s job, so a session with no
  /// restore ahead (first-launch onboarding, the setup form) never sees
  /// spurious restore breadcrumbs.
  void firstFrame() {
    _firstFrameSeen = true;
    _timer?.cancel();
    _timer = null;
    if (_firings > 0) {
      _onBreadcrumb(
        'first frame landed at ${_uptime.elapsedMilliseconds}ms '
        '(watchdog had fired $_firings×)',
      );
    }
  }

  /// Arms the restore phase: call when the post-frame restore chain
  /// (env → session manager → `createOrResumeSession`) actually starts.
  /// The TestFlight freeze wedged at ~3 s uptime — plausibly after the
  /// first frame, where a first-frame-only watchdog stays silent — so a
  /// restore wedge breadcrumbs the same way a pre-frame one does.
  /// Idempotent — a second call on an armed phase is a no-op.
  void beginRestore() {
    if (_restoreArmed) return;
    _restoreArmed = true;
    _arm(restoreThreshold, _fireRestore);
  }

  /// Disarms the restore phase: call when the post-frame restore
  /// (`restore:session`) completes, on success or failure. A no-op unless
  /// the phase is armed via [beginRestore] (and on repeat calls), so the
  /// boot path can end it in a `finally` without bookkeeping.
  void restoreDone() {
    if (!_restoreArmed) return;
    _restoreArmed = false;
    _timer?.cancel();
    _timer = null;
    if (_restoreFirings > 0) {
      _onBreadcrumb(
        'restore completed at ${_uptime.elapsedMilliseconds}ms '
        '(restore watchdog had fired $_restoreFirings×)',
      );
    }
  }

  void _arm(Duration delay, void Function() onFire) {
    _timer = Timer(delay, onFire);
  }

  void _fire() {
    if (_firstFrameSeen) return;
    _firings++;
    _onBreadcrumb(
      'first frame not reached after ${_uptime.elapsedMilliseconds}ms '
      '(threshold ${threshold.inMilliseconds}ms, firing #$_firings); '
      'boot steps ${BootSteps.describe()}',
    );
    _repeatOrGiveUp(_firings, _fire);
  }

  void _fireRestore() {
    if (!_restoreArmed) return;
    _restoreFirings++;
    _onBreadcrumb(
      'restore not completed after ${_uptime.elapsedMilliseconds}ms '
      '(threshold ${restoreThreshold.inMilliseconds}ms, '
      'firing #$_restoreFirings); boot steps ${BootSteps.describe()}',
    );
    _repeatOrGiveUp(_restoreFirings, _fireRestore);
  }

  /// Re-arms at [repeatInterval] until the phase hits [_maxFirings]; a
  /// wedged boot then gets a final "giving up" line and no more timers.
  void _repeatOrGiveUp(int firings, void Function() onFire) {
    if (firings >= _maxFirings) {
      _onBreadcrumb(
        'giving up after $_maxFirings firings '
        '(boot is permanently wedged or the app is backgrounded); '
        'boot steps ${BootSteps.describe()}',
      );
      return;
    }
    _arm(repeatInterval, onFire);
  }
}
