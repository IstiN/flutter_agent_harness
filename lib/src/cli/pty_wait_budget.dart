/// Load-aware PTY wait budgets (issue #1391).
///
/// The PTY-family merge-blocking legs — `PTY/CLI integration (linux, shard
/// N/3)` and `Terminal visual (PTY screenshots, PR)` — pin their wait
/// budgets (harness defaults 10-90 s, per-test overrides up to 60 s) for a
/// QUIET runner. When the SM dispatches several validations in one wave
/// (refresh waves supersede PR heads mid-run), the hosted ubuntu-24.04-arm
/// pool runs 2+ full CI runs concurrently; every CLI spawn, mock-LLM round
/// trip, compaction pass and TUI repaint stretches, and a single test pops
/// its budget inside an otherwise-green 60-70-test shard. Four drilled
/// runs (issue family #1391: 114115713413, 114064133950, 113385178088,
/// 114167806111) all show exactly that signature — one TimeoutException or
/// one raced-capture red, everything else passing — and each red parks the
/// victim PR behind `validation_failed` for a ~25 min re-validation slot.
///
/// The seam: the two merge-blocking CI legs export `FA_PTY_BUDGET_SCALE`
/// and every PTY-harness wait budget is multiplied by the parsed scale.
/// Local runs and the nightly (unsupervised flake evidence must stay
/// unscaled — quarantine/un-quarantine repeat-run proofs read its raw
/// verdicts) leave the variable unset and keep the exact legacy budgets.
///
/// MUST STAY FLUTTER-FREE: imported by the plain-dart root PTY harness
/// (`test/integration/pty_harness.dart`) AND the flutter_app visual harness
/// (`flutter_app/test/cli_visual/cli_visual_harness.dart`) — same shape as
/// `omp_reg_scenarios.dart` (issue #810).
///
/// Pure functions with injected env — nothing here reads
/// `Platform.environment` (the harnesses pass their own value), so every
/// branch is unit-provable without a PTY
/// (`test/cli/pty_wait_budget_test.dart`).
library;

/// The env var the merge-blocking PTY legs set to stretch harness waits.
const kPtyWaitBudgetScaleEnv = 'FA_PTY_BUDGET_SCALE';

/// The floor: a scale below 1 would SHRINK budgets and could only manufacture
/// new flakes — resolve clamps up to this.
const _minScale = 1.0;

/// The ceiling: a runaway value (e.g. `100`) would turn real hangs into
/// 50-minute waits and blow the job-level timeouts — resolve clamps down.
const _maxScale = 10.0;

/// Resolves the wait-budget scale from [envValue] (the raw
/// `FA_PTY_BUDGET_SCALE` value, or null when unset).
///
/// Blank and unparseable values read as 1.0 — a typo in the workflow env
/// must never red a leg (same fail-open rule as the FA_BIN seam's
/// empty-string-is-unset reading). Valid values clamp to
/// `[_minScale, _maxScale]`.
double resolvePtyWaitBudgetScale({String? envValue}) {
  final raw = envValue?.trim();
  if (raw == null || raw.isEmpty) return _minScale;
  final parsed = double.tryParse(raw);
  if (parsed == null || parsed.isNaN) return _minScale;
  if (parsed < _minScale) return _minScale;
  if (parsed > _maxScale) return _maxScale;
  return parsed;
}

/// Multiplies a wait [budget] by [scale]. A sub-1.0 scale is treated as
/// 1.0 (defensive — [resolvePtyWaitBudgetScale] already clamps, this only
/// keeps the multiplication honest if the two are ever used apart).
Duration scalePtyWaitBudget(Duration budget, double scale) {
  if (scale <= _minScale) return budget;
  return Duration(microseconds: (budget.inMicroseconds * scale).round());
}
