// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Virtual clock + timer queue for the connector time seams
/// ([ConnectorClock]/[ConnectorTimers]): tests advance time with
/// [FakeConnectorTimers.elapse] instead of sleeping, so rate limits and
/// backoff ladders are asserted as numbers, never as wall-clock waits.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// A clock that only moves when a test advances it.
final class FakeConnectorClock implements ConnectorClock {
  FakeConnectorClock([DateTime? start])
    : _now = start ?? DateTime.utc(2026, 11, 24, 12);

  DateTime _now;

  /// The current virtual instant.
  DateTime get current => _now;

  @override
  DateTime now() => _now;
}

/// One queued timer of a [FakeConnectorTimers].
final class FakeScheduledTimer implements ConnectorTimer {
  FakeScheduledTimer({
    required this.due,
    required this.fire,
    required this.delay,
    required this.sequence,
    this.interval,
  });

  /// When the timer fires next (virtual time).
  DateTime due;

  /// The delay (period for periodic timers) it was armed with.
  final Duration delay;

  /// Arming order; breaks due-time ties so firing order is deterministic.
  final int sequence;

  /// The callback armed through the seam.
  final void Function() fire;

  /// Repeat period for `periodic` timers; null for one-shot timers.
  final Duration? interval;

  /// Cancelled through the seam.
  bool cancelled = false;

  /// How many times the queue fired it.
  int fired = 0;

  @override
  void cancel() => cancelled = true;
}

/// Lets async work scheduled by a fired timer settle: a few event-loop
/// turns (microtasks + zero-delay futures), NO real waiting.
Future<void> settleAsync([int turns = 6]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A deterministic timer queue over a [FakeConnectorClock].
final class FakeConnectorTimers implements ConnectorTimers {
  FakeConnectorTimers(this.clock);

  /// The clock the queue reads.
  final FakeConnectorClock clock;

  final List<FakeScheduledTimer> _pending = [];
  int _sequence = 0;

  /// Every timer ever armed through the seam, in creation order (including
  /// cancelled and already-fired one-shot timers).
  final all = <FakeScheduledTimer>[];

  /// One-shot + periodic timers still live (not cancelled, not fired out).
  List<FakeScheduledTimer> get pending =>
      List.unmodifiable(_pending.where((timer) => !timer.cancelled));

  /// Live one-shot timers, in arming order.
  List<FakeScheduledTimer> get pendingDelayed => List.unmodifiable(
    _pending.where((timer) => !timer.cancelled && timer.interval == null),
  );

  @override
  ConnectorTimer delayed(Duration duration, void Function() onFire) {
    final timer = FakeScheduledTimer(
      due: clock.now().add(duration),
      fire: onFire,
      delay: duration,
      sequence: _sequence++,
      interval: null,
    );
    _pending.add(timer);
    all.add(timer);
    return timer;
  }

  @override
  ConnectorTimer periodic(Duration interval, void Function() onTick) {
    final timer = FakeScheduledTimer(
      due: clock.now().add(interval),
      fire: onTick,
      delay: interval,
      sequence: _sequence++,
      interval: interval,
    );
    _pending.add(timer);
    all.add(timer);
    return timer;
  }

  /// Advances the virtual clock by [by], firing every due timer in due
  /// order (arming order breaks ties). After each callback the queue lets
  /// the async work it started settle, so chained operations can arm new
  /// timers inside the window — they fire too, in order.
  Future<void> elapse(Duration by) async {
    final target = clock.now().add(by);
    while (true) {
      final due =
          _pending
              .where((timer) => !timer.cancelled && !timer.due.isAfter(target))
              .toList()
            ..sort(
              (a, b) => a.due.compareTo(b.due) != 0
                  ? a.due.compareTo(b.due)
                  : a.sequence.compareTo(b.sequence),
            );
      if (due.isEmpty) break;
      final timer = due.first;
      _pending.remove(timer);
      clock._now = timer.due;
      timer.fired++;
      if (timer.interval != null) {
        timer.due = timer.due.add(timer.interval!);
        _pending.add(timer);
      }
      timer.fire();
      await settleAsync();
    }
    if (clock.now().isBefore(target)) clock._now = target;
    await settleAsync();
  }
}
