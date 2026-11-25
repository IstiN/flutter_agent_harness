// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_agent_harness/src/network/connector/catalog_poller.dart';
import 'package:test/test.dart';

/// Deterministic stand-in for `Timer.periodic`: the test fires ticks by
/// hand and nothing depends on wall-clock time.
final class _FakeTimerFactory {
  final timers = <_FakeTimer>[];

  _FakeTimer get single => timers.single;

  CancelableTimer call(Duration interval, void Function() onTick) {
    final timer = _FakeTimer(interval, onTick);
    timers.add(timer);
    return timer;
  }
}

final class _FakeTimer implements CancelableTimer {
  _FakeTimer(this.interval, this._onTick);

  final Duration interval;
  final void Function() _onTick;
  var cancelled = false;
  var fires = 0;

  /// One periodic firing (the production callback is fire-and-forget).
  void fire() {
    expect(cancelled, isFalse, reason: 'a cancelled timer must not fire');
    fires++;
    _onTick();
  }

  @override
  void cancel() => cancelled = true;
}

/// A poll target the test parks mid-run to exercise single-flight.
final class _BlockingRun {
  int runs = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final _pending = <Completer<void>>[];

  Future<void> call() async {
    runs++;
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    final gate = Completer<void>();
    _pending.add(gate);
    try {
      await gate.future;
    } finally {
      inFlight--;
    }
  }

  /// Lets the oldest [count] parked run(s) finish.
  void release([int count = 1]) {
    for (var i = 0; i < count && _pending.isNotEmpty; i++) {
      _pending.removeAt(0).complete();
    }
  }
}

/// Lets every parked microtask/timer callback of a fire-and-forget tick
/// settle before the next assertion.
Future<void> _settle() => pumpEventQueue();

void main() {
  group('CatalogPoller scheduling', () {
    test(
      'start installs ONE periodic timer at the interval; stop cancels it',
      () async {
        final timers = _FakeTimerFactory();
        var runs = 0;
        final poller = CatalogPoller(
          run: () async => runs++,
          timerFactory: timers.call,
        );

        poller
          ..setActive(true)
          ..start(const Duration(seconds: 30));
        expect(timers.timers, hasLength(1));
        expect(timers.single.interval, const Duration(seconds: 30));
        expect(poller.isScheduled, isTrue);

        timers.single.fire();
        await _settle();
        expect(runs, 1);

        poller.stop();
        expect(timers.single.cancelled, isTrue);
        expect(poller.isScheduled, isFalse);
      },
    );

    test('re-start replaces the timer instead of stacking a second one', () {
      final timers = _FakeTimerFactory();
      final poller = CatalogPoller(run: () async {}, timerFactory: timers.call);
      poller.start(const Duration(seconds: 10));
      poller.start(const Duration(seconds: 30));
      expect(timers.timers, hasLength(2));
      expect(timers.timers.first.cancelled, isTrue);
      expect(timers.timers.last.cancelled, isFalse);
    });

    test(
      'a zero/negative interval schedules nothing (explicit ticks only)',
      () async {
        final timers = _FakeTimerFactory();
        var runs = 0;
        final poller = CatalogPoller(
          run: () async => runs++,
          timerFactory: timers.call,
        );
        poller
          ..setActive(true)
          ..start(Duration.zero);
        expect(timers.timers, isEmpty);
        await poller.tick();
        expect(runs, 1);
      },
    );
  });

  group('CatalogPoller single-flight', () {
    test(
      'ticks during a run coalesce into exactly ONE follow-up run',
      () async {
        final timers = _FakeTimerFactory();
        final run = _BlockingRun();
        final poller = CatalogPoller(run: run.call, timerFactory: timers.call);
        poller
          ..setActive(true)
          ..start(const Duration(seconds: 30));

        timers.single.fire();
        await _settle();
        expect(run.runs, 1);
        expect(poller.isRunning, isTrue);

        // A slow store (the production burn): the next intervals elapse while
        // the first pass is still loading. No second concurrent load starts.
        timers.single.fire();
        timers.single.fire();
        timers.single.fire();
        await _settle();
        expect(run.runs, 1, reason: 'a second loadSessions must not start');
        expect(run.maxInFlight, 1);
        expect(poller.isDirty, isTrue);

        run.release();
        await _settle();
        expect(run.runs, 2, reason: 'the coalesced ticks re-run at most once');
        expect(poller.isRunning, isTrue);

        run.release();
        await _settle();
        expect(run.runs, 2);
        expect(poller.isRunning, isFalse);
        expect(poller.isDirty, isFalse);
        expect(run.maxInFlight, 1);
      },
    );

    test('stop() during a run drops the pending follow-up', () async {
      final run = _BlockingRun();
      final poller = CatalogPoller(run: run.call);
      poller
        ..setActive(true)
        ..start(const Duration(seconds: 1));
      final tick = poller.tick();
      await _settle();
      expect(run.runs, 1);
      await poller.tick();
      expect(poller.isDirty, isTrue);

      poller.stop();
      expect(poller.isDirty, isFalse);
      run.release();
      await tick;
      await _settle();
      expect(run.runs, 1);
    });

    test(
      'a throwing run reports through onError and never wedges the poller',
      () async {
        final errors = <Object>[];
        var runs = 0;
        final poller = CatalogPoller(
          run: () async {
            runs++;
            throw StateError('store down');
          },
          onError: (error, stackTrace) {
            errors.add(error);
            expect(stackTrace, isNotNull);
          },
        );
        poller.setActive(true);
        await poller.tick();
        expect(errors, hasLength(1));
        expect(poller.isRunning, isFalse);
        await poller.tick();
        expect(runs, 2);
      },
    );

    test(
      'without onError the failure surfaces to the awaiting caller',
      () async {
        final poller = CatalogPoller(
          run: () async => throw StateError('store down'),
        );
        poller.setActive(true);
        await expectLater(poller.tick(), throwsStateError);
        expect(poller.isRunning, isFalse);
      },
    );
  });

  group('CatalogPoller active gate', () {
    test(
      'ticks while inactive are no-ops; activation refreshes once',
      () async {
        final run = _BlockingRun();
        final poller = CatalogPoller(run: run.call);
        expect(poller.isActive, isFalse, reason: 'disconnected before start');

        await poller.tick();
        await poller.tick();
        expect(
          run.runs,
          0,
          reason: 'disconnected ticks must not read the store',
        );
        expect(poller.isDirty, isFalse);

        poller.setActive(true);
        await _settle();
        expect(run.runs, 0, reason: 'a clean first connect needs no refresh');
        run.release();

        // Link drops while idle: anything may have changed while we were not
        // looking, so the next connect refreshes exactly once.
        poller.setActive(false);
        await poller.tick();
        expect(run.runs, 0);
        poller.setActive(true);
        await _settle();
        expect(run.runs, 1);
        run.release();
        await _settle();

        // Link drops mid-run: the parked pass finishes, the pending dirty
        // flag survives, and the reconnect covers it with one refresh.
        final tick = poller.tick();
        await _settle();
        expect(run.runs, 2);
        poller.setActive(false);
        await poller.tick();
        expect(run.runs, 2);
        run.release();
        await tick;
        await _settle();
        expect(run.runs, 2, reason: 'no follow-up while disconnected');
        expect(poller.isDirty, isTrue);

        poller.setActive(true);
        await _settle();
        expect(run.runs, 3);
        run.release();
        await _settle();
        expect(run.maxInFlight, 1);
      },
    );

    test('redundant setActive calls do not schedule refreshes', () async {
      var runs = 0;
      final poller = CatalogPoller(run: () async => runs++);
      poller.setActive(false);
      poller.setActive(false);
      poller.setActive(true);
      poller.setActive(true);
      await _settle();
      expect(runs, 0);
    });

    test('the periodic timer is gated too (fires while disconnected are '
        'no-ops)', () async {
      final timers = _FakeTimerFactory();
      var runs = 0;
      final poller = CatalogPoller(
        run: () async => runs++,
        timerFactory: timers.call,
      );
      poller.start(const Duration(seconds: 30));
      timers.single.fire();
      await _settle();
      expect(runs, 0);
      poller.setActive(true);
      timers.single.fire();
      await _settle();
      expect(runs, 1);
    });
  });
}
