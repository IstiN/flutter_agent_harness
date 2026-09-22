/// The double-press Ctrl+C contract (issue #830): a single press never
/// exits — press 1 aborts the in-flight run (bounded) and stays alive,
/// clearing the composer when idle; press 2 within the press window exits
/// exactly like the old single-press path: abort-if-running, session
/// resume hint, exit 130. Any other key/input resets the window, so a
/// press after the window is a fresh press 1.
///
/// ONE policy instance per interactive process is shared by both input
/// paths so they can never disagree (ACX.5): the SIGINT handler in
/// `bin/fah.dart` (isig stays on in the VM's raw mode — 0x03 never
/// reaches the TUI as a key event) and the TUI's `ctrl+c` KeyMsg handler
/// (kitty protocol / raw-mode terminals where isig is off). Headless runs
/// bypass the window entirely — scripts rely on an immediate exit 130.
/// Esc stays abort-without-exit everywhere; no config knob.
library;

/// The dim hint shown after press 1 (TUI prompt-zone footer row, line-mode
/// stderr line). One constant so every surface carries the same wording.
const kCtrlCExitHint = 'press ctrl+c again to exit';

/// What a Ctrl+C press should do.
enum SigintAction {
  /// Press 1: abort any in-flight run (bounded), clear the composer if it
  /// holds text, show [kCtrlCExitHint] — and stay alive.
  interruptAndStay,

  /// Press 2 within the window: the old single-press interactive exit —
  /// abort-if-running (bounded), print the session resume hint, exit 130.
  exitInteractive,

  /// Headless: exit(130) immediately, no cosmetic stdout bytes.
  exitHeadless,
}

/// Press-window state for the double-press contract. Not serialized, not
/// restored: the window lives only in the running process.
final class SigintPolicy {
  SigintPolicy({
    this.window = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long press 2 may follow press 1. Presses past the window start a
  /// fresh press-1 cycle.
  final Duration window;

  final DateTime Function() _now;
  DateTime? _lastPress;

  /// Whether a press 1 is currently inside the window (drives the TUI's
  /// dim footer hint).
  bool get armed => _lastPress != null;

  /// Resolves the action for one Ctrl+C press and arms the window.
  SigintAction press({required bool headless}) {
    if (headless) return SigintAction.exitHeadless;
    final at = _now();
    final last = _lastPress;
    _lastPress = at;
    return last != null && at.difference(last) <= window
        ? SigintAction.exitInteractive
        : SigintAction.interruptAndStay;
  }

  /// Any other key/input resets the window (issue #830): the next Ctrl+C
  /// is a fresh press 1, and the armed hint goes away.
  void noteOtherInput() => _lastPress = null;
}
