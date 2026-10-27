/// Observed context pressure (gh-1742): the provider-truth layer under the
/// compaction trigger, the over-window guard and the ctx meter.
///
/// Today's pressure was estimated-only (chars/4) against a statically
/// resolved window; the provider already reports the exact context size of
/// every completed request (`usage.input + usage.cacheRead` — it is
/// persisted on every assistant message in every session JSONL). This
/// library reconciles the two channels:
///
/// - **Observed-over-estimated** (gh-1742 invariant 1): when a request
///   completes, its reported `input + cacheRead` IS the context size that
///   was just accepted; the running pressure is
///   `max(estimate, observed)` — observed wins, the estimate fills the
///   gaps (kalman-lite). No chars/N constant is right across EN/RU/CJK
///   corpora; the provider's number is strictly better and free.
/// - **Over-limit is loud, never silent** (invariant 4): when the
///   observed channel alone crosses `window − headroom` while the
///   estimate channel stays under, the next boundary compacts with
///   `force: true` — the compactor's own `shouldCompact` re-check on the
///   estimate basis would otherwise skip the pass.
///
/// Degradation (E1): no observation yet (fresh session) or a provider
/// that reports no usable usage → estimate-only, exactly the legacy
/// behavior. `lastObservedContextTokens` reads the LIVE transcript, so a
/// resumed child/main agent rebuilds its last observation from the
/// persisted usage for free (E3).
library;

import 'dart:math' as math;

import '../types.dart' show AssistantMessage, Message, StopReason, Usage;
import 'compaction.dart' show CompactionSettings, shouldCompact;

/// The context size one completed request was accepted at (gh-1742):
/// `usage.input + usage.cacheRead` — what the provider counted of the
/// CONTEXT. The response side (`output`, `cacheWrite`) is not context;
/// `totalTokens` mixes both and over-counts the pressure.
int observedContextTokens(Usage usage) => usage.input + usage.cacheRead;

Usage? _usableUsage(Message message) {
  if (message case AssistantMessage(:final stopReason, :final usage)) {
    if (stopReason != StopReason.aborted &&
        stopReason != StopReason.error &&
        observedContextTokens(usage) > 0) {
      return usage;
    }
  }
  return null;
}

/// The most recent provider-reported context size in [messages]: the last
/// assistant message whose usage reports a positive context — or `null`
/// when none does (fresh transcript, or a gateway that reports no usage —
/// E1: the caller degrades to estimate-only). Reading the LIVE transcript
/// means a resumed agent rebuilds its observation from the persisted
/// usage with zero extra state (E3).
int? lastObservedContextTokens(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final usage = _usableUsage(messages[i]);
    if (usage != null) return observedContextTokens(usage);
  }
  return null;
}

/// Whether ANY assistant message in [messages] carries a usable
/// observation. E1: distinguishes "no observation YET" (fresh session —
/// silent) from "this provider never reports usage" (worth the caller's
/// once-per-model note).
bool hasAnyReportedUsage(List<Message> messages) =>
    messages.any((message) => _usableUsage(message) != null);

/// Kalman-lite reconciliation (gh-1742 invariant 1): the pressure input is
/// the WORSE of the two channels — `max(estimate, observed)`. An
/// observation at or below zero (providers that report zeros) and a null
/// observation degrade to the plain estimate; the estimate never
/// regresses because the observed channel dipped under it (the estimate
/// still prices the unsent trailing turn).
int reconcileContextTokens({
  required int estimatedTokens,
  int? observedTokens,
}) {
  final observed = observedTokens;
  if (observed == null || observed <= 0) return estimatedTokens;
  return math.max(estimatedTokens, observed);
}

/// The pressure verdict at one turn boundary (gh-1742): which channel
/// fired, the reconciled pressure, and whether the pass needs `force`.
final class ContextPressureDecision {
  const ContextPressureDecision({
    required this.pressureTokens,
    required this.estimateTriggered,
    required this.observedTriggered,
  });

  /// `max(estimate, observed)` — the reconciled pressure the trigger
  /// evaluated (what the ctx meter shows).
  final int pressureTokens;

  /// The reconciled pressure crossed `window − reserve`. Since the
  /// pressure is the max of both channels, this is the compound trigger:
  /// either channel alone crossing fires it.
  final bool estimateTriggered;

  /// The OBSERVED channel alone crossed `window − headroom` — the
  /// provider's own number says the next request rides into the reserve.
  final bool observedTriggered;

  /// Whether a compaction pass must run at this boundary.
  bool get triggered => estimateTriggered || observedTriggered;

  /// AC5: the observed channel fired — the pass must run with `force:
  /// true` so the compactor's own estimate-basis `shouldCompact` re-check
  /// cannot silently skip it.
  bool get needsForce => observedTriggered;
}

/// Assesses one boundary's context pressure (gh-1742): reconciles the
/// estimate with the observation and evaluates the trigger on both
/// channels. Pure.
ContextPressureDecision assessContextPressure({
  required int estimatedTokens,
  int? observedTokens,
  required int contextWindow,
  required CompactionSettings settings,
}) {
  final pressure = reconcileContextTokens(
    estimatedTokens: estimatedTokens,
    observedTokens: observedTokens,
  );
  final headroom = contextWindow - settings.reserveTokens;
  final observed = observedTokens;
  return ContextPressureDecision(
    pressureTokens: pressure,
    estimateTriggered: shouldCompact(pressure, contextWindow, settings),
    observedTriggered:
        observed != null && observed > 0 && headroom >= 0 &&
        observed > headroom,
  );
}
