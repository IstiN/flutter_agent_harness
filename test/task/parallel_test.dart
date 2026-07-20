import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeConcurrencyLimit', () {
    test('positive values truncate, zero and negatives mean unbounded', () {
      expect(normalizeConcurrencyLimit(4), 4);
      expect(normalizeConcurrencyLimit(4.9), 4);
      expect(normalizeConcurrencyLimit(0), 0);
      expect(normalizeConcurrencyLimit(-3), 0);
      expect(normalizeConcurrencyLimit(double.nan), 0);
      expect(normalizeConcurrencyLimit(double.infinity), 0);
    });
  });

  group('Semaphore', () {
    test('admits up to max concurrently, queues the rest', () async {
      final semaphore = Semaphore(2);
      await semaphore.acquire();
      await semaphore.acquire();
      expect(semaphore.current, 2);

      var thirdAdmitted = false;
      final third = semaphore.acquire().then((_) => thirdAdmitted = true);
      await pumpEventQueue();
      expect(thirdAdmitted, isFalse);
      expect(semaphore.queued, 1);

      semaphore.release();
      await third;
      expect(thirdAdmitted, isTrue);
      expect(semaphore.current, 2);
      semaphore.release();
      semaphore.release();
      expect(semaphore.current, 0);
    });

    test('max <= 0 is unbounded', () async {
      final semaphore = Semaphore(0);
      for (var i = 0; i < 100; i++) {
        await semaphore.acquire();
      }
      expect(semaphore.current, 100);
    });

    test(
      'a cancelled waiter leaves the queue and never gets admitted',
      () async {
        final semaphore = Semaphore(1);
        await semaphore.acquire();

        final source = CancelTokenSource();
        final waiting = semaphore.acquire(source.token);
        // Let the waiter enqueue, then cancel it.
        await pumpEventQueue();
        expect(semaphore.queued, 1);
        source.cancel('done waiting');
        await expectLater(waiting, throwsA(isA<CancelledException>()));
        await pumpEventQueue();
        expect(semaphore.queued, 0);

        // Releasing must not admit the abandoned waiter: the slot goes to a
        // fresh acquire instead (omp issue #3464 semantics).
        semaphore.release();
        expect(semaphore.current, 0);
        await semaphore.acquire();
        expect(semaphore.current, 1);
      },
    );

    test('acquire with a pre-cancelled token throws immediately', () async {
      final semaphore = Semaphore(1);
      final source = CancelTokenSource()..cancel();
      expect(
        () => semaphore.acquire(source.token),
        throwsA(isA<CancelledException>()),
      );
      await pumpEventQueue();
      expect(semaphore.current, 0);
    });

    test('resize up admits queued waiters that now fit', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();
      final admitted = <int>[];
      unawaited(semaphore.acquire().then((_) => admitted.add(1)));
      unawaited(semaphore.acquire().then((_) => admitted.add(2)));
      await pumpEventQueue();
      expect(semaphore.queued, 2);

      semaphore.resize(3);
      await pumpEventQueue();
      expect(admitted, [1, 2]);
      expect(semaphore.current, 3);
    });
  });
}
