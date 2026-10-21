/// The live token-rate meter (issue #1762): one pure-Dart accumulator fed
/// by agent stream events, read by every status surface.
///
/// Two numbers, one meter:
///
/// - **Live** — a rolling-window rate over the last [windowMs] of stream
///   deltas (text, thinking, and tool-call argument fragments alike).
///   Chars convert at pi's 4-chars-per-token heuristic, recalibrated by
///   the provider's real per-response `usage.output` at stream end
///   ([calibrate]); the char→token factor is clamped so a single outlier
///   response can never swing the estimate arbitrarily (AC4, drift
///   bounded). The window decays through streaming pauses (tool waits,
///   approvals): samples age out, so the number reflects PRINT speed and
///   hides once the window is empty — never a stale or zero `t/s`.
/// - **Average** — session output tokens over accumulated ACTIVE-stream
///   time. The numerator is the usage ledger's total output, passed in at
///   read time (one source of truth; a resumed session's restored ledger
///   comes free — E4); the denominator accrues only while deltas flow:
///   gaps longer than the grace window are tool waits, approvals, or
///   idle and stop the clock (the `time_spent` exclusion family).
///
/// Pure: injectable clock, O(1) bookkeeping per delta, no IO, no timers —
/// the band re-render rides the existing frame tick (the #802 invariant),
/// and both renderers (band segments + classic footer) read the same
/// instance. Model-authored text never enters here: only char counts and
/// usage numbers (the gh-1446 rule).
library;

import 'dart:collection' show Queue;

/// Chars → tokens, pi's conservative heuristic (the `estimateTokens`
/// basis — deliberately not a tokenizer; calibration bounds the drift).
const int _charsPerToken = 4;

/// Streaming gaps longer than this stop the average's clock: real print
/// bursts arrive within hundreds of ms of each other; longer silences are
/// tool execution, approvals, or idle (AC7).
const int _gapGraceMs = 1000;

/// The calibration clamp: one response moves the char→token factor by at
/// most 4× up or 4× down from the current base (AC4, drift bounded).
const double _minCalibrationFactor = 0.25;
const double _maxCalibrationFactor = 4.0;

/// The default rolling window for the live rate, ms — the
/// `tui.statusLine.rateWindowMs` fallback (card open question 2: 5s).
const int kDefaultRateWindowMs = 5000;

/// One windowed print burst: [tokens] (estimated) arrived at [tMs].
final class _RateSample {
  _RateSample(this.tMs, this.tokens);

  final int tMs;
  final double tokens;
}

/// The live/average token-rate accumulator behind the `token_rate` and
/// `token_rate_avg` segments and the classic footer's rate part.
final class LiveTokenRateMeter {
  /// [now] is injectable for exact tests; defaults to the wall clock.
  /// [windowMs] is the live rolling window (`tui.statusLine.rateWindowMs`).
  LiveTokenRateMeter({
    DateTime Function()? now,
    this.windowMs = kDefaultRateWindowMs,
  }) : _now = now ?? DateTime.now;

  /// The rolling window for the live rate, ms.
  final int windowMs;

  final DateTime Function() _now;
  final Queue<_RateSample> _samples = Queue();
  double _windowTokens = 0;
  double _messageTokens = 0;
  double _factor = 1;
  int _lastActivityMs = 0;
  bool _hasActivity = false;
  int _activeMs = 0;

  /// A text/thinking/tool-call-argument delta of [chars] characters
  /// arrived. O(1); non-positive counts are skipped, never fatal (E5).
  void observeDelta(int chars) {
    if (chars <= 0) return;
    _count(chars / _charsPerToken * _factor);
  }

  /// A new assistant message stream began — resets the per-message
  /// estimate baseline the end-of-message top-up works from.
  void startMessage() {
    _messageTokens = 0;
  }

  /// The assistant message completed; [estimatedTokens] is the
  /// whole-message `estimateTokens` figure. Providers that arrive whole
  /// (no deltas at all) still yield a live rate: the unobserved remainder
  /// lands as one arrival burst (AC6).
  void endMessage(int estimatedTokens) {
    final topUp = estimatedTokens - _messageTokens;
    if (topUp > 0) _count(topUp);
    if (estimatedTokens > _messageTokens) {
      _messageTokens = estimatedTokens.toDouble();
    }
  }

  /// The response's provider-reported output tokens arrived (once per
  /// response, at stream end). Recalibrates the char→token factor for the
  /// NEXT message's live estimate (AC4).
  void calibrate(int outputTokens) {
    if (outputTokens > 0 && _messageTokens > 0) {
      _factor = (_factor * outputTokens / _messageTokens)
          .clamp(_minCalibrationFactor, _maxCalibrationFactor)
          .toDouble();
    }
    _messageTokens = 0;
  }

  /// The live rate over the rolling window, tok/s; null when no sample is
  /// fresh enough (before the first stream, or decayed through a pause /
  /// idle) — hidden, never `0 t/s` (AC2, AC7).
  double? get tokensPerSecond {
    final nowMs = _now().millisecondsSinceEpoch;
    _prune(nowMs);
    if (_samples.isEmpty) return null;
    final spanMs = nowMs - _samples.first.tMs;
    if (spanMs <= 0) return null;
    return _windowTokens * 1000 / spanMs;
  }

  /// The session average: [totalOutputTokens] (the usage ledger's total
  /// output — session-lifetime) over the accumulated active-stream time,
  /// tok/s. Null until real output and real stream time both exist — on
  /// a fresh session that is exactly the first completed turn (AC3).
  double? tokensPerSecondAvg(int totalOutputTokens) {
    if (totalOutputTokens <= 0 || _activeMs <= 0) return null;
    return totalOutputTokens * 1000 / _activeMs;
  }

  /// Session switch or restore: the meter re-warms in the new session
  /// (E6 — no phantom stale rate across a kill/resume; the average's
  /// numerator re-enters via the restored ledger).
  void reset() {
    _samples.clear();
    _windowTokens = 0;
    _messageTokens = 0;
    _factor = 1;
    _lastActivityMs = 0;
    _hasActivity = false;
    _activeMs = 0;
  }

  /// Records [tokens] estimated output at the current clock: active-time
  /// accrual (gap-capped), the per-message baseline, and the window.
  void _count(double tokens) {
    final nowMs = _now().millisecondsSinceEpoch;
    if (_hasActivity) {
      final gap = nowMs - _lastActivityMs;
      _activeMs += gap <= 0 ? 0 : (gap > _gapGraceMs ? _gapGraceMs : gap);
    }
    _lastActivityMs = nowMs;
    _hasActivity = true;
    _messageTokens += tokens;
    _samples.addLast(_RateSample(nowMs, tokens));
    _windowTokens += tokens;
    _prune(nowMs);
  }

  /// Ages samples out of the rolling window (amortized O(1) per delta).
  void _prune(int nowMs) {
    final cutoff = nowMs - windowMs;
    while (_samples.isNotEmpty && _samples.first.tMs <= cutoff) {
      _windowTokens -= _samples.removeFirst().tokens;
    }
  }
}
