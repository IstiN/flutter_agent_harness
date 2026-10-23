/// The ForegroundCallSupervisor (issue #1786): the Escalation Ladder over
/// the wall-clock budget B for every running foreground tool call, plus the
/// [ToolCallBudgetEvent] the hosts persist and surface.
///
/// Split out of `agent_loop.dart` to keep it under the repo's 2800-line
/// size gate. Same library (a `part of`), so the helpers keep their access
/// to the loop's private members.
///
/// The ladder composes with (never replaces) the two existing nets:
/// - steering soft-yield (`steeringNotifications` → the phase yield token):
///   still converts a yield-aware bash call the moment steering arrives;
/// - stuck-call supervision (gh-1054): still owns its derived-threshold
///   cancel/retry/convert stage machine.
///
/// The budget is the UNCONDITIONAL outer bound: it derives nothing from the
/// call's declared timeout (a large explicit timeout defeats the stuck
/// threshold — `stuckThreshold = max(2 × declared, floor)` — which is
/// exactly the 2026-10-22 incident hole this card closes). When the budget
/// fires, it preempts the stuck stage machine: no stuck retry may restart a
/// call the budget has already escalated.
part of 'agent_loop.dart';

/// A budget-ladder action (issue #1786): an offer surfaced, a call moved to
/// the background, or a call aborted with partial output — every rung lands
/// here, session-visible, so no escalation is ever silent (AC6).
final class ToolCallBudgetEvent extends AgentEvent {
  const ToolCallBudgetEvent({
    required this.toolCallId,
    required this.toolName,
    required this.args,
    required this.rung,
    required this.action,
    required this.elapsed,
    required this.steeringCount,
    this.detail = '',
    required this.timestamp,
  });

  /// The [ToolCall.id] the ladder acted on.
  final String toolCallId;

  /// The tool's name.
  final String toolName;

  /// The parsed tool call arguments.
  final Map<String, dynamic> args;

  /// Which rung fired (1 = offer/auto, 2 = force, 3 = watchdog).
  final ForegroundBudgetRung rung;

  /// What the supervisor did (or is offering to do).
  final ForegroundBudgetAction action;

  /// How long the call had run when the rung fired.
  final Duration elapsed;

  /// Steering messages queued at fire time (the count the escalation
  /// delivers into the next turn through the existing boundary drain).
  final int steeringCount;

  /// The deterministic announcement line (the REG-1 byte-scan target).
  final String detail;

  /// When the rung fired.
  final DateTime timestamp;
}

/// Call-scoped state of the budget ladder — spans every stuck-supervision
/// attempt of the call (B counts from CALL start, not attempt start).
/// Grouped into one object so the timer callbacks stay top-level functions
/// under the CRAP ratchet (12.0).
final class _BudgetClock {
  _BudgetClock({
    required this.toolCall,
    required this.budget,
    required this.pendingSteeringCount,
  }) : stopwatch = Stopwatch()..start();

  final ToolCall toolCall;
  final Stopwatch stopwatch;
  final ForegroundCallBudgetConfig budget;
  final int Function()? pendingSteeringCount;

  Timer? offerTimer;
  Timer? forceTimer;
  Timer? graceTimer;

  /// Cleared when the call is over: the timers must then become no-ops
  /// (no rung may outlive the call).
  bool alive = true;

  /// The ladder acted (offer accepted, auto-convert, or force) — one-shot.
  bool ladderFired = false;

  /// The one-key offer is on the table (interactive hosts decide).
  bool offerOutstanding = false;

  /// Fire-time snapshots for the outcome announcement.
  late ForegroundBudgetRung escalationRung;
  late Duration escalationElapsed;
  int escalationSteeringCount = 0;

  /// Output seen so far (the rung-1 "no output" condition, E8) and the
  /// last partial text (the abort path's partial-output capture).
  int outputBytes = 0;
  String partialText = '';

  /// The CURRENT attempt's plumbing, registered by [_supervisedAttempt]:
  /// a fire between attempts cancels stale tokens harmlessly; the grace
  /// gate opens the current attempt's bounded wait.
  CancelTokenSource? attemptCallSource;
  CancelTokenSource? attemptYieldSource;
  _AttemptClock? attemptClock;
  void Function(AgentEvent event)? enqueue;

  void disarm() {
    offerTimer?.cancel();
    forceTimer?.cancel();
    graceTimer?.cancel();
    alive = false;
  }
}

/// Whether the budget supervises a tool call: everything EXCEPT the same
/// human-blocking / self-supervised class the stuck supervisor excludes by
/// default — `ask`/`request_secret` block on a human by design (a budget
/// force would abort a deliberation), `task` runs whole subagents whose
/// own machinery owns long runs.
bool _budgetAppliesTo(String toolName) =>
    !StuckToolConfig.defaultStuckExcludedTools.contains(toolName);

/// Arms the ladder's two timers for one call: the rung-1 offer deadline at
/// B/2 and the rung-2 force deadline at B. Timers are no-ops once the call
/// ends ([_BudgetClock.disarm]), so short calls keep byte-identical legacy
/// behavior (AC7).
void _armBudgetTimers(_BudgetClock clock) {
  clock.offerTimer = Timer(clock.budget.offerAt, () {
    _onBudgetOfferDeadline(clock);
  });
  clock.forceTimer = Timer(clock.budget.budget, () {
    // Rung 2 fires at B regardless of output (UT-1); an outstanding
    // unaccepted offer force-escalates too.
    _escalateBudgetNow(clock, rung: ForegroundBudgetRung.force);
  });
}

/// The rung-1 deadline: the offer (or the config-gated auto-convert) fires
/// only when the call is silent AND steering is pending (UT-1) — output
/// activity resets the condition (E8) and an empty steering FIFO skips the
/// rung (E2).
void _onBudgetOfferDeadline(_BudgetClock clock) {
  if (!_budgetOfferEligible(clock)) return;
  if (clock.budget.autoConvert) {
    // Unattended sessions: background (reversible) instead of asking —
    // never a silent kill (the outcome event lands when the stage
    // advances, mirroring the stuck supervisor's deferred records).
    _escalateBudgetNow(clock, rung: ForegroundBudgetRung.offer);
    return;
  }
  _surfaceBudgetOffer(clock, ForegroundBudgetRung.offer);
}

/// Whether a rung-1 offer may fire for [clock] right now.
bool _budgetOfferEligible(_BudgetClock clock) {
  if (!clock.alive || clock.ladderFired || clock.offerOutstanding) {
    return false;
  }
  if (clock.outputBytes > 0) return false;
  return (clock.pendingSteeringCount?.call() ?? 0) > 0;
}

/// Surfaces the one-key "background & deliver steering" offer (rung 1, or
/// rung 3 when the watchdog's escalate invoked it). Purely advisory: the
/// call keeps running until the user accepts or rung 2 fires.
void _surfaceBudgetOffer(_BudgetClock clock, ForegroundBudgetRung rung) {
  clock.offerOutstanding = true;
  final steering = clock.pendingSteeringCount?.call() ?? 0;
  final announcement = foregroundBudgetAnnouncement(
    rung: rung,
    action: ForegroundBudgetAction.offer,
    toolName: clock.toolCall.name,
    elapsed: clock.stopwatch.elapsed,
    steeringCount: steering,
  );
  clock.enqueue?.call(
    ToolCallBudgetEvent(
      toolCallId: clock.toolCall.id,
      toolName: clock.toolCall.name,
      args: clock.toolCall.arguments,
      rung: rung,
      action: ForegroundBudgetAction.offer,
      elapsed: clock.stopwatch.elapsed,
      steeringCount: steering,
      detail: announcement,
      timestamp: DateTime.now(),
    ),
  );
}

/// The watchdog's rung-3 hook (AC4): fire the offer NOW instead of letting
/// the tracker print a second display-only nudge. Returns false when the
/// ladder cannot act (no in-flight silent call / steering pending / already
/// acted) — the caller keeps its legacy nudge in that case.
bool _requestBudgetOffer(_BudgetClock clock) {
  if (!_budgetOfferEligible(clock)) return false;
  _surfaceBudgetOffer(clock, ForegroundBudgetRung.watchdog);
  return true;
}

/// The one-key accept (rung 1): escalate immediately — background if the
/// tool hands back, else abort-with-partial after the grace. False when the
/// offer is gone (the ladder already acted or the call ended).
bool _acceptBudgetOffer(_BudgetClock clock) {
  if (!clock.alive || clock.ladderFired || !clock.offerOutstanding) {
    return false;
  }
  _escalateBudgetNow(clock, rung: ForegroundBudgetRung.offer);
  return true;
}

/// Escalates NOW: cancels the current attempt's yield token first (a
/// jobs-capable bash hands the call to `ShellJobRegistry` untouched —
/// reversible) and then the call token (token-obeying tools abort), and
/// opens the cancel grace so even a token-ignoring zombie cannot stretch
/// the unreachability window past B + grace (E6). The outcome event waits
/// for [_finalizeBudgetEscalation], which only announces what ACTUALLY
/// happened (a call that completes inside the grace never leaves a forced
/// record behind — mirroring the stuck supervisor's deferred records).
void _escalateBudgetNow(
  _BudgetClock clock, {
  required ForegroundBudgetRung rung,
}) {
  if (!clock.alive || clock.ladderFired) return;
  clock.ladderFired = true;
  clock.offerOutstanding = false;
  clock.escalationRung = rung;
  clock.escalationElapsed = clock.stopwatch.elapsed;
  clock.escalationSteeringCount = clock.pendingSteeringCount?.call() ?? 0;
  final reason = ForegroundBudgetFollowUp(
    'foreground budget rung ${rung.label} at '
    '${_formatElapsed(clock.escalationElapsed)}',
  );
  clock.attemptYieldSource?.cancel(reason);
  clock.attemptCallSource?.cancel(reason);
  final attempt = clock.attemptClock;
  if (attempt != null && !attempt.graceGate.isCompleted) {
    if (clock.budget.cancelGrace > Duration.zero) {
      clock.graceTimer = Timer(clock.budget.cancelGrace, () {
        // The stuck supervisor's grace timer may share this gate (both
        // ladders can be armed on one call): the guard keeps a late
        // orphan timer from completing a settled Completer.
        if (!attempt.graceGate.isCompleted) attempt.graceGate.complete();
      });
    } else {
      attempt.graceGate.complete();
    }
  }
}

/// Classifies the post-escalation attempt and lands the outcome: a hand-back
/// result (the call was backgrounded) is marked and returned; a genuine
/// completion inside the grace is marked without a forced record; anything
/// else is the abort path — a session-visible budget event plus an error
/// result carrying the announcement and the captured partial output.
Future<ToolExecutionResult> _finalizeBudgetEscalation({
  required _BudgetClock clock,
  required ToolCall toolCall,
  required _SupervisedAttempt outcome,
  required AgentEventSink emit,
}) async {
  final announcement = foregroundBudgetAnnouncement(
    rung: clock.escalationRung,
    action: ForegroundBudgetAction.abort,
    toolName: toolCall.name,
    elapsed: clock.escalationElapsed,
    steeringCount: clock.escalationSteeringCount,
  );
  if (outcome.error == null && !outcome.hung) {
    final result = outcome.result!;
    if (_isBackgroundHandback(result)) {
      final line = foregroundBudgetAnnouncement(
        rung: clock.escalationRung,
        action: ForegroundBudgetAction.background,
        toolName: toolCall.name,
        elapsed: clock.escalationElapsed,
        steeringCount: clock.escalationSteeringCount,
      );
      await emit(
        _budgetRecord(clock, toolCall, ForegroundBudgetAction.background, line),
      );
      return _prefixMarks([line], result);
    }
    // The call finished its own work inside the grace: nothing was forced,
    // so no forced record (only the truthful mark on the result).
    return _prefixMarks([
      '$announcement — the call completed as the budget fired.',
    ], result);
  }
  final partial = clock.partialText.isEmpty
      ? ''
      : '\n\nPartial output so far:\n${clock.partialText}';
  // A hung outcome means the call ignored both tokens (E6): the zombie
  // handle is named in the announcement, the partial output is captured.
  final line = outcome.hung
      ? foregroundBudgetAnnouncement(
          rung: clock.escalationRung,
          action: ForegroundBudgetAction.abort,
          toolName: toolCall.name,
          elapsed: clock.escalationElapsed,
          steeringCount: clock.escalationSteeringCount,
          detail: 'the call ignored cancellation',
        )
      : announcement;
  await emit(
    _budgetRecord(clock, toolCall, ForegroundBudgetAction.abort, line),
  );
  throw StateError('$line$partial');
}

/// The outcome event for a forced budget action (the session-record feed).
ToolCallBudgetEvent _budgetRecord(
  _BudgetClock clock,
  ToolCall toolCall,
  ForegroundBudgetAction action,
  String detail,
) => ToolCallBudgetEvent(
  toolCallId: toolCall.id,
  toolName: toolCall.name,
  args: toolCall.arguments,
  rung: clock.escalationRung,
  action: action,
  elapsed: clock.escalationElapsed,
  steeringCount: clock.escalationSteeringCount,
  detail: detail,
  timestamp: DateTime.now(),
);
