// The inbound hub-mail routing decision (faDap.boundSession): pure so the
// whole table is VM-testable — AgentHost maps the action onto its session
// primitives (openSession / newSession / stay).

/// What the host should do with the live session BEFORE running the turn
/// for an inbound hub-mail message.
enum BoundSessionAction {
  /// Keep the current session (mode `current`, already on the bound
  /// session, or no usable binding).
  stay,

  /// Open the bound session's archive onto the live path.
  openBound,

  /// Mint a dedicated session: `newSession` (or adopt the pristine live
  /// one) and persist its id back into the config.
  createDedicated,
}

/// Decides the pre-turn session move for one inbound mail.
///
/// * `current` mode never moves;
/// * `named` opens the pinned session unless already live (a missing id
///   stays — never lose mail over a dangling config);
/// * `dedicated` opens the remembered session, or creates one when none
///   is remembered yet. A pristine live session (no messages yet) is
///   ADOPTED as the dedicated session instead of archiving an empty
///   transcript and minting another — [BoundSessionAction.createDedicated]
///   covers both; the host picks adopt-vs-new from [pristineLive].
BoundSessionAction boundSessionAction({
  required String mode,
  required String? boundId,
  required String currentId,
  required bool pristineLive,
}) {
  switch (mode) {
    case 'named':
      if (boundId == null || boundId.isEmpty || boundId == currentId) {
        return BoundSessionAction.stay;
      }
      return BoundSessionAction.openBound;
    case 'dedicated':
      if (boundId != null && boundId.isNotEmpty) {
        return boundId == currentId
            ? BoundSessionAction.stay
            : BoundSessionAction.openBound;
      }
      return BoundSessionAction.createDedicated;
    default: // 'current' and anything unrecognized
      return BoundSessionAction.stay;
  }
}
