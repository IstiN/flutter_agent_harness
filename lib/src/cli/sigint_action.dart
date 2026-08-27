/// Ctrl+C semantics for the CLI's SIGINT handler.
///
/// PTY-verified behavior: Ctrl+C arrives as SIGINT (isig stays enabled —
/// 0x03 never reaches the TUI as a key event), so this module owns the
/// whole story. Interactive presses exit exactly like `/exit`: abort the
/// in-flight run first (bounded wait for the partial transcript to
/// persist), then print the session-resume hint and exit(130). Esc inside
/// the TUI remains the abort-without-exit key. Headless runs exit
/// immediately — there is no TUI to keep alive.
library;

/// What the SIGINT handler should do for one Ctrl+C press.
enum SigintAction {
  /// Interactive: abort any in-flight run (bounded), print the session
  /// resume hint, exit(130).
  exitInteractive,

  /// Headless: exit(130) immediately, no cosmetic stdout bytes.
  exitHeadless,
}

/// Resolve the action for one Ctrl+C press.
SigintAction sigintAction({required bool headless}) {
  return headless ? SigintAction.exitHeadless : SigintAction.exitInteractive;
}
