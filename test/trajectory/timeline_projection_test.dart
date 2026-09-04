import 'package:flutter_agent_harness/src/trajectory/timeline_projection.dart';
import 'package:flutter_agent_harness/src/trajectory/timeline_range.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_layout.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:test/test.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int seconds) => _base.add(Duration(seconds: seconds));

double _ms(DateTime time) => time.millisecondsSinceEpoch.toDouble();

TrajectoryTurnModel _turn(int? number, List<TrajectoryRecord> cells) {
  return TrajectoryTurnModel(
    turn: number,
    groups: [
      TrajectoryGroupModel(kind: TrajectoryGroupKind.message, cells: cells),
    ],
  );
}

TrajectoryUserRecord _user(int index) {
  return TrajectoryUserRecord(
    index: index,
    recordId: 'u$index',
    text: 'hi',
    opensTurn: true,
    startedAt: _at(index),
  );
}

TrajectoryAssistantRecord _assistant(
  int index, {
  required int turn,
  required int step,
  DateTime? startedAt,
  Duration? timeSeconds,
  bool? isError,
  bool requestOnly = false,
  String displayText = 'answer',
}) {
  return TrajectoryAssistantRecord(
    index: index,
    recordId: 'a$index',
    messageId: 'm$index',
    turn: turn,
    step: step,
    stepStartTime: startedAt,
    timeSeconds: timeSeconds,
    isError: isError,
    requestOnly: requestOnly,
    displayText: displayText,
  );
}

TrajectoryToolRecord _tool(
  int index,
  String callId, {
  String? parentCallId,
  DateTime? startedAt,
  Duration? timeSeconds,
  bool isError = false,
}) {
  return TrajectoryToolRecord(
    index: index,
    recordId: 'tool\u0000call\u0000$callId',
    callId: callId,
    parentCallId: parentCallId,
    name: 'bash',
    argsRaw: '{}',
    startedAt: startedAt,
    timeSeconds: timeSeconds,
    isError: isError,
  );
}

/// Two-second assistant, a ten-second idle gap, then a four-second tool.
List<TrajectoryTurnModel> _gapFixture() {
  return [
    _turn(1, [
      _assistant(
        1,
        turn: 1,
        step: 1,
        startedAt: _at(0),
        timeSeconds: const Duration(seconds: 2),
      ),
      _tool(
        2,
        't1',
        startedAt: _at(12),
        timeSeconds: const Duration(seconds: 4),
      ),
    ]),
  ];
}

void main() {
  group('deriveTrajectoryTimeline (sequence)', () {
    test('gives every cell one equal-width slot regardless of duration', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _user(1),
          _assistant(
            2,
            turn: 1,
            step: 1,
            startedAt: _at(0),
            timeSeconds: const Duration(seconds: 5),
          ),
          _tool(
            3,
            't1',
            startedAt: _at(1),
            timeSeconds: const Duration(seconds: 60),
          ),
        ]),
      ])!;
      expect(model.start, 0);
      expect(model.end, 3);
      expect(
        [for (final span in model.spans) span.end - span.start],
        [1.0, 1.0, 1.0],
      );
      expect([for (final span in model.spans) span.index], [1, 2, 3]);
    });

    test('cells without any timing still appear', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _assistant(1, turn: 1, step: 1),
          TrajectoryContextRecord(index: 2, recordId: 'c2', text: 'ctx'),
        ]),
      ])!;
      expect(model.end, 2);
      expect(
        [for (final span in model.spans) span.kind],
        [TrajectoryCellKind.message, TrajectoryCellKind.context],
      );
    });

    test('turn boundary sits at the turn first span left edge', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [_user(1), _assistant(2, turn: 1, step: 1)]),
        _turn(2, [_assistant(3, turn: 2, step: 1)]),
      ])!;
      expect(
        [for (final boundary in model.turnBoundaries) boundary.turn],
        [1, 2],
      );
      expect(
        [for (final boundary in model.turnBoundaries) boundary.time],
        [0.0, 2.0],
        reason: 'turn 2 opens where its first span starts',
      );
    });

    test('standalone compaction sections add spans but no boundary', () {
      final model = deriveTrajectoryTimeline([
        _turn(null, [
          TrajectoryCompactedRecord(
            index: 1,
            recordId: 'cp1',
            text: 'summary',
            summary: 'summary',
          ),
        ]),
      ])!;
      expect(model.spans, hasLength(1));
      expect(model.turnBoundaries, isEmpty);
    });

    test('requestOnly separators are skipped', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _assistant(1, turn: 1, step: 1, requestOnly: true, startedAt: _at(0)),
          _assistant(2, turn: 1, step: 2),
        ]),
      ])!;
      expect([for (final span in model.spans) span.index], [2]);
      expect(model.turnBoundaries.single.time, 0);
    });

    test('empty turns project to null', () {
      expect(deriveTrajectoryTimeline(const []), isNull);
      expect(
        deriveTrajectoryTimeline([
          _turn(1, [_assistant(1, turn: 1, step: 1, requestOnly: true)]),
        ]),
        isNull,
      );
    });

    test('is the default mode', () {
      final turns = [
        _turn(1, [_assistant(1, turn: 1, step: 1)]),
      ];
      final defaulted = deriveTrajectoryTimeline(turns)!;
      final explicit = deriveTrajectoryTimeline(
        turns,
        TrajectoryTimelineMode.sequence,
      )!;
      expect(defaulted.start, explicit.start);
      expect(defaulted.end, explicit.end);
      expect(
        [for (final span in defaulted.spans) span.index],
        [for (final span in explicit.spans) span.index],
      );
    });
  });

  group('deriveTrajectoryTimeline (duration)', () {
    test('keeps recorded widths and compresses idle cumulatively', () {
      final model = deriveTrajectoryTimeline(
        _gapFixture(),
        TrajectoryTimelineMode.duration,
      )!;
      final assistant = model.spans[0];
      final tool = model.spans[1];
      expect(assistant.start, _ms(_at(0)));
      expect(assistant.end, _ms(_at(2)));
      expect(
        tool.start,
        _ms(_at(2)),
        reason: 'the ten-second idle gap is removed before the tool',
      );
      expect(tool.end - tool.start, 4000);
      expect(model.start, _ms(_at(0)));
      expect(model.end, _ms(_at(6)));
    });

    test('is overlap-safe: cumulative offset only removes true idle', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _assistant(
            1,
            turn: 1,
            step: 1,
            startedAt: _at(0),
            timeSeconds: const Duration(seconds: 2),
          ),
          _tool(
            2,
            't1',
            startedAt: _at(12),
            timeSeconds: const Duration(seconds: 4),
          ),
          _tool(
            3,
            't2',
            startedAt: _at(13),
            timeSeconds: const Duration(seconds: 8),
          ),
        ]),
      ], TrajectoryTimelineMode.duration)!;
      final tool1 = model.spans[1];
      final tool2 = model.spans[2];
      expect(tool1.start, _ms(_at(2)));
      expect(tool1.end, _ms(_at(6)));
      expect(
        tool2.start,
        _ms(_at(3)),
        reason: 'overlap with tool 1 removes no extra idle',
      );
      expect(tool2.end - tool2.start, 8000);
      expect(model.end, _ms(_at(11)));
      for (final span in model.spans) {
        expect(span.start, lessThanOrEqualTo(span.end));
      }
    });

    test('zero recorded duration projects to a start marker', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _tool(
            '0'.codeUnitAt(0),
            't1',
            startedAt: _at(5),
            timeSeconds: Duration.zero,
          ),
        ]),
      ], TrajectoryTimelineMode.duration)!;
      expect(model.spans.single.start, model.spans.single.end);
    });
  });

  group('deriveTrajectoryTimeline (time)', () {
    test('keeps real wall-clock gaps with zero-width spans', () {
      final model = deriveTrajectoryTimeline(
        _gapFixture(),
        TrajectoryTimelineMode.time,
      )!;
      for (final span in model.spans) {
        expect(span.start, span.end, reason: 'time mode renders start markers');
      }
      expect(model.spans[0].start, _ms(_at(0)));
      expect(model.spans[1].start, _ms(_at(12)));
      expect(model.start, _ms(_at(0)));
      expect(model.end, _ms(_at(12)));
    });
  });

  group('deriveTrajectoryTimeline (actual)', () {
    test('keeps recorded widths and real gaps', () {
      final model = deriveTrajectoryTimeline(
        _gapFixture(),
        TrajectoryTimelineMode.actual,
      )!;
      final assistant = model.spans[0];
      final tool = model.spans[1];
      expect(assistant.start, _ms(_at(0)));
      expect(assistant.end, _ms(_at(2)));
      expect(tool.start, _ms(_at(12)));
      expect(tool.end - tool.start, 4000);
      expect(model.end, _ms(_at(16)));
    });
  });

  group('timed vs sequence visibility', () {
    test('assistant without startedAt drops from timed modes only', () {
      final turns = [
        _turn(1, [
          _assistant(1, turn: 1, step: 1),
          _assistant(
            2,
            turn: 1,
            step: 2,
            startedAt: _at(3),
            timeSeconds: const Duration(seconds: 1),
          ),
        ]),
      ];
      expect(deriveTrajectoryTimeline(turns)!.spans.map((span) => span.index), [
        1,
        2,
      ]);
      for (final mode in TrajectoryTimelineMode.values) {
        if (mode == TrajectoryTimelineMode.sequence) continue;
        expect(
          deriveTrajectoryTimeline(
            turns,
            mode,
          )!.spans.map((span) => span.index),
          [2],
          reason: '$mode drops untimed cells',
        );
      }
    });

    test('requestOnly separators are skipped in timed modes too', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _assistant(
            1,
            turn: 1,
            step: 1,
            requestOnly: true,
            startedAt: _at(0),
            timeSeconds: const Duration(seconds: 9),
          ),
        ]),
      ], TrajectoryTimelineMode.duration);
      expect(model, isNull);
    });
  });

  group('trajectoryTimelineFocusIndexes', () {
    /// Assistant [0s,1s], then overlapping tools A [2s,12s] and B [4s,8s].
    List<TrajectoryTurnModel> overlapping() {
      return [
        _turn(1, [
          _assistant(
            1,
            turn: 1,
            step: 1,
            startedAt: _at(0),
            timeSeconds: const Duration(seconds: 1),
          ),
          _tool(
            2,
            'a',
            startedAt: _at(2),
            timeSeconds: const Duration(seconds: 10),
          ),
          _tool(
            3,
            'b',
            startedAt: _at(4),
            timeSeconds: const Duration(seconds: 4),
          ),
        ]),
      ];
    }

    test('sequence slots select by slot interval', () {
      final turns = overlapping();
      expect(
        trajectoryTimelineFocusIndexes(
          turns,
          const TrajectoryTimeRange(start: 1.5, end: 2.5),
        ),
        {2, 3},
        reason: 'inclusive bounds touch tool A slot end and tool B slot start',
      );
      expect(
        trajectoryTimelineFocusIndexes(
          turns,
          const TrajectoryTimeRange(start: 0.5, end: 1.5),
        ),
        {1, 2},
        reason: 'inclusive bounds overlap the touching slot edges',
      );
    });

    test('timed overlap selects exactly the records active inside', () {
      final turns = overlapping();
      expect(
        trajectoryTimelineFocusIndexes(
          turns,
          TrajectoryTimeRange(start: _ms(_at(5)), end: _ms(_at(6))),
          TrajectoryTimelineMode.actual,
        ),
        {2, 3},
      );
      expect(
        trajectoryTimelineFocusIndexes(
          turns,
          TrajectoryTimeRange(
            start: _ms(_base.add(const Duration(milliseconds: 500))),
            end: _ms(_base.add(const Duration(milliseconds: 500))),
          ),
          TrajectoryTimelineMode.actual,
        ),
        {1},
      );
    });

    test('inclusive boundaries count touching spans', () {
      final turns = overlapping();
      expect(
        trajectoryTimelineFocusIndexes(
          turns,
          TrajectoryTimeRange(start: _ms(_at(12)), end: _ms(_at(12))),
          TrajectoryTimelineMode.actual,
        ),
        {2},
        reason: 'tool A ends exactly at 12s',
      );
      expect(
        trajectoryTimelineFocusIndexes(
          turns,
          TrajectoryTimeRange(
            start: _ms(_base.add(const Duration(milliseconds: 1500))),
            end: _ms(_base.add(const Duration(milliseconds: 1500))),
          ),
          TrajectoryTimelineMode.actual,
        ),
        isEmpty,
      );
    });

    test('empty layout focuses nothing', () {
      expect(
        trajectoryTimelineFocusIndexes(
          const [],
          const TrajectoryTimeRange(start: 0, end: 10),
        ),
        isEmpty,
      );
    });
  });

  group('span flags', () {
    test('error spans are flagged', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _assistant(1, turn: 1, step: 1, isError: true),
          _assistant(2, turn: 1, step: 2),
          _tool(3, 't1', isError: true),
          _user(4),
        ]),
      ])!;
      expect(
        [for (final span in model.spans) span.isError],
        [true, false, true, false],
      );
    });

    test('lanes and labels follow the kind', () {
      final model = deriveTrajectoryTimeline([
        _turn(1, [
          _user(1),
          _assistant(2, turn: 1, step: 1, displayText: 'answer'),
          _tool(3, 't1'),
          _tool(4, 't2', parentCallId: 't1'),
        ]),
      ])!;
      expect([for (final span in model.spans) span.lane], [0, 1, 2, 2]);
      expect(
        [for (final span in model.spans) span.label],
        ['hi', 'answer', 'bash', 'bash'],
      );
    });
  });

  group('formatTimelineOffset', () {
    test('formats integer milliseconds with thousands separators', () {
      expect(formatTimelineOffset(0), '0');
      expect(formatTimelineOffset(1234.6), '1,235');
      expect(formatTimelineOffset(12000), '12,000');
      expect(formatTimelineOffset(-5), '0');
    });
  });
}
