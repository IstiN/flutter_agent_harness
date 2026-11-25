// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared periodic rediscovery of the local session catalog for the
/// network hosts (CLI [NetworkPresenceController] + the daemon's
/// [MultiSessionConnectorHost]).
///
/// Why this exists (gh-2410, idle CPU burn): both hosts used to run a bare
/// `Timer.periodic(interval, (_) => refresh())`. On a large session store
/// one catalog pass outlasted the interval, so passes overlapped, each one
/// re-reading gigabytes of transcript windows, and an otherwise idle `fa`
/// burned ~1.5 cores forever. The poller is the ONE place that owns the
/// three rules every periodic store pass must obey:
///
/// * **single-flight** — a tick that lands while a pass is still running
///   only marks it dirty; when the running pass finishes, at most ONE
///   follow-up pass covers every tick that piled up. Concurrent store
///   reads are impossible by construction.
/// * **active gate** — ticks are no-ops while the upstream link is not
///   connected: nothing is published while disconnected and the next
///   connect sends a full snapshot anyway. Deactivating marks the poller
///   dirty, so the next activation refreshes exactly once and the
///   snapshot published after a reconnect reflects changes made while the
///   link was down.
/// * **deterministic clock** — the periodic timer comes from an injected
///   [PeriodicTimerFactory], so tests fire ticks by hand (no wall clock).
///
/// The initial full refresh at start stays with the hosts; the poller only
/// schedules the follow-up passes.
library;

import 'dart:async';

/// The slice of `Timer` the poller needs, so the production `Timer.periodic`
/// and hand-fired test timers share one type.
abstract interface class CancelableTimer {
  /// Cancels the timer; a cancelled timer never fires again.
  void cancel();
}

/// Creates a cancelable periodic timer firing [onTick] every [interval].
typedef PeriodicTimerFactory =
    CancelableTimer Function(Duration interval, void Function() onTick);

/// The production timer factory: `Timer.periodic`.
CancelableTimer periodicTimer(Duration interval, void Function() onTick) =>
    _TimerHandle(Timer.periodic(interval, (_) => onTick()));

final class _TimerHandle implements CancelableTimer {
  const _TimerHandle(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// Periodic, single-flight, gated runner of one catalog pass ([run]).
///
/// Not restartable after [stop] only in the sense that the schedule is
/// gone — [start] may be called again (hosts re-enter `start()` on every
/// session switch); the poller instance itself lives as long as its host.
final class CatalogPoller {
  /// Creates a poller around one catalog pass.
  ///
  /// [onError] receives a failing [run]; when null the failure is rethrown
  /// to the awaiting caller (a timer-driven tick then surfaces it as an
  /// uncaught async error — never swallowed).
  CatalogPoller({
    required this.run,
    this.onError,
    PeriodicTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? periodicTimer;

  /// One catalog pass (e.g. `refreshSessionCatalog()`).
  final Future<void> Function() run;

  /// Failure sink of [run]; null rethrows.
  final void Function(Object error, StackTrace stackTrace)? onError;

  final PeriodicTimerFactory _timerFactory;

  CancelableTimer? _timer;
  var _active = false;
  var _running = false;
  var _dirty = false;

  /// Whether ticks may run (the upstream link is connected).
  bool get isActive => _active;

  /// Whether a catalog pass is in flight.
  bool get isRunning => _running;

  /// Whether a tick arrived that no finished pass has covered yet.
  bool get isDirty => _dirty;

  /// Whether a periodic timer is installed.
  bool get isScheduled => _timer != null;

  /// (Re)installs the periodic schedule at [interval], replacing any
  /// previous one. A zero/negative interval installs nothing — explicit
  /// [tick]s still work.
  void start(Duration interval) {
    _timer?.cancel();
    _timer = null;
    if (interval <= Duration.zero) return;
    _timer = _timerFactory(interval, () => unawaited(tick()));
  }

  /// Cancels the schedule and drops the pending follow-up. An in-flight
  /// pass is left to finish (its result is still published by the host).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _dirty = false;
  }

  /// Opens ([active]) or closes the gate. Closing marks the poller dirty so
  /// the next opening refreshes once — unless a pass is already running,
  /// which finishes on its own.
  void setActive(bool active) {
    if (active == _active) return;
    _active = active;
    if (!active) {
      _dirty = true;
      return;
    }
    if (_dirty && !_running) unawaited(_drain());
  }

  /// One periodic tick. No-op while inactive; while a pass is running it
  /// only marks dirty (the running pass covers it with one follow-up);
  /// otherwise it runs the pass and awaits its completion.
  Future<void> tick() {
    if (_running) {
      _dirty = true;
      return Future<void>.value();
    }
    if (!_active) return Future<void>.value();
    return _drain();
  }

  /// Runs [run], then at most one follow-up per tick that arrived during a
  /// pass, for as long as the gate stays open and the schedule alive.
  Future<void> _drain() async {
    _running = true;
    try {
      _dirty = false;
      await _runOnce();
      while (_dirty && _active) {
        _dirty = false;
        await _runOnce();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _runOnce() async {
    try {
      await run();
    } on Object catch (error, stackTrace) {
      final handler = onError;
      if (handler == null) rethrow;
      handler(error, stackTrace);
    }
  }
}
