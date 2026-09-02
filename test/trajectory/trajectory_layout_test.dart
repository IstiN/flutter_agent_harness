import 'dart:collection';

import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_layout.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_snapshot_builder.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

TrajectorySnapshot _snapshot(
  List<TrajectoryRecord> records, {
  List<TrajectoryRequestNumber> requests = const [],
  TrajectoryPartialAssistant? partial,
  List<TrajectoryRunningToolCall> runningCalls = const [],
}) {
  return TrajectorySnapshot(
    records: UnmodifiableListView<TrajectoryRecord>(records),
    requests: UnmodifiableListView(requests),
    callSchemas: const {},
    partial: partial,
    runningCalls: UnmodifiableListView(runningCalls),
    recordLocations: const {},
    revision: 1,
  );
}

TrajectoryUserRecord _user(int index, {String text = 'hi'}) {
  return TrajectoryUserRecord(
    index: index,
    recordId: 'u$index',
    text: text,
    opensTurn: true,
    startedAt: _at(index),
  );
}

TrajectoryAssistantRecord _assistant(
  int index, {
  required int turn,
  required int step,
}) {
  return TrajectoryAssistantRecord(
    index: index,
    recordId: 'a$index',
    messageId: 'm$index',
    turn: turn,
    step: step,
    completedTime: _at(index),
  );
}

TrajectoryToolRecord _tool(
  int index,
  String callId, {
  String? parentCallId,
  String name = 'bash',
  Duration? timeSeconds,
}) {
  return TrajectoryToolRecord(
    index: index,
    recordId: 'tool\u0000call\u0000$callId',
    callId: callId,
    parentCallId: parentCallId,
    name: name,
    argsRaw: '{}',
    timeSeconds: timeSeconds,
    startedAt: _at(index),
  );
}

TrajectoryCompactedRecord _compacted(int index) {
  return TrajectoryCompactedRecord(
    index: index,
    recordId: 'cp$index',
    text: 'summary',
    summary: 'summary',
    startedAt: _at(index),
  );
}

TrajectorySystemRecord _system(int index) {
  return TrajectorySystemRecord(
    index: index,
    recordId: 's$index',
    text: 'openai/gpt',
    change: TrajectorySystemChange.modelChange,
    time: _at(index),
  );
}

void main() {
  group('deriveTrajectoryLayout', () {
    test('empty session folds to no turns', () {
      expect(deriveTrajectoryLayout(_snapshot(const [])), isEmpty);
    });

    test('two users separated by a model change fold into two turns', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([
          _user(1),
          _assistant(2, turn: 1, step: 1),
          _system(3),
          _user(4),
          _assistant(5, turn: 2, step: 1),
        ]),
      );
      expect(layout.map((turn) => turn.turn), [1, 2]);
    });

    test(
      'one user with two assistant+tool steps folds into two step groups',
      () {
        final layout = deriveTrajectoryLayout(
          _snapshot([
            _user(1),
            _assistant(2, turn: 1, step: 1),
            _tool(3, 'c1'),
            _assistant(4, turn: 1, step: 2),
            _tool(5, 'c2'),
          ]),
        );
        expect(layout, hasLength(1));
        final groups = layout.single.groups;
        expect(groups.map((g) => g.kind), [
          TrajectoryGroupKind.message,
          TrajectoryGroupKind.step,
          TrajectoryGroupKind.step,
        ]);
        expect(groups[1].stepNumber, 1);
        expect(groups[1].cells.map((c) => c.kind), [
          TrajectoryCellKind.message,
          TrajectoryCellKind.tool,
        ]);
        expect(groups[2].stepNumber, 2);
      },
    );

    test('three sequential tool calls land as siblings', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([
          _user(1),
          _assistant(2, turn: 1, step: 1),
          _tool(3, 'c1'),
          _tool(4, 'c2', name: 'read'),
          _tool(5, 'c3'),
        ]),
      );
      final step = layout.single.groups[1];
      expect(step.cells, hasLength(4));
      expect(step.cells.skip(1).map((c) => c.kind), [
        TrajectoryCellKind.tool,
        TrajectoryCellKind.tool,
        TrajectoryCellKind.tool,
      ]);
    });

    test('subtool rows keep subtool kind and follow the parent', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([
          _assistant(1, turn: 1, step: 1),
          _tool(2, 'c1'),
          _tool(3, 'c2', parentCallId: 'c1', name: 'grep'),
        ]),
      );
      final cells = layout.single.groups.single.cells;
      expect(cells.map((c) => c.kind), [
        TrajectoryCellKind.message,
        TrajectoryCellKind.tool,
        TrajectoryCellKind.subtool,
      ]);
    });

    test('compaction rows become standalone sections between turns', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([
          _user(1),
          _assistant(2, turn: 1, step: 1),
          _compacted(3),
          _user(4),
          _assistant(5, turn: 2, step: 1),
        ]),
      );
      expect(layout.map((section) => section.turn), [1, null, 2]);
      expect(layout[1].groups.single.kind, TrajectoryGroupKind.compaction);
    });

    test('request-only separators appear for unrepresented requests', () {
      final layout = deriveTrajectoryLayout(
        _snapshot(
          const [],
          requests: [
            TrajectoryRequestNumber(
              seq: 1,
              turn: 1,
              step: 1,
              purpose: TrajectoryRequestPurpose.assistant,
              provider: 'anthropic',
              model: 'claude-test',
              status: TrajectoryRequestStatus.running,
              startedAt: _at(0),
            ),
          ],
        ),
      );
      final cell =
          layout.single.groups.single.cells.single as TrajectoryAssistantRecord;
      expect(cell.requestOnly, isTrue);
      expect(cell.turn, 1);
      expect(cell.step, 1);
      expect(cell.timeSeconds, isNull);
      expect(cell.isError, isNull);
    });

    test('failed request-only separators surface the error', () {
      final layout = deriveTrajectoryLayout(
        _snapshot(
          const [],
          requests: [
            TrajectoryRequestNumber(
              seq: 1,
              turn: 1,
              step: 1,
              purpose: TrajectoryRequestPurpose.assistant,
              provider: 'anthropic',
              model: 'claude-test',
              status: TrajectoryRequestStatus.failed,
              startedAt: _at(0),
              completedAt: _at(5),
            ),
          ],
        ),
      );
      final cell =
          layout.single.groups.single.cells.single as TrajectoryAssistantRecord;
      expect(cell.isError, isTrue);
      expect(cell.timeSeconds, const Duration(seconds: 5));
    });

    test('running calls append into their step group without durations', () {
      final layout = deriveTrajectoryLayout(
        _snapshot(
          [_user(1), _assistant(2, turn: 1, step: 1)],
          runningCalls: [
            TrajectoryRunningToolCall(
              callId: 'c9',
              name: 'grep',
              turn: 1,
              step: 1,
            ),
          ],
        ),
      );
      final step = layout.single.groups[1];
      final running = step.cells.last as TrajectoryToolRecord;
      expect(running.kind, TrajectoryCellKind.tool);
      expect(running.callId, 'c9');
      expect(running.result, '');
      expect(running.timeSeconds, isNull);
    });

    test('partial anchors a trailing user turn without emitting cells', () {
      final layout = deriveTrajectoryLayout(
        _snapshot(
          [_user(1), _assistant(2, turn: 1, step: 1), _user(3)],
          partial: TrajectoryPartialAssistant(
            messageId: 'p1',
            turn: 2,
            step: 1,
            blocks: const [],
          ),
        ),
      );
      expect(layout.map((section) => section.turn), [1, 2]);
      expect(layout[1].groups.single.kind, TrajectoryGroupKind.message);
      expect(layout[1].groups.single.cells, hasLength(1));
    });

    test('wall-span description spans call to result and counts tools', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([
          _assistant(1, turn: 1, step: 1),
          _tool(2, 'c1', timeSeconds: const Duration(seconds: 2)),
        ]),
      );
      expect(layout.single.groups.single.description, '3,000 bash');
    });

    test('tool histograms dedupe by name with counts', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([
          _assistant(1, turn: 1, step: 1),
          _tool(2, 'c1'),
          _tool(3, 'c2'),
          _tool(4, 'c3', name: 'read'),
        ]),
      );
      final description = layout.single.groups.single.description;
      expect(description, contains('bash×2'));
      expect(description, contains('read'));
    });

    test('message-only groups carry no description', () {
      final layout = deriveTrajectoryLayout(_snapshot([_user(1)]));
      expect(layout.single.groups.single.description, isNull);
    });

    test('orphan turn-0 tool cells fold into Turn 1 prefix', () {
      final layout = deriveTrajectoryLayout(
        _snapshot([_tool(1, 'c1'), _user(2), _assistant(3, turn: 1, step: 1)]),
      );
      expect(layout, hasLength(1));
      expect(layout.single.turn, 1);
      expect(
        layout.single.groups.first.cells.first.kind,
        TrajectoryCellKind.tool,
      );
    });

    test('record identities survive prepending older records', () {
      MessageRecord userRecord(String id) => MessageRecord(
        id: id,
        parentId: null,
        timestamp: _at(0),
        message: UserMessage.text('hi', timestamp: _at(0)),
      );
      MessageRecord assistantRecord(String id, {String? parentId}) =>
          MessageRecord(
            id: id,
            parentId: parentId,
            timestamp: _at(1),
            message: AssistantMessage(
              content: const [TextContent(text: 'answer')],
              api: 'anthropic-messages',
              provider: 'anthropic',
              model: 'claude-test',
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: _at(1),
            ),
          );
      final short = TrajectorySnapshotBuilder()
        ..append(userRecord('u1'))
        ..append(assistantRecord('a1', parentId: 'u1'));
      final long = TrajectorySnapshotBuilder()
        ..append(_systemLikeRecord())
        ..append(userRecord('u1'))
        ..append(assistantRecord('a1', parentId: 'u1'));
      final shortIds = short.build().records.map((r) => r.recordId).toSet();
      final longIds = long.build().records.map((r) => r.recordId).toSet();
      expect(shortIds, isNot(same(longIds)));
      for (final id in shortIds) {
        expect(longIds, contains(id));
      }
      final shortLayout = deriveTrajectoryLayout(short.build());
      final longLayout = deriveTrajectoryLayout(long.build());
      expect(
        shortLayout.single.turn,
        longLayout.single.turn,
        reason: 'turn structure is independent of prepended history',
      );
    });
  });
}

/// A model-change session record for prepend tests.
ModelChangeRecord _systemLikeRecord() => ModelChangeRecord(
  id: 'm0',
  parentId: null,
  timestamp: _at(0),
  provider: 'openai',
  modelId: 'gpt-test',
);
