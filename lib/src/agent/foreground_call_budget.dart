/// Foreground tool-call budget (issue #1786): every running foreground tool
/// call becomes a bounded-unreachability window — user steering and watchdog
/// escalation always reach the agent within a configurable wall-clock budget
/// B (default 10 min), never only when the tool happens to return.
///
/// The budget is a DIFFERENT axis from the bash command timeout: B caps how
/// long the agent loop can be unreachable by steering; the optional command
/// timeout still governs the process when set. The two compose.
///
/// The ladder (Escalation Ladder), armed per foreground call by the loop's
/// `ForegroundCallSupervisor` (see `agent_loop_foreground_budget.dart`, a
/// part of `agent_loop.dart`):
///
/// - rung 1 at B/2 — with no output and steering pending: surface the
///   one-key "background & deliver steering" offer (interactive hosts);
///   `foregroundCallAutoConvert: auto` converts instead of asking
///   (unattended sessions — reversible backgrounding, never a silent kill).
/// - rung 2 at B — force-escalate regardless of output: yield-aware tools
///   (bash over a jobs-capable env) hand the call to `ShellJobRegistry` with
///   output continuity; anything else is aborted with partial output after
///   the cancel grace. Both paths announce in the transcript.
/// - rung 3 — the CLI liveness watchdog's 300s escalation invokes the same
///   supervisor action path (via [ForegroundCallBudgetControls]) instead of
///   printing a second display-only nudge.
///
/// Steering itself is NEVER injected into the blocked call: escalation ends
/// the unreachability window and the queued steering drains through the
/// existing turn-boundary path (`getSteeringMessages`) — no new instruction
/// channel.
///
/// The config is pure data (no IO); yaml parsing follows the strict
/// [StuckToolConfig] pattern — a bad schema throws [ConfigException] at
/// boot. yaml shape (flat `agent:` leaves, named as in the GOAL card):
///
/// ```yaml
/// agent:
///   foregroundCallBudgetSeconds: 600   # B, integer > 0
///   foregroundCallAutoConvert: offer   # offer | auto (default offer)
/// ```
library;

import '../exceptions.dart';
import 'stuck_tool.dart';

/// Default budget B (`agent.foregroundCallBudgetSeconds`): 10 minutes —
/// about 2x the liveness watchdog's escalate point, so rung 1 has room to
/// offer before rung 2 forces.
const defaultForegroundCallBudgetSeconds = 600;

/// Session record type for a budget-ladder action
/// (`CustomRecord.customType`): offer surfaced, auto-convert, force
/// background, or abort-with-partial — every rung lands here, so an
/// escalation can never be silent (issue #1786 AC6).
const foregroundBudgetRecordType = 'foreground_budget';

/// The cancel reason the budget supervisor puts on a call/yield token — a
/// marker, not an error: the tokens' other listeners only check
/// [CancelToken.isCancelled], and bash's unwind path must be able to tell
/// this apart from the stuck supervisor's cancel-retry
/// (`StuckCallFollowUp`) so the budget force escalates to a BACKGROUND
/// hand-back, not a failed retry.
///
/// Deliberately NOT named `StuckCallFollowUp`: bash's
/// `_isSupervisorAbort` classifies that type as cancel-and-retry; any other
/// reason unwinds the job to the background — exactly the budget's
/// reversibility contract.
class ForegroundBudgetFollowUp {
  const ForegroundBudgetFollowUp(this.detail);

  /// Why the budget acted (rung + elapsed), for diagnostics.
  final String detail;
}

/// Which rung of the Escalation Ladder acted (or is about to).
enum ForegroundBudgetRung {
  /// B/2: the one-key offer (interactive) or the config-gated auto-convert
  /// (`foregroundCallAutoConvert: auto`).
  offer,

  /// B: force-escalate — background, or abort-with-partial-output when the
  /// tool cannot be backgrounded.
  force,

  /// The liveness watchdog's 300s escalation invoking the supervisor action
  /// path (rung 3).
  watchdog;

  /// The snake_case label used in session records and HEP frames.
  String get label => switch (this) {
    offer => 'offer',
    force => 'force',
    watchdog => 'watchdog',
  };
}

/// What the supervisor did at a rung (the `action` field of the session
/// record / [ToolCallBudgetEvent]).
enum ForegroundBudgetAction {
  /// The one-key offer was surfaced (interactive hosts).
  offer,

  /// The call was moved to the background (reversible; output continues
  /// into `ShellJobRegistry`).
  background,

  /// No backgrounding was possible: the call was aborted with partial
  /// output captured (last resort, announced).
  abort;

  /// The snake_case label used in session records and HEP frames.
  String get label => switch (this) {
    offer => 'offer',
    background => 'background',
    abort => 'abort',
  };
}

/// The `agent.foregroundCallBudgetSeconds` / `agent.foregroundCallAutoConvert`
/// config (issue #1786). Strict: a bad schema throws at boot; the budget
/// must be a positive integer; `autoConvert` is `offer` (default) or `auto`.
/// Per-tool-kind overrides are a second-tier opt-in and are REJECTED in the
/// core tier (a map where the integer/enum is expected fails validation).
final class ForegroundCallBudgetConfig {
  const ForegroundCallBudgetConfig({
    this.budget = const Duration(seconds: defaultForegroundCallBudgetSeconds),
    this.autoConvert = false,
    this.cancelGrace = const Duration(seconds: defaultStuckCancelGraceSeconds),
  });

  /// The wall-clock budget B. Force-escalation fires at B; the offer rung
  /// at B/2.
  final Duration budget;

  /// `true` = rung 1 auto-converts at B/2 (unattended-friendly, reversible
  /// backgrounding) instead of surfacing the one-key offer.
  final bool autoConvert;

  /// Bounded wait for an escalated call to observe its cancellation before
  /// the supervisor abandons it and captures the partial output — a token-
  /// ignoring zombie cannot stretch the unreachability window past
  /// B + grace. Internal knob (not yaml-exposed); defaults to the stuck
  /// supervisor's grace.
  final Duration cancelGrace;

  /// When rung 1 fires.
  Duration get offerAt => budget ~/ 2;

  /// Parses the two flat `agent:` leaves
  /// (`foregroundCallBudgetSeconds`, `foregroundCallAutoConvert`), applying
  /// the defaults for absent ones.
  static ForegroundCallBudgetConfig fromLeaves({
    Object? budgetSeconds,
    Object? autoConvert,
  }) {
    var budget = const Duration(seconds: defaultForegroundCallBudgetSeconds);
    var auto = false;
    if (budgetSeconds != null) {
      if (budgetSeconds is! int || budgetSeconds <= 0) {
        throw ConfigException(
          '"agent.foregroundCallBudgetSeconds" must be a positive integer, '
          'got: $budgetSeconds',
        );
      }
      budget = Duration(seconds: budgetSeconds);
    }
    if (autoConvert != null) {
      if (autoConvert is! String) {
        throw ConfigException(
          '"agent.foregroundCallAutoConvert" must be a string '
          '(offer | auto)',
        );
      }
      auto = switch (autoConvert) {
        'offer' => false,
        'auto' => true,
        _ => throw ConfigException(
          '"agent.foregroundCallAutoConvert" must be "offer" or "auto", '
          'got: $autoConvert',
        ),
      };
    }
    return ForegroundCallBudgetConfig(budget: budget, autoConvert: auto);
  }
}

/// The deterministic announcement line for a budget action — the REG-1
/// byte-scan target (`[foreground-budget]`): names the rung, the elapsed
/// time, and the steering count, so no escalation is ever silent (AC6).
String foregroundBudgetAnnouncement({
  required ForegroundBudgetRung rung,
  required ForegroundBudgetAction action,
  required String toolName,
  required Duration elapsed,
  required int steeringCount,
  String detail = '',
}) {
  final steering = steeringCount == 1
      ? '1 steering message'
      : '$steeringCount steering messages';
  final suffix = switch (action) {
    ForegroundBudgetAction.offer =>
      ' — accept to move it to the background and deliver $steering now',
    ForegroundBudgetAction.background =>
      'moved to a background job (still running; steering: $steering queued '
          'for the next turn)',
    ForegroundBudgetAction.abort =>
      'aborted with partial output captured (steering: $steering queued for '
          'the next turn)',
  };
  final head =
      '[foreground-budget] rung ${foregroundBudgetRungNumber(rung)}: '
      '$toolName after ${_formatBudgetElapsed(elapsed)}';
  return detail.isEmpty ? '$head $suffix' : '$head — $detail — $suffix';
}

/// The rung number for announcements (1/2/3 per the GOAL card's ladder).
String foregroundBudgetRungNumber(ForegroundBudgetRung rung) => switch (rung) {
  ForegroundBudgetRung.offer => '1',
  ForegroundBudgetRung.force => '2',
  ForegroundBudgetRung.watchdog => '3',
};

/// Human elapsed for budget announcements (`4m05s`).
String _formatBudgetElapsed(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
}

/// The host-created CLI→loop controls for the budget ladder (issue #1786
/// AC2/AC4): the loop registers per-call closures while a budgeted call is
/// in flight; the interactive host invokes them from the one-key stall
/// banner action and from the liveness watchdog's escalate rung.
///
/// Without a controls instance (headless hosts) rung 1 degrades to waiting
/// for rung 2 (or `autoConvert: auto`), and the watchdog keeps its nudge —
/// the bounded-unreachability invariant never depends on this object.
final class ForegroundCallBudgetControls {
  /// Accept closures by in-flight tool call id (parallel calls each
  /// register their own; insertion order = call start order).
  final _acceptors = <String, bool Function()>{};

  /// Offer-request closures by in-flight tool call id (the watchdog's
  /// rung-3 hook escalates the OLDEST eligible call).
  final _requesters = <String, bool Function()>{};

  /// Registers the loop-side closures for one in-flight call (called by the
  /// supervisor when the call starts; [detach] clears them when it ends).
  void attach({
    required String toolCallId,
    required bool Function() requestOffer,
    required bool Function() acceptOffer,
  }) {
    _requesters[toolCallId] = requestOffer;
    _acceptors[toolCallId] = acceptOffer;
  }

  /// Clears the closures of a finished call (no offer may outlive its
  /// call).
  void detach(String toolCallId) {
    _requesters.remove(toolCallId);
    _acceptors.remove(toolCallId);
  }

  /// Watchdog rung 3: fire the offer for the oldest eligible budgeted call.
  /// False = no budgeted call can act (caller keeps the display-only nudge).
  bool requestOffer() {
    for (final requester in _requesters.values) {
      // One call at a time answers the watchdog; stop at the first that
      // surfaced an offer.
      if (requester()) return true;
    }
    return false;
  }

  /// One-key accept: escalate the offered call now. False = that offer is
  /// no longer outstanding (the ladder already acted or the call ended).
  bool acceptOffer(String toolCallId) =>
      _acceptors[toolCallId]?.call() ?? false;
}
