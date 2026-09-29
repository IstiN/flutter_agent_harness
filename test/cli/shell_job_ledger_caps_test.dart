import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:flutter_agent_harness/src/cli/shell_job_board.dart';
import 'package:flutter_agent_harness/src/session/ledger_caps.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
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

    test('a rehydrated board from capped records is still terminal-safe',
        () {
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
      final huge = 'h' * (ledgetTextCapChars * 10);
      final board = ShellJobBoard()
        ..start(_card('sh-1', command: huge))
        ..settle(
          'sh-1',
          state: TaskBlockState.failed,
          elapsed: 1.0,
          detail: huge,
        );
      final records = board.toRecords();
      expect((records.single['label'] as String).length,
          ledgetTextCapChars);
      expect((records.single['detail'] as String).length,
          lessThanOrEqualTo(ledgetTextCapChars));
      // The LIVE board keeps the full label for rendering — the cap is
      // the persisted record's alone.
      expect(board.allCards.single.label.length, huge.length);
    });
  });

  group('LedgerSnapshotDeduper (gh-1073)', () {
    test('skips a byte-identical snapshot, persists changes', () {
      final deduper = LedgerSnapshotDeduper();
      expect(deduper.shouldPersist('{"a":1}'), isTrue);
      expect(deduper.shouldPersist('{"a":1}'), isFalse);
      expect(deduper.shouldPersist('{"a":2}'), isTrue);
    });

    test('reset re-persists the same payload (fresh session)', () {
      final deduper = LedgerSnapshotDeduper();
      deduper.shouldPersist('snap');
      deduper.reset();
      expect(deduper.shouldPersist('snap'), isTrue);
    });
  });
}
