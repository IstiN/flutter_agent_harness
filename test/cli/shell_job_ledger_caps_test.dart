import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:flutter_agent_harness/src/cli/shell_job_board.dart';
import 'package:flutter_agent_harness/src/session/ledger_caps.dart';
import 'package:test/test.dart';

TaskBlock _card(
  String id, {
  String command = 'sleep 2',
  TaskBlockState state = TaskBlockState.running,
  String? detail,
}) => TaskBlock(
  id: id,
  kind: 'bash',
  state: state,
  label: command,
  detail: detail,
);

void main() {
  group('gh-1073: persisted shell_job_registry records are bounded', () {
    test('records keep only the newest cards', () {
      final board = ShellJobBoard();
      for (var i = 1; i <= shellJobBoardPersistedCardCap + 20; i++) {
        board.start(_card('sh-$i'));
        board.settle('sh-$i', state: TaskBlockState.done, elapsed: 1.0);
      }
      final records = board.toRecords();
      expect(records.length, shellJobBoardPersistedCardCap);
      // The OLDEST cards drop — rehydration only needs the recent tail
      // (live cards + recently settled) for the never-shows-running rule.
      expect(records.first['id'], 'sh-${20 + 1}');
      expect(records.last['id'], 'sh-${shellJobBoardPersistedCardCap + 20}');
    });

    test('a rehydrated board from capped records is still terminal-safe', () {
      final board = ShellJobBoard();
      for (var i = 1; i <= shellJobBoardPersistedCardCap + 5; i++) {
        board.start(_card('sh-$i'));
      }
      // Nothing settled: on reload all persisted cards demote to lost.
      final rehydrated = ShellJobBoard.rehydrated(board.toRecords());
      for (final card in rehydrated.allCards) {
        expect(taskBlockStateIsTerminal(card.state), isTrue);
      }
      expect(rehydrated.allCards, hasLength(shellJobBoardPersistedCardCap));
    });

    test('record label and detail strings are truncated', () {
      final huge = 'h' * (ledgerTextCapChars * 10);
      final board = ShellJobBoard()
        ..start(_card('sh-1', command: huge))
        ..settle(
          'sh-1',
          state: TaskBlockState.failed,
          elapsed: 1.0,
          detail: huge,
        );
      final records = board.toRecords();
      expect((records.single['label'] as String).length, ledgerTextCapChars);
      expect(
        (records.single['detail'] as String).length,
        lessThanOrEqualTo(ledgerTextCapChars),
      );
      // The LIVE board keeps the full label for rendering — the cap is
      // the persisted record's alone.
      expect(board.allCards.single.label.length, huge.length);
    });
  });

  group('LedgerSnapshotDeduper (gh-1073)', () {
    test('skips a byte-identical snapshot, persists changes', () {
      final deduper = LedgerSnapshotDeduper();
      expect(deduper.shouldPersist('{"a":1}'), isTrue);
      deduper.confirmPersisted();
      expect(deduper.shouldPersist('{"a":1}'), isFalse);
      expect(deduper.shouldPersist('{"a":2}'), isTrue);
      deduper.confirmPersisted();
      expect(deduper.shouldPersist('{"a":2}'), isFalse);
    });

    test('a failed write does not mark the snapshot persisted', () {
      final deduper = LedgerSnapshotDeduper();
      expect(deduper.shouldPersist('{"a":1}'), isTrue);
      // The append failed (and the persist chain swallows the error by
      // design): the retried IDENTICAL snapshot must not be skipped —
      // otherwise the ledger silently misses a state until the next
      // mutation.
      deduper.revertFailedPersist();
      expect(deduper.shouldPersist('{"a":1}'), isTrue);
      deduper.confirmPersisted();
      expect(deduper.shouldPersist('{"a":1}'), isFalse);
    });

    test('reset re-persists the same payload (fresh session)', () {
      final deduper = LedgerSnapshotDeduper();
      deduper.shouldPersist('snap');
      deduper.confirmPersisted();
      deduper.reset();
      expect(deduper.shouldPersist('snap'), isTrue);
    });
  });

  group('LedgerSnapshotThrottle (gh-1590)', () {
    test('the first snapshot persists; N mutations inside the window '
        'coalesce behind the trailing flush', () {
      var now = DateTime(2026, 10, 13, 12);
      final throttle = LedgerSnapshotThrottle(
        minInterval: const Duration(seconds: 30),
        clock: () => now,
      );
      expect(
        throttle.shouldPersistNow(),
        isTrue,
        reason: 'a never-persisted ledger appends its first snapshot',
      );
      throttle.confirmPersisted();
      // gh-1590 acceptance shape: N shell-job state changes inside the
      // window must leave ONE snapshot, not N — the deduper only
      // suppressed byte-identical payloads, so 1,635 distinct board
      // states once appended 1,635 records.
      for (var i = 1; i <= 25; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(
          throttle.shouldPersistNow(),
          isFalse,
          reason: 'mutation $i inside the window coalesces',
        );
      }
      expect(
        throttle.hasPending,
        isTrue,
        reason: 'the coalesced state reserves a trailing flush',
      );
    });

    test('the trailing flush becomes due one window after the first '
        'refused mutation, then the window closes again', () {
      var now = DateTime(2026, 10, 13, 12);
      final throttle = LedgerSnapshotThrottle(
        minInterval: const Duration(seconds: 30),
        clock: () => now,
      );
      throttle.shouldPersistNow();
      throttle.confirmPersisted();
      now = now.add(const Duration(seconds: 10));
      expect(throttle.shouldPersistNow(), isFalse);
      // Not due yet — the pending mutation is only 10s old.
      now = now.add(const Duration(seconds: 10));
      expect(throttle.poll(), isFalse);
      // One full window after the refusal (t=10 → t=40) the trailing
      // flush may land.
      now = now.add(const Duration(seconds: 20));
      expect(throttle.poll(), isTrue);
      throttle.confirmPersisted();
      expect(throttle.poll(), isFalse);
      expect(throttle.hasPending, isFalse);
      // The window closed again with the flush.
      expect(throttle.shouldPersistNow(), isFalse);
    });

    test('a mutation after a full open window persists immediately '
        '(steady state ≈ one snapshot per window)', () {
      var now = DateTime(2026, 10, 13, 12);
      final throttle = LedgerSnapshotThrottle(
        minInterval: const Duration(seconds: 30),
        clock: () => now,
      );
      expect(throttle.shouldPersistNow(), isTrue);
      throttle.confirmPersisted();
      now = now.add(const Duration(seconds: 31));
      expect(
        throttle.shouldPersistNow(),
        isTrue,
        reason:
            'an idle window re-opens without needing the trailing '
            'flush',
      );
      throttle.confirmPersisted();
      expect(throttle.hasPending, isFalse);
    });

    test('reset re-opens the window (fresh session)', () {
      var now = DateTime(2026, 10, 13, 12);
      final throttle = LedgerSnapshotThrottle(
        minInterval: const Duration(seconds: 30),
        clock: () => now,
      );
      throttle.shouldPersistNow();
      throttle.confirmPersisted();
      now = now.add(const Duration(seconds: 1));
      expect(throttle.shouldPersistNow(), isFalse);
      throttle.reset();
      expect(
        throttle.shouldPersistNow(),
        isTrue,
        reason:
            'a rehydrated board persists its first snapshot at '
            'once — the deduper reset next to it depends on that',
      );
    });

    test('a refusal arms the production trailing leg, and its flush '
        're-owns the window', () async {
      var fired = 0;
      late final LedgerSnapshotThrottle throttle;
      throttle = LedgerSnapshotThrottle(
        minInterval: const Duration(milliseconds: 40),
        onFlushDue: () {
          fired++;
          // The production wiring persists and confirms from the flush —
          // the window restarts with the flushed snapshot.
          throttle.confirmPersisted();
        },
      );
      expect(throttle.shouldPersistNow(), isTrue);
      throttle.confirmPersisted();
      // A refusal arms the leg…
      expect(throttle.shouldPersistNow(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        fired,
        1,
        reason:
            'the trailing leg lands the coalesced '
            'snapshot when the mutations stop',
      );
      expect(
        throttle.hasPending,
        isFalse,
        reason: 'the flush consumed the pending reservation',
      );
    });

    test('dispose disarms the trailing leg mid-flight', () async {
      var fired = 0;
      final throttle = LedgerSnapshotThrottle(
        minInterval: const Duration(milliseconds: 40),
        onFlushDue: () => fired++,
      );
      expect(throttle.shouldPersistNow(), isTrue);
      throttle.confirmPersisted();
      expect(throttle.shouldPersistNow(), isFalse);
      // The shutdown flush disposes BEFORE the leg can fire.
      throttle.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        fired,
        0,
        reason:
            'a disposed throttle never fires — the '
            'shutdown flush replaces it',
      );
    });
  });
}
