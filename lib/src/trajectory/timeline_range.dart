/// Inclusive selection interval used by the trajectory timeline.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// timeline.ts` (`TrajectoryTimeRange`). The domain units depend on the
/// active timeline projection (sequence slots or wall-clock seconds).
library;

/// Inclusive selection in the active timeline projection's domain.
final class TrajectoryTimeRange {
  /// Creates a [TrajectoryTimeRange].
  const TrajectoryTimeRange({required this.start, required this.end});

  /// Inclusive lower bound.
  final double start;

  /// Inclusive upper bound.
  final double end;

  /// Whether [other] shares any point with this range.
  ///
  /// Inclusive on both ends: touching ranges overlap.
  bool overlaps(TrajectoryTimeRange other) =>
      other.start <= end && other.end >= start;
}
