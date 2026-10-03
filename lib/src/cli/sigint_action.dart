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
/// Esc stays abort-without-exit everywhere; no user-facing config knob
/// — [kSigintWindowEnvVar] is a harness TEST seam, not configuration
/// (gh-1014): PTY integration suites spawn the real binary and cannot
/// inject a clock, so they widen the window instead, keeping both window
/// crossings far from runner-load jitter.
library;

/// How long press 2 may follow press 1. The contract constant: the policy
/// default and every window-crossing test sleep reference it so there is
/// exactly one place where the window lives.
const kSigintPressWindow = Duration(seconds: 3);

/// Test-only press-window override (gh-1014): set to an integer number of
/// milliseconds and the CLI builds its [SigintPolicy] with that window.
/// NOT user configuration — the 3 s contract stands for every interactive
/// surface and nothing in the help text or docs mentions this variable.
/// It exists because a PTY integration test spawns the real binary and
/// cannot inject a clock into it (unlike the in-process unit tests, which
/// use the injectable stopwatch): widening the window makes both window
/// crossings of the double-press ladder insensitive to runner-load jitter
/// — the wait past the window can only land later (always a fresh press
/// 1), and the presses inside the fresh window land seconds before it
/// closes. Invalid values are ignored silently (null), never errors.
const kSigintWindowEnvVar = 'FA_SIGINT_WINDOW_MS';

/// Parses [kSigintWindowEnvVar] from [env]. Absent, blank, non-numeric,
/// zero and negative values yield null — the [kSigintPressWindow]
/// contract window stands.
Duration? resolveSigintWindowOverride({required Map<String, String> env}) {
  final ms = int.tryParse(env[kSigintWindowEnvVar]?.trim() ?? '');
  if (ms == null || ms <= 0) return null;
  return Duration(milliseconds: ms);
}

/// The dim hint shown after press 1 (TUI prompt-zone footer row, line-mode
/// stderr line). One constant so every surface carries the same wording.
const kCtrlCExitHint = 'press ctrl+c again to exit';

/// Line-mode press-1 stderr rendering: dim when the terminal speaks ANSI,
/// plain otherwise (piped/scripted runs must not see escape bytes).
String dimCtrlCExitHint({required bool supportsAnsiEscapes}) =>
    supportsAnsiEscapes ? '\x1b[2m$kCtrlCExitHint\x1b[22m' : kCtrlCExitHint;

/// What a double-press exit prints when the session has nothing persisted
/// (the empty-session file is deleted, so a resume hint would lie).
const kNothingToResumeHint = 'nothing to resume';

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
///
/// The window is measured on a monotonic [Stopwatch], not wall-clock
/// `DateTime` math: an NTP correction or VM pause/resume stepping the
/// clock backwards must never turn a minutes-late press into "press 2".
final class SigintPolicy {
  SigintPolicy({
    this.window = kSigintPressWindow,
    Stopwatch Function()? stopwatch,
  }) : _stopwatchFactory = stopwatch ?? Stopwatch.new;

  /// How long press 2 may follow press 1. Presses past the window start a
  /// fresh press-1 cycle.
  final Duration window;

  final Stopwatch Function() _stopwatchFactory;
  Stopwatch? _armed;

  /// Whether a press 1 is currently inside the window (drives the TUI's
  /// dim footer hint).
  bool get armed => _armed != null;

  /// Resolves the action for one Ctrl+C press and arms the window.
  SigintAction press({required bool headless}) {
    if (headless) return SigintAction.exitHeadless;
    final current = _armed;
    if (current != null && current.elapsed <= window) {
      current.stop();
      _armed = null;
      return SigintAction.exitInteractive;
    }
    // Fresh press 1: first press ever, a press past the window, or the
    // first press after other input reset the window.
    _armed = _stopwatchFactory()..start();
    return SigintAction.interruptAndStay;
  }

  /// Any other key/input resets the window (issue #830): the next Ctrl+C
  /// is a fresh press 1, and the armed hint goes away.
  void noteOtherInput() {
    _armed?.stop();
    _armed = null;
  }
}
