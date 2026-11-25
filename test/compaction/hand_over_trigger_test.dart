// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the post-run soft trigger, its hysteresis and the
/// `compacting` gate (AC11/AC12, IT-18, D8/D9). Pure host-side logic.

library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  const window = 100000;
  const settings = CompactionSettings(
    enabled: true,
    reserveTokens: 20000,
    keepRecentTokens: 10000,
  );
  final hysteresis = HandOverHysteresis(turns: 3);

  group('soft trigger line', () {
    test('default = hard line − 5 % of the window', () {
      expect(softTriggerTokens(window: window, settings: settings), 75000);
    });

    test('`compaction.softRatio` fixes the line at ratio × window', () {
      expect(
        softTriggerTokens(window: window, settings: settings, softRatio: 0.6),
        60000,
      );
    });

    test('IT-18 fresh session: the band [soft, hard) fires post-run', () {
      expect(
        softTriggerReached(
          tokens: 74000,
          window: window,
          settings: settings,
          hysteresis: hysteresis,
        ),
        isFalse,
      );
      expect(
        softTriggerReached(
          tokens: 76000,
          window: window,
          settings: settings,
          hysteresis: hysteresis,
        ),
        isTrue,
      );
    });

    test('IT-18 hysteresis: after a run the band is muted for N turns', () {
      hysteresis.recordRun();
      expect(hysteresis.allowSoft, isFalse);
      expect(
        softTriggerReached(
          tokens: 76000,
          window: window,
          settings: settings,
          hysteresis: hysteresis,
        ),
        isFalse,
        reason: 'the band is muted right after a run',
      );
      // Hard pressure is never suppressed.
      expect(
        softTriggerReached(
          tokens: 81000,
          window: window,
          settings: settings,
          hysteresis: hysteresis,
        ),
        isTrue,
      );
      hysteresis.onTurn();
      hysteresis.onTurn();
      expect(hysteresis.allowSoft, isFalse);
      hysteresis.onTurn();
      expect(hysteresis.allowSoft, isTrue);
      expect(
        softTriggerReached(
          tokens: 76000,
          window: window,
          settings: settings,
          hysteresis: hysteresis,
        ),
        isTrue,
      );
    });

    test('a disabled compaction never fires; the default turns are 3', () {
      const off = CompactionSettings(
        enabled: false,
        reserveTokens: 1,
        keepRecentTokens: 1,
      );
      expect(
        softTriggerReached(
          tokens: 99000,
          window: window,
          settings: off,
          hysteresis: HandOverHysteresis(),
        ),
        isFalse,
      );
      expect(HandOverHysteresis().turns, handOverHysteresisTurnsDefault);
    });
  });

  group('CompactingGate (D9/E33)', () {
    test(
      'idle: wait resolves at once; run executes and clears the flag',
      () async {
        final gate = CompactingGate();
        expect(gate.isCompacting, isFalse);
        await gate.wait();
        final result = await gate.run(() async => 42);
        expect(result, 42);
        expect(gate.isCompacting, isFalse);
      },
    );

    test('IT-19 a prompt arriving mid-run waits for the compaction', () async {
      final gate = CompactingGate();
      final release = Completer<void>();
      var waited = false;
      final run = gate.run(() async {
        await release.future;
        return 'compacted';
      });
      expect(gate.isCompacting, isTrue);
      final prompt = gate.wait().then((_) => waited = true);
      await Future<void>.delayed(Duration.zero);
      expect(waited, isFalse);
      release.complete();
      expect(await run, 'compacted');
      await prompt;
      expect(waited, isTrue);
    });

    test(
      'a second run while one is in flight joins it — never two writers',
      () async {
        final gate = CompactingGate();
        final release = Completer<void>();
        var bodyRuns = 0;
        final first = gate.run(() async {
          bodyRuns++;
          await release.future;
        });
        var secondStarted = false;
        final second = gate.run(() async {
          secondStarted = true;
          bodyRuns++;
        });
        await Future<void>.delayed(Duration.zero);
        expect(bodyRuns, 1);
        expect(secondStarted, isFalse);
        release.complete();
        await first;
        await second;
        expect(bodyRuns, 2);
        expect(gate.isCompacting, isFalse);
      },
    );

    test(
      'review R1: a QUEUED run registers before it waits — isCompacting '
      'stays true across the hand-over and wait() covers the queued body',
      () async {
        final gate = CompactingGate();
        final first = Completer<void>();
        final second = Completer<void>();
        final order = <String>[];
        final r1 = gate.run(() async {
          order.add('1:start');
          await first.future;
          order.add('1:end');
        });
        final r2 = gate.run(() async {
          order.add('2:start');
          expect(gate.isCompacting, isTrue);
          await second.future;
          order.add('2:end');
        });
        final waited = gate.wait().then((_) => order.add('waited'));
        await Future<void>.delayed(Duration.zero);
        expect(order, ['1:start']);
        expect(gate.isCompacting, isTrue, reason: 'the queued run counts');

        first.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(order, ['1:start', '1:end', '2:start']);
        expect(
          gate.isCompacting,
          isTrue,
          reason: 'the queued body is THE active compaction while it runs',
        );
        expect(order, isNot(contains('waited')));

        second.complete();
        await r1;
        await r2;
        await waited;
        expect(order, ['1:start', '1:end', '2:start', '2:end', 'waited']);
        expect(gate.isCompacting, isFalse);
      },
    );

    test('a throwing body still releases the gate', () async {
      final gate = CompactingGate();
      await expectLater(
        gate.run(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(gate.isCompacting, isFalse);
      await gate.wait();
    });

    test('IT-19b a JOINED body stays registered — isCompacting holds and '
        'wait() cannot resolve mid-join (gh-2407)', () async {
      final gate = CompactingGate();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final first = gate.run(() async {
        firstStarted.complete();
        await releaseFirst.future;
        return 'first';
      });
      await firstStarted.future;
      expect(gate.isCompacting, isTrue);

      // The second run joins the in-flight one; its body executes AFTER
      // the first completed — as a compaction of its own.
      var joinedBodySawCompacting = false;
      final second = gate.run(() async {
        joinedBodySawCompacting = gate.isCompacting;
        return 'second';
      });
      var waiterDone = false;
      final waiter = gate.wait().then((_) => waiterDone = true);

      // Let the join happen (first settles, the joined body runs) without
      // releasing anything: the gate must stay closed across the hand-off
      // and the waiter must not resolve while the joined body is running.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
        expect(waiterDone, isFalse, reason: 'microtask turn $i');
      }
      releaseFirst.complete();
      expect(await first, 'first');
      expect(await second, 'second');
      expect(joinedBodySawCompacting, isTrue);
      await waiter;
      expect(waiterDone, isTrue);
      expect(gate.isCompacting, isFalse);
    });
  });
}
