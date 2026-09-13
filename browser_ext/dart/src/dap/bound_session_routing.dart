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

/// The routing mode used when faDap.boundSession is absent or garbled:
/// 'dedicated' — inbound hub mail mints (or reopens) the agent-owned
/// 'DAP Inbox' session. This is the #304 owner UX and the picker's default
/// radio; every layer agrees on it (panel default, sw hub.bind default,
/// [DapConfig]'s fallback, [normalizeBoundSessionMode]).
const String kDefaultBoundSessionMode = 'dedicated';

/// Normalizes a stored `faDap.boundSession.mode` (possibly absent, empty or
/// garbled) to a valid mode: the three valid values pass through (after
/// trimming), anything else degrades to [kDefaultBoundSessionMode] —
/// never to 'current', which would silently move mail away from the inbox
/// the user expects (issue #321).
String normalizeBoundSessionMode(String? raw) {
  final mode = (raw ?? '').trim();
  return mode == 'dedicated' || mode == 'current' || mode == 'named'
      ? mode
      : kDefaultBoundSessionMode;
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
///
/// Unrecognized modes reaching this table stay on the live session — a
/// defensive last resort only: the config layer normalizes garbage to
/// [kDefaultBoundSessionMode] before the table sees it
/// ([normalizeBoundSessionMode]).
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
