// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Boot diagnostics (gh-1507): boot-step breadcrumbs + a first-frame
/// watchdog.
///
/// A TestFlight freeze report ("Just freezed", uptime 3000 ms) carried no
/// crash log and no clue which boot step wedged. [BootSteps] records every
/// completed boot step with its timestamp, and [BootWatchdog] watches the
/// first frame: when it does not land within [BootWatchdog.threshold], a
/// breadcrumb naming the uptime and the last completed / in-flight boot
/// step is logged through the process-wide `debugPrint` tee (console +
/// `logs/app.log` + the Crashlytics breadcrumb trail — both tees are
/// installed by `bootWindow`/`bootTelemetry`, so the breadcrumb reaches
/// every sink without direct dependencies here).
///
/// The watchdog only ever LOGS — it must never change boot semantics.
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

/// Watches the first frame during boot. [install] schedules the frame
/// probe and arms the threshold timer; while no frame lands, the timer
/// re-arms at [repeatInterval] and logs one breadcrumb per firing.
final class BootWatchdog {
  BootWatchdog({
    this.threshold = const Duration(
      milliseconds: _defaultThresholdMs,
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

  /// Time allowed for the first frame before the first breadcrumb fires.
  final Duration threshold;

  /// Re-arm interval while no frame has landed (one breadcrumb per firing).
  final Duration repeatInterval;

  final void Function(String message) _onBreadcrumb;
  final Stopwatch _uptime;
  Timer? _timer;
  bool _firstFrameSeen = false;
  int _firings = 0;

  /// Arms the watchdog and schedules the first-frame probe. Must be called
  /// with the widgets binding initialized (after `bootWindow`). Idempotent
  /// — a second install on an already-armed instance is a no-op.
  void install() {
    if (_defaultThresholdMs <= 0) return;
    if (_timer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => firstFrame());
    _arm(threshold);
  }

  /// Records that the first frame landed: cancels the timer. Also wired by
  /// tests in place of a real frame.
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

  void _arm(Duration delay) {
    _timer = Timer(delay, _fire);
  }

  void _fire() {
    if (_firstFrameSeen) return;
    _firings++;
    _onBreadcrumb(
      'first frame not reached after ${_uptime.elapsedMilliseconds}ms '
      '(threshold ${threshold.inMilliseconds}ms, firing #$_firings); '
      'boot steps ${BootSteps.describe()}',
    );
    _arm(repeatInterval);
  }
}
