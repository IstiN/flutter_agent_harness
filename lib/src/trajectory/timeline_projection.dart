/// Operation-sequence and recorded-time projections for the trajectory
/// overview.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// timeline.ts` (`deriveTrajectoryTimeline`,
/// `trajectoryTimelineFocusIndexes`, `formatTimelineOffset`), adapted to the
/// phase-1 record model: records carry kind-specific wall-clock anchors
/// instead of one uniform `startedAt`, and `TrajectoryTimeRange` is final, so
/// spans and models hold their own `start`/`end` doubles. Domain units are
/// record slots (sequence) or epoch milliseconds (timed modes).
library;

import 'formatters.dart';
import 'timeline_range.dart';
import 'trajectory_layout.dart';
import 'trajectory_record.dart';

/// Horizontal projection used by the trajectory timeline.
enum TrajectoryTimelineMode {
  /// Equal-width record slots; cells without timing still appear.
  sequence,

  /// Recorded durations with idle gaps compressed out.
  duration,

  /// Zero-width start markers on the real wall clock.
  time,

  /// Recorded durations with real idle gaps kept.
  actual,
}

/// One ledger record projected into the active timeline domain.
final class TrajectoryTimelineSpan {
  /// Creates a [TrajectoryTimelineSpan].
  const TrajectoryTimelineSpan({
    required this.start,
    required this.end,
    required this.index,
    required this.isError,
    required this.kind,
    required this.label,
    required this.lane,
  });

  /// Inclusive lower bound in the active domain.
  final double start;

  /// Inclusive upper bound in the active domain.
  final double end;

  /// 1-based ledger record index this span projects.
  final int index;

  /// Whether the record failed.
  final bool isError;

  /// Kind of the projected record.
  final TrajectoryCellKind kind;

  /// Short record label for tooltips.
  final String label;

  /// Visual lane: 0 system/user/context, 1 message/compacted, 2 tools.
  final int lane;
}

/// One turn boundary in the active timeline domain.
final class TrajectoryTimelineTurnBoundary {
  /// Creates a [TrajectoryTimelineTurnBoundary].
  const TrajectoryTimelineTurnBoundary({
    required this.turn,
    required this.time,
  });

  /// 1-based turn number.
  final int turn;

  /// Left edge of the turn's first span in the active domain.
  final double time;
}

/// Full-domain model used by the overview.
final class TrajectoryTimelineModel {
  /// Creates a [TrajectoryTimelineModel].
  const TrajectoryTimelineModel({
    required this.start,
    required this.end,
    required this.spans,
    required this.turnBoundaries,
  });

  /// Inclusive domain lower bound.
  final double start;

  /// Inclusive domain upper bound.
  final double end;

  /// Spans in ledger order.
  final List<TrajectoryTimelineSpan> spans;

  /// Turn boundaries in ledger order.
  final List<TrajectoryTimelineTurnBoundary> turnBoundaries;
}

/// Format a timeline duration as an integer-millisecond label.
String formatTimelineOffset(double milliseconds) =>
    formatDurationMillis(milliseconds.round());

/// Projects every visible record into a stable three-lane timeline.
///
/// [turns] is the unfiltered trajectory layout; [mode] picks the projection.
/// Returns null when no record is visible.
TrajectoryTimelineModel? deriveTrajectoryTimeline(
  List<TrajectoryTurnModel> turns, [
  TrajectoryTimelineMode mode = TrajectoryTimelineMode.sequence,
]) {
  if (mode != TrajectoryTimelineMode.sequence) {
    return _deriveTimedTimeline(
      turns,
      actualDuration:
          mode == TrajectoryTimelineMode.duration ||
          mode == TrajectoryTimelineMode.actual,
      compressIdle: mode == TrajectoryTimelineMode.duration,
    );
  }
  final spans = <TrajectoryTimelineSpan>[];
  final turnBoundaries = <TrajectoryTimelineTurnBoundary>[];

  for (final turn in turns) {
    final cells = [
      for (final group in turn.groups)
        for (final cell in group.cells)
          if (!_requestOnly(cell)) cell,
    ];
    if (cells.isEmpty) continue;
    final turnNumber = turn.turn;
    if (turnNumber != null) {
      turnBoundaries.add(
        TrajectoryTimelineTurnBoundary(
          turn: turnNumber,
          time: spans.length.toDouble(),
        ),
      );
    }
    for (final cell in cells) {
      spans.add(
        _spanFor(cell, start: spans.length.toDouble(), end: spans.length + 1.0),
      );
    }
  }

  if (spans.isEmpty) return null;
  return TrajectoryTimelineModel(
    start: 0,
    end: spans.length.toDouble(),
    spans: spans,
    turnBoundaries: turnBoundaries,
  );
}

/// Identifies records active at any point inside an inclusive selected
/// interval in the active projection.
Set<int> trajectoryTimelineFocusIndexes(
  List<TrajectoryTurnModel> turns,
  TrajectoryTimeRange range, [
  TrajectoryTimelineMode mode = TrajectoryTimelineMode.sequence,
]) {
  final model = deriveTrajectoryTimeline(turns, mode);
  return {
    for (final span in model?.spans ?? const <TrajectoryTimelineSpan>[])
      if (span.start <= range.end && span.end >= range.start) span.index,
  };
}

/// Raw wall-clock span of one record, before idle compression.
final class _RawSpan {
  _RawSpan({required this.record, required this.start, required this.end});

  final TrajectoryRecord record;
  final double start;
  final double end;

  /// Cumulative idle removed before this span's start (ms).
  double removedIdle = 0;
}

TrajectoryTimelineModel? _deriveTimedTimeline(
  List<TrajectoryTurnModel> turns, {
  required bool actualDuration,
  required bool compressIdle,
}) {
  final timedTurns = _timedTurns(turns);
  final rawSpans = [for (final (_, turnSpans) in timedTurns) ...turnSpans];
  if (rawSpans.isEmpty) return null;
  _markRemovedIdle([...rawSpans]..sort(_compareRawSpans), compressIdle);
  return _projectTimedTurns(timedTurns, actualDuration);
}

/// Timed turns in layout order, dropping request-only and untimed cells.
List<(int?, List<_RawSpan>)> _timedTurns(List<TrajectoryTurnModel> turns) {
  final timedTurns = <(int?, List<_RawSpan>)>[];
  for (final turn in turns) {
    final rawSpans = _turnRawSpans(turn);
    if (rawSpans.isEmpty) continue;
    timedTurns.add((turn.turn, rawSpans));
  }
  return timedTurns;
}

List<_RawSpan> _turnRawSpans(TrajectoryTurnModel turn) {
  final rawSpans = <_RawSpan>[];
  for (final group in turn.groups) {
    for (final cell in group.cells) {
      if (_requestOnly(cell)) continue;
      final range = _cellRange(cell);
      if (range == null) continue;
      rawSpans.add(_RawSpan(record: cell, start: range.$1, end: range.$2));
    }
  }
  return rawSpans;
}

/// Start order, ties broken by end.
int _compareRawSpans(_RawSpan left, _RawSpan right) {
  final byStart = left.start.compareTo(right.start);
  return byStart != 0 ? byStart : left.end.compareTo(right.end);
}

/// Accumulates the idle each span's start has had compressed out, walking
/// spans in [sorted] order.
void _markRemovedIdle(List<_RawSpan> sorted, bool compressIdle) {
  var removedIdle = 0.0;
  double? coveredUntil;
  for (final span in sorted) {
    if (compressIdle && coveredUntil != null && span.start > coveredUntil) {
      removedIdle += span.start - coveredUntil;
    }
    span.removedIdle = removedIdle;
    final end = span.end;
    coveredUntil = coveredUntil == null || end > coveredUntil
        ? end
        : coveredUntil;
  }
}

/// Projects the timed turns into spans plus turn boundaries.
TrajectoryTimelineModel _projectTimedTurns(
  List<(int?, List<_RawSpan>)> timedTurns,
  bool actualDuration,
) {
  final spans = <TrajectoryTimelineSpan>[];
  final turnBoundaries = <TrajectoryTimelineTurnBoundary>[];
  for (final (turnNumber, turnSpans) in timedTurns) {
    final projected = [
      for (final raw in turnSpans)
        _spanFor(
          raw.record,
          start: raw.start - raw.removedIdle,
          end: (actualDuration ? raw.end : raw.start) - raw.removedIdle,
        ),
    ];
    spans.addAll(projected);
    if (turnNumber != null) {
      turnBoundaries.add(
        TrajectoryTimelineTurnBoundary(
          turn: turnNumber,
          time: projected.map((span) => span.start).reduce(_minDouble),
        ),
      );
    }
  }
  return TrajectoryTimelineModel(
    start: spans.map((span) => span.start).reduce(_minDouble),
    end: spans.map((span) => span.end).reduce(_maxDouble),
    spans: spans,
    turnBoundaries: turnBoundaries,
  );
}

/// Visual lane for the closed kind set: tools bottom, model middle, rest top.
int _laneFor(TrajectoryCellKind kind) {
  if (kind == TrajectoryCellKind.tool || kind == TrajectoryCellKind.subtool) {
    return 2;
  }
  if (kind == TrajectoryCellKind.message ||
      kind == TrajectoryCellKind.compacted) {
    return 1;
  }
  return 0;
}

TrajectoryTimelineSpan _spanFor(
  TrajectoryRecord record, {
  required double start,
  required double end,
}) {
  return TrajectoryTimelineSpan(
    start: start,
    end: end,
    index: record.index,
    isError: _isError(record),
    kind: record.kind,
    label: _label(record),
    lane: _laneFor(record.kind),
  );
}

/// Epoch-millisecond [start, end] of a record, null without a wall-clock
/// anchor (in-flight or untimed records drop from timed modes).
///
/// Mirrors the TS `cellRange`: negative recorded durations clamp to zero,
/// and a start without a duration projects to a zero-width start marker.
(double, double)? _cellRange(TrajectoryRecord record) {
  final DateTime? startedAt = switch (record) {
    final TrajectoryAssistantRecord assistant => assistant.stepStartTime,
    final TrajectoryToolRecord tool => tool.startedAt,
    final TrajectoryUserRecord user => user.startedAt,
    final TrajectoryCompactedRecord compacted => compacted.startedAt,
    final TrajectorySystemRecord system => system.time,
    TrajectoryContextRecord() => null,
  };
  if (startedAt == null) return null;
  final durationMs = switch (record) {
    final TrajectoryAssistantRecord assistant =>
      assistant.timeSeconds?.inMilliseconds,
    final TrajectoryToolRecord tool => tool.timeSeconds?.inMilliseconds,
    final TrajectoryCompactedRecord compacted =>
      compacted.timeSeconds?.inMilliseconds,
    _ => null,
  };
  final start = startedAt.millisecondsSinceEpoch.toDouble();
  return (
    start,
    start + (durationMs != null && durationMs > 0 ? durationMs : 0),
  );
}

bool _isError(TrajectoryRecord record) => switch (record) {
  final TrajectoryAssistantRecord assistant => assistant.isError == true,
  final TrajectoryToolRecord tool => tool.isError,
  _ => false,
};

/// Request-only separators carry no ledger record of their own.
bool _requestOnly(TrajectoryRecord record) =>
    record is TrajectoryAssistantRecord && record.requestOnly;

String _label(TrajectoryRecord record) => switch (record) {
  final TrajectoryAssistantRecord assistant => assistant.displayText,
  final TrajectoryToolRecord tool => tool.name,
  final TrajectoryUserRecord user => user.text,
  final TrajectoryContextRecord context => context.text,
  final TrajectoryCompactedRecord compacted => compacted.text,
  final TrajectorySystemRecord system => system.text,
};

double _minDouble(double left, double right) => left < right ? left : right;

double _maxDouble(double left, double right) => left > right ? left : right;
