import 'package:flutter_agent_harness/src/trajectory/timeline_range.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:test/test.dart';

void main() {
  group('TrajectoryTimeRange.overlaps', () {
    const unit = TrajectoryTimeRange(start: 0, end: 10);

    test('overlaps inside the range', () {
      expect(
        unit.overlaps(const TrajectoryTimeRange(start: 5, end: 6)),
        isTrue,
      );
    });

    test('overlaps when only touching the inclusive start boundary', () {
      expect(
        unit.overlaps(const TrajectoryTimeRange(start: -3, end: 0)),
        isTrue,
      );
    });

    test('overlaps when only touching the inclusive end boundary', () {
      expect(
        unit.overlaps(const TrajectoryTimeRange(start: 10, end: 12)),
        isTrue,
      );
    });

    test('does not overlap disjoint ranges', () {
      expect(
        unit.overlaps(const TrajectoryTimeRange(start: 10.5, end: 20)),
        isFalse,
      );
      expect(
        unit.overlaps(const TrajectoryTimeRange(start: -2, end: -0.5)),
        isFalse,
      );
    });

    test('contains the full range and is contained by it', () {
      expect(
        unit.overlaps(const TrajectoryTimeRange(start: -5, end: 15)),
        isTrue,
      );
      expect(
        const TrajectoryTimeRange(start: -5, end: 15).overlaps(unit),
        isTrue,
      );
    });
  });

  group('trajectoryRecordId', () {
    test('prefers the explicit record id', () {
      expect(
        trajectoryRecordId(
          kind: 'user',
          recordId: 'rec-1',
          callId: 'call-1',
          sourceSeq: 7,
          index: 3,
        ),
        'rec-1',
      );
    });

    test('falls back to the call id', () {
      expect(
        trajectoryRecordId(kind: 'tool', callId: 'call-9', index: 4),
        'tool\u0000call\u0000call-9',
      );
    });

    test('falls back to the source seq', () {
      expect(
        trajectoryRecordId(kind: 'system', sourceSeq: 12, index: 5),
        'system\u0000seq\u000012',
      );
    });

    test('falls back to the index', () {
      expect(
        trajectoryRecordId(kind: 'user', index: 8),
        'user\u0000index\u00008',
      );
    });

    test('does not treat an empty call id as absent', () {
      expect(
        trajectoryRecordId(kind: 'tool', callId: '', index: 1),
        'tool\u0000call\u0000',
      );
    });
  });

  group('TrajectoryCellKind', () {
    test('matches the closed set from the TS reference', () {
      expect(TrajectoryCellKind.values.map((kind) => kind.name), [
        'system',
        'user',
        'context',
        'compacted',
        'message',
        'tool',
        'subtool',
      ]);
    });
  });
}
