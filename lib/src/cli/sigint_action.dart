/// Ctrl+C semantics for the CLI's SIGINT handler.
///
/// Matched empirically against a PTY repro: while a run streams, the
/// kernel-delivered SIGINT aborts the run — but with NO visible feedback
/// the aborted stream looks exactly like a frozen process (streaming
/// stops, nothing else happens), which users read as "Ctrl+C hangs".
/// The first busy press therefore aborts AND prints [busySigintHint];
/// an idle press (including a second press right after the abort) exits
/// 130. Headless runs always exit — there is no TUI to keep alive.
library;

/// What the SIGINT handler should do for one Ctrl+C press.
enum SigintAction {
  /// Abort the in-flight run and print [busySigintHint].
  abortRun,

  /// Idle interactive: restore canonical mode, drop an unused session
  /// file, print the resume hint, exit(130).
  exitIdle,

  /// Headless: exit(130) immediately, no cosmetic stdout bytes.
  exitHeadless,
}

/// Resolve the action for one Ctrl+C press.
SigintAction sigintAction({required bool busy, required bool headless}) {
  if (headless) return SigintAction.exitHeadless;
  return busy ? SigintAction.abortRun : SigintAction.exitIdle;
}

/// Printed after a busy Ctrl+C abort so the still-running TUI is not
/// mistaken for a hung process.
const busySigintHint = 'run aborted — press Ctrl+C again to exit';
