// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Test doubles for the hosts' periodic catalog poll (gh-2410): a
/// hand-fired timer seam and a catalog store whose loads can be parked
/// mid-flight — the production burn was a pass slower than its interval.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/catalog_poller.dart';
import 'package:flutter_agent_harness/src/session/session_catalog.dart';
import 'package:test/test.dart';

/// Catalog store counting loads; with [gate] set every load parks until
/// [release], so a test can hold a pass open across several ticks.
final class GatedCatalogStore implements SessionCatalogStore {
  var loads = 0;
  var gate = false;
  final _parked = <Completer<void>>[];

  /// Lets every parked load finish and settles the follow-up microtasks.
  Future<void> release() async {
    final pending = List.of(_parked);
    _parked.clear();
    for (final completer in pending) {
      completer.complete();
    }
    await pumpEventQueue();
  }

  @override
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  }) async {
    loads++;
    if (gate) {
      final completer = Completer<void>();
      _parked.add(completer);
      await completer.future;
    }
    return const [];
  }
}

/// Hand-fired stand-in for `Timer.periodic` (the hosts' timer seam).
final class FakeTimers {
  final created = <FakePeriodicTimer>[];

  /// The one live (not cancelled) timer; fails the test when there is not
  /// exactly one, so a stacked schedule cannot hide.
  FakePeriodicTimer get live {
    final alive = created.where((timer) => !timer.cancelled).toList();
    expect(alive, hasLength(1));
    return alive.single;
  }

  /// The factory to pass as `catalogPollTimerFactory`.
  CancelableTimer call(Duration interval, void Function() onTick) {
    final timer = FakePeriodicTimer(interval, onTick);
    created.add(timer);
    return timer;
  }

  /// Fires the live timer [count] times.
  void fire([int count = 1]) {
    for (var i = 0; i < count; i++) {
      live.fire();
    }
  }
}

final class FakePeriodicTimer implements CancelableTimer {
  FakePeriodicTimer(this.interval, this.onTick);

  final Duration interval;
  final void Function() onTick;
  var cancelled = false;

  void fire() {
    expect(cancelled, isFalse, reason: 'a cancelled timer never fires');
    onTick();
  }

  @override
  void cancel() => cancelled = true;
}
