/// User-facing compaction trigger tuning (gh-2098): the `compaction:`
/// yaml keys override the gh-1742 `CompactionSettings.forWindow` curves.
///
/// gh-1742 shipped the hard-coded threshold policy — provider-usage
/// anchored estimates plus proportional headroom
/// (`reserve = min(65536, max(window ~/ 16, legacy curve))`). Three gaps
/// remained: the trigger is not user-configurable, the ~94% default
/// fires late on large-window model classes, and the only lever was
/// lying about the window (`agent.contextWindowCap` also moves the
/// over-window guard). This library adds the config seam:
///
/// - `compaction.triggerRatio` (0 < r < 1, e.g. 0.75): the trigger line
///   sits at `r × window` — the reserve becomes `window − floor(r ×
///   window)`, so EVERY window-derived consumer (both trigger channels,
///   the structured engine's gate, the ctx meter, the spill budget)
///   moves together through the one reserve value.
/// - `compaction.reserveTokens` / `compaction.keepRecentTokens`: direct
///   overrides of the forWindow curve outputs. `triggerRatio` and
///   `reserveTokens` are two spellings of the same knob (the trigger
///   line) — configuring both is a strict config error.
/// - Absent keys → the gh-1742 behavior byte-identically
///   ([applyCompactionTuning] returns the base instance untouched).
///
/// The default decision (documented in `docs/compaction.md` with the
/// benchmark note): the legacy gh-1742 curve stays the default — moving
/// every session to the 0.75–0.80 band multiplies compaction frequency
/// and cost; operators of large-window classes opt in per scope.
///
/// Pure Dart — no dart:io; the yaml surface parses in the CLI config
/// layer (`cli_config.dart`), the application is shared host wiring
/// (`host_wiring.dart`).
library;

import 'dart:math' as math;

import '../exceptions.dart';
import 'compaction.dart' show CompactionSettings;

/// The `compaction:` section's tuning keys (gh-2098). Null fields mean
/// "no opinion" — the forWindow curve stands.
final class CompactionTuning {
  /// Creates a tuning bundle; every field defaults to null (no
  /// override).
  const CompactionTuning({
    this.triggerRatio,
    this.reserveTokens,
    this.keepRecentTokens,
  });

  /// Parses a raw `compaction:` yaml node into the tuning keys. Null
  /// node → null (the section is absent). Unknown keys (`engine`,
  /// `judgeBudgetSeconds`, future keys) are ignored here — the engine
  /// selector and the judge budget have their own parsers.
  ///
  /// Strict: a mistyped value or an out-of-range ratio is a
  /// [ConfigException] naming the key — a typo must surface at boot,
  /// never silently run the default policy (the `compaction:` section
  /// has been strict since issue #148).
  static CompactionTuning? fromSection(Object? node, {required String label}) {
    if (node == null) return null;
    if (node is! Map) {
      throw ConfigException('$label: compaction must be a map, got: $node');
    }
    final tuning = CompactionTuning(
      triggerRatio: _parseTriggerRatio(node['triggerRatio'], label: label),
      reserveTokens: _parseTokens(
        node['reserveTokens'],
        name: 'reserveTokens',
        label: label,
      ),
      keepRecentTokens: _parseTokens(
        node['keepRecentTokens'],
        name: 'keepRecentTokens',
        label: label,
      ),
    );
    _validateExclusivity(
      tuning.triggerRatio,
      tuning.reserveTokens,
      label: label,
    );
    return tuning;
  }

  /// The trigger ratio: fire when the (anchored) context reaches this
  /// fraction of the effective window. Strictly between 0 and 1.
  final double? triggerRatio;

  /// The reserve override (the headroom the trigger fires before),
  /// bypassing the forWindow curve.
  final int? reserveTokens;

  /// The kept-recent region override, bypassing the forWindow curve.
  final int? keepRecentTokens;

  /// Whether no key carries an opinion — the forWindow curve stands.
  bool get isEmpty =>
      triggerRatio == null && reserveTokens == null && keepRecentTokens == null;

  /// The inverse of [isEmpty].
  bool get isNotEmpty => !isEmpty;
}

/// Parses `compaction.triggerRatio` (gh-2098): null when absent; a
/// strictly-between-0-and-1 number otherwise; anything else is a strict
/// [ConfigException] — a typo must surface at boot, not silently keep
/// the legacy curve.
double? _parseTriggerRatio(Object? value, {required String label}) {
  if (value == null) return null;
  if (value is! num) {
    throw ConfigException(
      '$label: compaction.triggerRatio must be a number strictly '
      'between 0 and 1, got: $value',
    );
  }
  final ratio = value.toDouble();
  if (ratio <= 0 || ratio >= 1) {
    throw ConfigException(
      '$label: compaction.triggerRatio must be strictly between 0 and 1, '
      'got: $value',
    );
  }
  return ratio;
}

/// Parses a positive-int `compaction.<name>` token budget (gh-2098);
/// null when absent. Mirrors `parseJudgeBudgetSeconds` (issue #541 —
/// the pattern for `compaction.*` keys).
int? _parseTokens(
  Object? value, {
  required String name,
  required String label,
}) {
  if (value == null) return null;
  if (value is! int) {
    throw ConfigException(
      '$label: compaction.$name must be a positive int, got: $value',
    );
  }
  if (value <= 0) {
    throw ConfigException(
      '$label: compaction.$name must be positive, got: $value',
    );
  }
  return value;
}

void _validateExclusivity(
  double? triggerRatio,
  int? reserveTokens, {
  required String label,
}) {
  if (triggerRatio == null || reserveTokens == null) return;
  throw ConfigException(
    '$label: compaction.triggerRatio and compaction.reserveTokens are '
    'mutually exclusive — the ratio already fixes the trigger line; '
    'configure one of them',
  );
}

/// Merges the config scopes' tuning keys, deepest wins per key
/// (global `~/.fah/config.yaml` < project `.fah/config.yaml` — the same
/// per-key stack the `tools:` section uses). Both absent → null; a
/// merged pair that re-creates the ratio+reserve conflict is a strict
/// [ConfigException] (the scopes may disagree).
CompactionTuning? mergeCompactionTuning({
  CompactionTuning? global,
  CompactionTuning? project,
}) {
  if (global == null && project == null) return null;
  final merged = CompactionTuning(
    triggerRatio: project?.triggerRatio ?? global?.triggerRatio,
    reserveTokens: project?.reserveTokens ?? global?.reserveTokens,
    keepRecentTokens: project?.keepRecentTokens ?? global?.keepRecentTokens,
  );
  _validateExclusivity(
    merged.triggerRatio,
    merged.reserveTokens,
    label: 'resolved compaction tuning',
  );
  return merged;
}

/// Applies the `compaction:` tuning keys over [base] (the resolved
/// forWindow curve, or a host's explicit settings pin) for a model whose
/// (conversation) window is [window].
///
/// Null/empty [tuning] returns [base] IDENTICALLY (same instance) —
/// unset config stays byte-for-byte legacy, the same contract
/// `resolveBenchCompactionSettings` ships.
///
/// The ratio converts to the reserve the trigger consumers already read:
/// `reserve = window − floor(ratio × window)`. `floor` keeps the line AT
/// or BELOW `r × window` — the configured ratio never fires later than
/// configured. The degenerate guards mirror
/// [CompactionSettings.forWindow] so the pipeline invariants survive any
/// override: a reserve over half the window (a ratio below ~0.5) clamps
/// to `window ~/ 4`, a keep over the window clamps to `window ~/ 2` — a
/// pass must always free tokens. Pure.
CompactionSettings applyCompactionTuning(
  CompactionSettings base, {
  required int window,
  CompactionTuning? tuning,
}) {
  if (tuning == null || tuning.isEmpty) return base;
  final ratio = tuning.triggerRatio;
  var reserveTokens = ratio != null
      ? window - (window * ratio).floor()
      : (tuning.reserveTokens ?? base.reserveTokens);
  var keepRecentTokens = tuning.keepRecentTokens ?? base.keepRecentTokens;
  if (reserveTokens >= window ~/ 2) {
    reserveTokens = math.max(128, window ~/ 4);
  }
  if (keepRecentTokens >= window) {
    keepRecentTokens = math.max(256, window ~/ 2);
  }
  return CompactionSettings(
    enabled: base.enabled,
    reserveTokens: reserveTokens,
    keepRecentTokens: keepRecentTokens,
  );
}
