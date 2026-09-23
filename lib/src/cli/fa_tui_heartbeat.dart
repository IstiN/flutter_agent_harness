// The busy-row heartbeat's message dispatch (issue #830 review round 4,
// CRAP gate): the old CC-13 if-ladder in FaTuiModel._updateWithHeartbeat,
// split into three dispatch groups of at most four decision points each.
// Same library, so the private members they touch stay private. The ??-
// chain in [_updateWithHeartbeat] preserves the ladder's exact order:
// first non-null result wins.

part of 'fa_tui.dart';

extension FaTuiModelHeartbeat on FaTuiModel {
  (Model, Cmd?) _updateWithHeartbeat(Msg msg) =>
      _updatePreExit(msg) ?? _updateRunPulse(msg) ?? _updateTail(msg);

  /// Groups that must run before the exit check. Output first so trailing
  /// writes (e.g. the 'bye' line from /exit) still render before the program
  /// quits; the host sends _QuitRequestedMsg once it has marked exit.
  /// Busy/spinner bookkeeping follows for the same reason: /exit arrives
  /// wrapped in sendBusy(true/false) calls, and quitting here would land in
  /// the same drained batch as the farewell output and skip its render. The
  /// host's delayed _QuitRequestedMsg is the only quit path that matters.
  /// Issue #804: the vendored program's OSC 11 background reply lands before
  /// the exit check — a late reply must still re-resolve the palette (and
  /// paint via the theme-swap cache reset) even while busy.
  (Model, Cmd?)? _updatePreExit(Msg msg) {
    final scheduled = _updateScheduled(msg);
    if (scheduled != null) return scheduled;
    if (msg is OutputMsg) return _handleOutputMsg(msg);
    if (msg is BusyMsg) return _handleBusyMsg(msg);
    if (msg is BackgroundColorMsg) return _handleBackgroundProbe(msg);
    return null;
  }

  /// Run-machinery pulses: stall recovery, spinner ticks, and the queue
  /// drain/clear pairs.
  (Model, Cmd?)? _updateRunPulse(Msg msg) {
    if (msg is RunStalledMsg) return _handleRunStalled(msg);
    if (msg is SpinnerTickMsg) return _handleSpinnerTick();
    if (msg is DrainQueueMsg) return _handleDrainQueue(msg);
    if (msg is ClearQueueMsg) return _handleClearQueue();
    return null;
  }

  /// The tail past the run pulses: the double-press ctrl+c states (issue
  /// #830), the prompt-zone grab, and finally the exit check — an already
  /// exited model only quits; everything else takes the main dispatch.
  (Model, Cmd?) _updateTail(Msg msg) {
    if (msg is InterruptArmedMsg) return _handleInterruptArmed();
    if (msg is CtrlCWindowExpiredMsg) return _handleWindowExpired();
    if (msg is OpenPromptMsg) {
      _promptCompleter = msg.completer;
      return (copyWith(prompt: TuiPromptState(msg.spec)), null);
    }
    if (isExited()) return (this, () => quit());
    return _updateAfterExitCheck(msg);
  }
}
