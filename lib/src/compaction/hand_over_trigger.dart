/// The post-run soft trigger of the merged hand-over (GOAL #2394 D8/D9 —
/// AC11/AC12): the soft pressure line, the hysteresis that keeps a run
/// from firing on every turn of the `[soft, hard)` band, and the
/// `compacting` gate that queues a prompt arriving while the post-run
/// call is in flight. Pure Dart — hosts own the counters.
///
/// - PRE-FLIGHT stays hard-only (`shouldCompact` — over the line → fold
///   before the request); the hard guard is never suppressed.
/// - POST-RUN fires the soft line: the bucket the main request just
///   warmed is still hot, so the merged call reads it from cache.
/// - Hysteresis: after any compaction run the soft trigger stays
///   suppressed until pressure reaches the hard line or N user turns
///   passed (`compaction.handOver.hysteresisTurns`, default 3).
/// - No cache-miss latch: a cold bucket never changes the mode — it is
///   a report signal only.
library;

import 'dart:async';
import 'dart:math' show max;

import 'compaction.dart' show CompactionSettings, shouldCompact;

/// Default `compaction.handOver.hysteresisTurns`.
const int handOverHysteresisTurnsDefault = 3;

/// The soft line's default distance below the hard line, as a share of
/// the window (`softRatio` unset): hard − 5 % of the window.
const double softRatioDefaultGap = 0.05;

/// The soft trigger line in tokens: `floor(softRatio × window)` when the
/// key is set, else the hard line minus [softRatioDefaultGap] of the
/// window (never below 1).
int softTriggerTokens({
  required int window,
  required CompactionSettings settings,
  double? softRatio,
}) {
  if (softRatio != null) return max(1, (window * softRatio).floor());
  final hard = window - settings.reserveTokens;
  return max(1, hard - (window * softRatioDefaultGap).floor());
}

/// Whether the POST-RUN soft trigger fires for [tokens]: at or over the
/// soft line, and either over the hard line (pressure the hysteresis
/// never suppresses) or past the hysteresis window.
bool softTriggerReached({
  required int tokens,
  required int window,
  required CompactionSettings settings,
  double? softRatio,
  required HandOverHysteresis hysteresis,
}) {
  if (!settings.enabled) return false;
  if (tokens >=
      softTriggerTokens(
        window: window,
        settings: settings,
        softRatio: softRatio,
      )) {
    return shouldCompact(tokens, window, settings) || hysteresis.allowSoft;
  }
  return false;
}

/// The soft-trigger hysteresis (D8): counts user turns, remembers the
/// turn of the last compaction run.
final class HandOverHysteresis {
  /// Creates a hysteresis with the configured turn window.
  HandOverHysteresis({this.turns = handOverHysteresisTurnsDefault});

  /// User turns that must pass after a run before the soft line may
  /// fire again (`compaction.handOver.hysteresisTurns`). Writable so a
  /// host that re-resolves its settings per run (the Flutter app) can
  /// keep ONE counter across config flips.
  int turns;

  int _turns = 0;
  int _turnsAtRun = -1 << 30;

  /// A user turn started (hosts call it at every prompt).
  void onTurn() => _turns++;

  /// A compaction run happened (success or failure alike — the band
  /// must not re-fire every turn over a failing endpoint).
  void recordRun() => _turnsAtRun = _turns;

  /// Turns passed since the last run (saturating).
  int get turnsSinceRun => max(0, _turns - _turnsAtRun);

  /// Whether the soft line may fire: no run yet, or the window passed.
  bool get allowSoft => turnsSinceRun >= turns;
}

/// The host-side holder of the two stateful pieces (CLI and Flutter
/// alike): the hysteresis and the `compacting` gate. Pure state — the
/// host owns WHEN to call [softReached] (post-run only, AC11) and
/// [recordRun] (after any compaction run, success or failure alike).
final class HandOverTriggerState {
  /// Creates the state; [turns] is `compaction.handOver.hysteresisTurns`
  /// (null → the default).
  HandOverTriggerState({int? turns})
    : hysteresis = HandOverHysteresis(
        turns: turns ?? handOverHysteresisTurnsDefault,
      );

  /// The soft-trigger hysteresis.
  final HandOverHysteresis hysteresis;

  /// The `compacting` gate — one run at a time, prompts wait.
  final CompactingGate gate = CompactingGate();

  /// A user turn started (hosts call it at every user prompt).
  void onTurn() => hysteresis.onTurn();

  /// A compaction run happened.
  void recordRun() => hysteresis.recordRun();

  /// Whether the POST-RUN soft line fires for [tokens].
  bool softReached({
    required int tokens,
    required int window,
    required CompactionSettings settings,
    double? softRatio,
  }) => softTriggerReached(
    tokens: tokens,
    window: window,
    settings: settings,
    softRatio: softRatio,
    hysteresis: hysteresis,
  );
}

/// The `compacting` flag (D9 — E33): ONE compaction at a time, and a
/// prompt arriving while the post-run call is in flight WAITS for it
/// ([wait]) instead of racing a second `_refreshState` or losing a
/// persist. Not a lock on the prompt — the prompt's own pre-flight then
/// measures the fresh basis.
final class CompactingGate {
  Completer<void>? _active;

  /// Whether a compaction run is in flight.
  bool get isCompacting => _active != null;

  /// Runs [body] as THE compaction; a nested/second run while one is in
  /// flight is joined to the first's completion instead of starting
  /// (never two writers).
  Future<T> run<T>(Future<T> Function() body) async {
    final active = _active;
    if (active != null) {
      await active.future;
      return body();
    }
    final completer = Completer<void>();
    _active = completer;
    try {
      return await body();
    } finally {
      _active = null;
      completer.complete();
    }
  }

  /// Resolves when no compaction is in flight (immediately when idle).
  Future<void> wait() async {
    while (true) {
      final active = _active;
      if (active == null) return;
      await active.future;
    }
  }
}
