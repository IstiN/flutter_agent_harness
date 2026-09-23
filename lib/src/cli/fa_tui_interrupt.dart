// The double-press Ctrl+C interrupt cluster (issue #830), split out of
// fa_tui.dart to keep it under the repo's 2800-line gate. Same library,
// so the private members it touches stay private.

part of 'fa_tui.dart';

extension FaTuiModelInterrupt on FaTuiModel {
  /// Normal-mode interrupt keys (ctrl+c double-press, esc aborts the run);
  /// null when the key belongs to another cluster.
  (Model, Cmd?)? _handleInterruptKeys(KeyMsg msg) {
    switch (msg.key) {
      case 'ctrl+c':
        return _handleCtrlCPress();
      case 'esc':
        // Escape aborts the streaming run (pi's keybinding); a no-op when
        // idle because the host only aborts while busy. Unlike Ctrl+C it
        // never quits the program.
        callbacks.onInterrupt?.call();
        return (this, null);
      default:
        return null;
    }
  }

  /// ONE implementation of a ctrl+c press for every key path (normal mode
  /// and the hub overlay — issue #830): the shared [sigintPolicy] decides.
  /// Press 1 aborts the in-flight run (bounded downstream), clears the
  /// composer when idle, and arms the footer hint; press 2 within the
  /// window runs the SIGINT-parity exit (resume hint, 130).
  (Model, Cmd?) _handleCtrlCPress() {
    callbacks.onInterrupt?.call();
    if (sigintPolicy.press(headless: false) == SigintAction.exitInteractive) {
      final exit = callbacks.onCtrlCExit;
      if (exit != null) {
        return (
          copyWith(ctrlCArmed: false),
          () async {
            exit();
            return null;
          },
        );
      }
      // Legacy hosts without the SIGINT-parity exit seam: the old
      // single-press quit (exit 0).
      return (copyWith(ctrlCArmed: false), () => quit());
    }
    return (_stayAfterCtrlC(), _scheduleWindowExpiry());
  }

  /// Press-1 stay state: the dim footer hint goes up; an idle composer
  /// clears fully — text (the boot banner's `ctrl+c clear` promise),
  /// attachment chips, and a stale slash menu (the SIGINT path arms
  /// before mode gating, so the menu can be open here). A run in flight
  /// keeps the composer — the abort already owns the screen.
  FaTuiModel _stayAfterCtrlC() {
    var next = copyWith(
      ctrlCArmed: true,
      menuOpen: false,
      menuTokenStart: -1,
    );
    if (!next.busy && next.inputText.isNotEmpty) {
      next = next.copyWith(
        inputText: '',
        cursor: 0,
        attachments: const [],
      );
    }
    return next;
  }

  /// SIGINT press 1 routed in from the host (isig terminals never deliver
  /// ctrl+c as a key): same stay state + expiry schedule as the key path.
  (Model, Cmd?) _handleInterruptArmed() =>
      (_stayAfterCtrlC(), _scheduleWindowExpiry());

  /// The window ran out: the armed hint would now lie (the next press is
  /// a fresh press 1), so the hint goes away and the policy disarms. A
  /// late timer after the window was already reset is a no-op.
  (Model, Cmd?) _handleWindowExpired() {
    if (!ctrlCArmed) return (this, null);
    sigintPolicy.noteOtherInput();
    return (copyWith(ctrlCArmed: false), null);
  }

  /// Schedules [CtrlCWindowExpiredMsg] one press window after the arm, so
  /// the hint tracks the policy's clock instead of living forever.
  Cmd _scheduleWindowExpiry() => () async {
    await Future<void>.delayed(sigintPolicy.window);
    return const CtrlCWindowExpiredMsg();
  };

  /// Any input other than a ctrl+c press resets the double-press window
  /// (issue #830): the next ctrl+c is a fresh press 1 and the footer hint
  /// goes away. Ctrl+c itself keeps the window so press 2 can land.
  (Model, Cmd?) _withFreshCtrlCWindow(
    Msg msg,
    (Model, Cmd?) Function() handle, {
    bool keepWindow = false,
  }) {
    if (keepWindow || (!ctrlCArmed && !sigintPolicy.armed)) return handle();
    sigintPolicy.noteOtherInput();
    final (next, cmd) = handle();
    return ((next as FaTuiModel).copyWith(ctrlCArmed: false), cmd);
  }
}
