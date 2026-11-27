/// Per-session calibration of the fixed request-overhead estimate
/// (gh-2411).
///
/// [OverheadCalibration] is a pure value: the multiplier the provider's
/// own usage report earned for the unanchored request estimate. The
/// heuristic density (`overheadCharsPerToken`) is honest on average and
/// wrong per provider — tokenizers differ, and a system prompt full of
/// paths, ids or non-English prose is denser than English. The first
/// valid usage of a session settles the question (`fromUsage`); the
/// host carries the value forward, so the ctx meter, the over-window
/// guard and the compaction trigger stay honest on UNANCHORED estimates
/// too: a fresh or resumed session, and every turn after a compaction
/// zeroed the usage anchors. No policy lives here — the derivation from
/// a transcript is `deriveOverheadCalibration` in `token_estimation.dart`.
library;

/// The measured multiplier over the unanchored request estimate.
final class OverheadCalibration {
  /// Creates a calibration with [ratio].
  const OverheadCalibration(this.ratio, {this.measured = false});

  /// No calibration: the heuristic stands as is.
  static const uncalibrated = OverheadCalibration(1.0);

  /// A provider reporting FEWER tokens than the heuristic may LOWER the
  /// meter — down to this floor. An under-read estimate silently overruns
  /// the window (the gh-2411 incident), but an over-read one is not free
  /// either: the owner's live test (glm-5.3-flash, 34 tools) charged
  /// 15,792 tokens where the heuristic read 24,348 (ratio 0.65), and
  /// clamped at 1.0 that over-read held the soft-window regime on every
  /// prompt — no pass ever ran and the context grew to 114%. Only the
  /// FIRST, overhead-dominated anchor moves the meter
  /// (`deriveOverheadCalibration`); the floor keeps a degenerate report
  /// from erasing the overhead.
  static const double minRatio = 0.6;

  /// A degenerate usage report (a units mismatch, a summed field) must
  /// not multiply the window away.
  static const double maxRatio = 4.0;

  /// The multiplier over the unanchored request estimate.
  final double ratio;

  /// Whether a provider usage report produced this value. A session
  /// consumes its FIRST valid usage and keeps the result — later anchors
  /// (a transcript far larger than the overhead, diluting the ratio
  /// toward 1.0) never overwrite it, and a measurement that clamped to
  /// [minRatio] still counts as taken.
  final bool measured;

  /// Whether the provider's usage moved the heuristic at all.
  bool get isCalibrated => ratio != 1.0;

  /// The calibration from ONE request: [promptTokens] is what the
  /// provider charged for the request (input + cache reads/writes, i.e.
  /// its total minus the output), [unanchoredRequestTokens] our
  /// heuristic estimate of the same request. Clamped to
  /// [minRatio]..[maxRatio]; a zero or degenerate input yields
  /// [uncalibrated].
  factory OverheadCalibration.fromUsage({
    required int promptTokens,
    required int unanchoredRequestTokens,
  }) {
    if (promptTokens <= 0 || unanchoredRequestTokens <= 0) {
      return uncalibrated;
    }
    return OverheadCalibration(
      (promptTokens / unanchoredRequestTokens).clamp(minRatio, maxRatio),
      measured: true,
    );
  }

  /// The calibrated token count of an [unanchoredTokens] estimate (the
  /// estimate itself when uncalibrated; never negative).
  int apply(int unanchoredTokens) => unanchoredTokens <= 0
      ? unanchoredTokens
      : (unanchoredTokens * ratio).ceil();
}
