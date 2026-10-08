import 'package:flutter_agent_harness/src/agent/finalize_gate.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot_builder.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

/// gh-1412 UT-2: the TaskLedger record round-trips — a persisted hidden
/// `task_ledger` custom record replays through the snapshot builder and
/// folds onto the snapshot (last-wins), without ever becoming an unknown
/// ledger row. IT-2's engine half: a legacy session without a ledger
/// degrades cleanly (null field, no unknown row).
void main() {
  final base = DateTime.utc(2026, 1, 1, 12);

  MessageRecord userRecord(String id, {String? parentId}) => MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: base,
    message: UserMessage.text('fixture task'),
  );

  MessageRecord assistantRecord(String id, {String? parentId}) =>
      MessageRecord(
        id: id,
        parentId: parentId,
        timestamp: base.add(const Duration(seconds: 1)),
        message: AssistantMessage(
          content: [TextContent(text: 'done — checklist verified')],
          api: 'anthropic-messages',
          provider: 'anthropic',
          model: 'claude-test',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: base.add(const Duration(seconds: 1)),
        ),
      );

  CustomRecord ledgerRecord(
    String id, {
    String? parentId,
    required TaskLedger ledger,
  }) => CustomRecord(
    id: id,
    parentId: parentId,
    timestamp: base.add(const Duration(seconds: 2)),
    customType: taskLedgerRecordType,
    data: ledger.toJson(),
  );

  final ledger = const TaskLedger(
    items: [
      TaskLedgerItem(
        requirement: 'create script.py',
        command: 'test -f script.py',
        status: TaskLedgerItemStatus.pass,
      ),
      TaskLedgerItem(
        requirement: 'script.py is executable',
        command: 'test -x script.py',
        status: TaskLedgerItemStatus.fixed,
      ),
    ],
  );

  test('a persisted task_ledger record folds onto the snapshot', () {
    final snapshot = TrajectorySnapshotBuilder()
        ..append(userRecord('u1'))
        ..append(assistantRecord('a1', parentId: 'u1'))
        ..append(ledgerRecord('l1', parentId: 'a1', ledger: ledger));
    final state = snapshot.append(
      MessageRecord(
        id: 'a2',
        parentId: 'l1',
        timestamp: base.add(const Duration(seconds: 3)),
        message: AssistantMessage(
          content: const [TextContent(text: 'next turn')],
          api: 'anthropic-messages',
          provider: 'anthropic',
          model: 'claude-test',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: base.add(const Duration(seconds: 3)),
        ),
      ),
    );
    expect(state.taskLedger, isNotNull);
    expect(state.taskLedger!.items, hasLength(2));
    expect(state.taskLedger!.verifiedCount, 2);
    expect(state.taskLedger!.allVerified, isTrue);
    // Hidden record: no unknown row either.
    expect(state.unknownRecordCount, 0);
  });

  test('the LAST ledger record wins wholesale (re-verified after a fix)', () {
    final builder = TrajectorySnapshotBuilder()
      ..append(userRecord('u1'))
      ..append(assistantRecord('a1', parentId: 'u1'));
    builder.append(ledgerRecord('l1', parentId: 'a1', ledger: ledger));
    final revised = const TaskLedger(
      items: [
        TaskLedgerItem(
          requirement: 'create script.py',
          command: 'test -f script.py',
          status: TaskLedgerItemStatus.pass,
        ),
        TaskLedgerItem(
          requirement: 'script.py is executable',
          command: 'test -x script.py',
          status: TaskLedgerItemStatus.fixed,
        ),
        TaskLedgerItem(
          requirement: 'report content',
          command: 'grep -q out.txt script.log',
          status: TaskLedgerItemStatus.pass,
        ),
      ],
    );
    final snapshot = builder.append(
      ledgerRecord('l2', parentId: 'a1', ledger: revised),
    );
    expect(snapshot.taskLedger!.items, hasLength(3));
    expect(snapshot.taskLedger!.toJson(), revised.toJson());
  });

  test('a corrupt ledger payload never throws and never renders unknown', () {
    final builder = TrajectorySnapshotBuilder()
      ..append(userRecord('u1'))
      ..append(assistantRecord('a1', parentId: 'u1'));
    final snapshot = builder.append(
      CustomRecord(
        id: 'l1',
        parentId: 'a1',
        timestamp: base.add(const Duration(seconds: 2)),
        customType: taskLedgerRecordType,
        data: 'garbage',
      ),
    );
    expect(snapshot.taskLedger, isNull);
    expect(snapshot.unknownRecordCount, 0);
  });

  test('legacy session without a ledger degrades cleanly (IT-2)', () {
    final snapshot = TrajectorySnapshotBuilder().appendAll([
      userRecord('u1'),
      assistantRecord('a1', parentId: 'u1'),
    ]);
    expect(snapshot.taskLedger, isNull);
    expect(snapshot.unknownRecordCount, 0);
  });

  test('empty snapshot has no ledger', () {
    expect(TrajectorySnapshot.empty.taskLedger, isNull);
  });
}
