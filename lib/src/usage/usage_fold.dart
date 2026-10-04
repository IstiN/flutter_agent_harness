/// The pure fold math of the usage ledger (gh-1241, UT-2/UT-3): turning a
/// sequence of per-request observations into [UsageSegment]s and a
/// [UsageLedger] — no IO, no clock, fully deterministic.
///
/// A [FoldRequest] is one provider request as the fold sees it: the model
/// it ran on (I5's `byModel` key), the token counts (reported or
/// estimated), and that request's own provenance. Segment and total
/// `source` markers are DERIVED, never assigned: a scope is `reported`
/// when every contributing request was provider-reported, `estimated`
/// when none were, and `mixed` otherwise (I3 — estimated never silently
/// substitutes reported).
library;

import 'usage_ledger.dart';

/// One provider request observed on the session chain.
final class FoldRequest {
  /// Creates a [FoldRequest].
  const FoldRequest({
    required this.model,
    required this.input,
    required this.output,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.reasoning,
    required this.source,
  });

  /// The model id the request ran on (provider-controlled string).
  final String model;

  /// Prompt (input) tokens — reported or estimated (see [source]).
  final int input;

  /// Completion (output) tokens — reported or estimated (see [source]).
  final int output;

  /// Input tokens served from a provider cache.
  final int cacheRead;

  /// Input tokens written into a provider cache.
  final int cacheWrite;

  /// Reasoning tokens, when the provider reported them.
  final int? reasoning;

  /// This request's own provenance: [UsageSource.reported] or
  /// [UsageSource.estimated] (never `mixed` — that is a scope-level
  /// marker derived by [UsageFolder]).
  final UsageSource source;
}

/// Folds [FoldRequest] sequences into ledger segments/totals.
final class UsageFolder {
  /// Creates a [UsageFolder].
  const UsageFolder();

  /// Folds one segment's [requests] (chain order irrelevant — addition is
  /// commutative and every field is a sum).
  UsageSegment foldSegment(
    int index,
    List<FoldRequest> requests, {
    DateTime? openedAt,
    DateTime? closedAt,
  }) {
    var totals = UsageModelTotals.zero;
    var byModel = <String, UsageModelTotals>{};
    var sawReported = false;
    var sawEstimated = false;
    for (final request in requests) {
      final slice = UsageModelTotals(
        requests: 1,
        input: request.input,
        output: request.output,
        cacheRead: request.cacheRead,
        cacheWrite: request.cacheWrite,
        reasoning: request.reasoning,
      );
      totals = totals + slice;
      byModel = mergeUsageByModel(byModel, {
        request.model: slice,
      });
      sawReported = sawReported || request.source == UsageSource.reported;
      sawEstimated = sawEstimated || request.source == UsageSource.estimated;
    }
    return UsageSegment(
      index: index,
      totals: totals,
      byModel: byModel,
      source: scopeSource(
        sawReported: sawReported,
        sawEstimated: sawEstimated,
      ),
      openedAt: openedAt,
      closedAt: closedAt,
    );
  }

  /// Recomputes the cumulative total from [segments] (I2: the total is
  /// always derived, never incrementally patched, so it can never drift
  /// from `Σ(segments)`).
  UsageLedgerTotal totalOf(List<UsageSegment> segments) {
    var totals = UsageModelTotals.zero;
    var byModel = <String, UsageModelTotals>{};
    var sawReported = false;
    var sawEstimated = false;
    for (final segment in segments) {
      totals = totals + segment.totals;
      byModel = mergeUsageByModel(byModel, segment.byModel);
      sawReported = sawReported || segment.source == UsageSource.reported;
      sawEstimated = sawEstimated || segment.source == UsageSource.estimated;
    }
    return UsageLedgerTotal(
      totals: totals,
      byModel: byModel,
      source: scopeSource(
        sawReported: sawReported,
        sawEstimated: sawEstimated,
      ),
    );
  }

  /// The scope-level source marker from the presence flags (UT-3's
  /// matrix: neither → `reported` (nothing was estimated), both →
  /// `mixed`, one → that one).
  UsageSource scopeSource({
    required bool sawReported,
    required bool sawEstimated,
  }) {
    if (sawReported && sawEstimated) return UsageSource.mixed;
    if (sawEstimated) return UsageSource.estimated;
    return UsageSource.reported;
  }
}
