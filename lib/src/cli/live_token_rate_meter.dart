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
///   bounded). The number hides during the first [_minSpanMs] of a
///   response (too little elapsed time to price print speed honestly —
///   no start-of-stream spike) and decays through streaming pauses (tool
///   waits, approvals) as samples age out, reflecting PRINT speed and
///   hiding once the window is empty — never a stale or zero `t/s`.
/// - **Average** — session output tokens over accumulated ACTIVE-stream
///   time. The numerator is the usage ledger's total output, passed in
///   at read time (one source of truth — the CLI's accumulator grows
///   only from live turns); the denominator accrues only while deltas
///   flow: gaps longer than the grace window are tool waits, approvals,
///   or idle and stop the clock (the `time_spent` exclusion family).
///   [settledAverageTokensPerSecond] freezes that denominator at each
///   response settle for the frame-stable surfaces.
///
/// Pure: injectable clock, O(1) bookkeeping per delta, no IO, no timers —
/// the band re-render rides the existing frame tick (the #802 invariant),
/// and every reader (band segments, classic footer) reads the same
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

/// Spans shorter than this cannot be priced honestly, so the numbers
/// hide instead of lying:
///
/// - the live rate: in the first fraction of a response the window's
///   elapsed span is near zero and `burst / span` prices an honest
///   50 t/s stream at hundreds or thousands of t/s; past this floor the
///   window math takes over.
/// - the averages: sub-millisecond "active time" is scheduler noise
///   between microtasks, not print time (an instant scripted turn can
///   straddle one wall-clock ms) — an average over less than this much
///   measured stream time stays hidden.
const int _minSpanMs = 250;

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
  int _settledActiveMs = 0;

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
    _settledActiveMs = _activeMs;
  }

  /// The live rate over the rolling window, tok/s; null before the first
  /// stream, during the first [_minSpanMs] of a response (a near-zero
  /// span would price an honest stream at an absurd spike), and once the
  /// window has decayed through a pause or idle — hidden, never `0 t/s`
  /// (AC2, AC7).
  double? get tokensPerSecond {
    final nowMs = _now().millisecondsSinceEpoch;
    _prune(nowMs);
    if (_samples.isEmpty) return null;
    final spanMs = nowMs - _samples.first.tMs;
    if (spanMs < _minSpanMs) return null;
    return _windowTokens * 1000 / spanMs;
  }

  /// The session average: [totalOutputTokens] (the usage ledger's total
  /// output — session-lifetime) over the accumulated active-stream time,
  /// tok/s. Null until real output and a measurable amount of stream
  /// time both exist (sub-[_minSpanMs] accruals are scheduler noise) —
  /// on a fresh session that is exactly the first completed turn (AC3).
  double? tokensPerSecondAvg(int totalOutputTokens) {
    if (totalOutputTokens <= 0 || _activeMs < _minSpanMs) return null;
    return totalOutputTokens * 1000 / _activeMs;
  }

  /// [tokensPerSecondAvg] at turn granularity: [totalOutputTokens] (the
  /// ledger total — stable mid-turn, it only moves at stream end) over
  /// the active-stream time as of the last [calibrate]. Frame-stable
  /// between turns; null until the first settled turn produced both
  /// output and a measurable (≥ [_minSpanMs]) amount of stream time.
  double? settledAverageTokensPerSecond(int totalOutputTokens) {
    if (totalOutputTokens <= 0 || _settledActiveMs < _minSpanMs) return null;
    return totalOutputTokens * 1000 / _settledActiveMs;
  }

  /// Session switch: the meter re-warms with the session's own ledger —
  /// the CLI resets both together, so nothing crosses the switch: no
  /// phantom stale rate or borrowed denominator, and the average reappears
  /// with the new session's first settled turn (E6).
  void reset() {
    _samples.clear();
    _windowTokens = 0;
    _messageTokens = 0;
    _factor = 1;
    _lastActivityMs = 0;
    _hasActivity = false;
    _activeMs = 0;
    _settledActiveMs = 0;
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
