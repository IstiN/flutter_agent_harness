/// The outstanding one-key budget-offer affordance (issue #1786 AC2) —
/// split out of [AgentCli] to keep it under the repo's 2800-line gate.
/// The state field lives on [AgentCli] itself (extensions cannot hold
/// fields); these members are the only writers/readers.
part of 'agent_cli.dart';

extension AgentCliBudget on AgentCli {
  /// A budget record with `action: offer` surfaced (rung 1 or the
  /// watchdog's rung 3): the terminal line printed it and the `b` key may
  /// now accept it. One offer at a time — a newer offer replaces a stale
  /// one (the ladder acts on the oldest eligible call, and only one call
  /// holds an outstanding offer).
  void budgetOfferSurfaced(String toolCallId) {
    _outstandingBudgetOffer = toolCallId;
  }

  /// The offer is gone: a terminal budget action fired (background /
  /// abort), or the call ended, or the accept already consumed it.
  void budgetOfferCleared() {
    _outstandingBudgetOffer = null;
  }

  /// Whether the stall banner should advertise the `b` affordance.
  bool get hasOutstandingBudgetOffer => _outstandingBudgetOffer != null;

  /// The one-key accept: escalates the offered call now (background if
  /// the tool hands back, else abort-with-partial after the grace).
  /// False = nothing to accept (no offer outstanding, or the ladder
  /// already acted / the call ended) — the stale id clears either way.
  bool acceptOutstandingBudgetOffer() {
    final id = _outstandingBudgetOffer;
    if (id == null) return false;
    if (_foregroundBudgetControls.acceptOffer(id)) return true;
    _outstandingBudgetOffer = null;
    return false;
  }
}
