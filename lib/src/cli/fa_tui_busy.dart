// The busy-row run machinery's message dispatch (the busy↔idle bracket,
// phase relabels, the wedge-watchdog tick and its kaomoji cadence), split
// out of fa_tui.dart (gh-1232 2800-line gate) as a library part — the
// same pattern as fa_tui_heartbeat.dart, so the members stay
// library-private and no public API moves.
part of 'fa_tui.dart';

extension FaTuiModelBusy on FaTuiModel {
  (Model, Cmd?) _handleBusyMsg(BusyMsg msg) {
    // An in-busy phase relabel (silent post-answer work like
    // auto-compaction or durable-memory extraction) takes priority.
    if (msg.busy && msg.phase != null) return _handlePhaseRelabel(msg);
    // A raw re-start while ALREADY busy (a trigger that bypassed the
    // controller's refcount): keep the elapsed window and the single tick
    // chain instead of stacking another one.
    if (msg.busy && busy) return _ignoreBusyRestart(msg);
    return _applyBusyTransition(msg);
  }

  /// The wedge watchdog's liveness push (issue #514): flips the busy row's
  /// label to `Stalled…` (and back) without touching the elapsed window —
  /// the stall is a STATE, not a phase relabel.
  (Model, Cmd?) _handleRunStalled(RunStalledMsg msg) =>
      (copyWith(runStalled: msg.stalled), null);

  /// A phase relabel on a BUSY model: swap the label over the SAME elapsed
  /// window and never schedule another tick here — extra chains would
  /// multiply repaint timers.
  (Model, Cmd?) _handlePhaseRelabel(BusyMsg msg) {
    final phase = msg.phase!;
    if (!busy) {
      // A relabel on an IDLE model is a post-run straggler (a compaction
      // finally-branch landing after the bracket released): dropping it is
      // the whole point — re-arming the spinner here wedged a session at
      // "Working… Ns" burning 100% CPU for hours (each chain re-renders
      // the full transcript every 100ms).
      faTuiBusyDiagnostics?.call('busy relabel dropped (idle) phase=$phase');
      return (this, null);
    }
    return (copyWith(busyPhase: phase), null);
  }

  (Model, Cmd?) _ignoreBusyRestart(BusyMsg msg) {
    faTuiBusyDiagnostics?.call(
      'busy re-start ignored (already busy) source=${msg.source}',
    );
    return (this, null);
  }

  /// The busy↔idle bracket itself. Kick the spinner loop when going busy;
  /// the loop stops itself on the first tick that finds the model idle
  /// again. Going idle also unpins the sticky user echo and clears any
  /// phase, so the next run starts as plain "Working…".
  (Model, Cmd?) _applyBusyTransition(BusyMsg msg) {
    faTuiBusyDiagnostics?.call(
      msg.busy
          ? 'busy on source=${msg.source ?? '?'}'
          : 'busy off source=${busySource.isEmpty ? '?' : busySource} '
                'elapsed=${busyStartedAtMs < 0 ? 0 : (DateTime.now().millisecondsSinceEpoch - busyStartedAtMs) ~/ 1000}s',
    );
    return (
      copyWith(
        busy: msg.busy,
        busyStartedAtMs: msg.busy ? DateTime.now().millisecondsSinceEpoch : -1,
        busyPhase: '',
        busySource: msg.busy ? (msg.source ?? '') : '',
        busyLastEventMs: msg.busy ? DateTime.now().millisecondsSinceEpoch : -1,
        // A new bracket always starts unstalled: the host pushes the
        // stall state per-episode, so a stale `Stalled…` must never
        // leak into the next run (issue #514).
        runStalled: msg.busy ? runStalled : false,
        spinnerFrame: 0,
        // A fresh run opens on a random face (issue #1374) — the same
        // seam the swap cadence uses, so tests stay deterministic.
        kaomojiFace: msg.busy ? kaomojiPick(kKaomojiFaces.length) : kaomojiFace,
        stickyLines: msg.busy ? null : const [],
        stickyIndex: msg.busy ? null : -1,
      ),
      msg.busy ? _scheduleSpinnerTick() : null,
    );
  }

  Cmd _scheduleSpinnerTick() {
    return () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return SpinnerTickMsg();
    };
  }

  (Model, Cmd?) _handleSpinnerTick() {
    if (!busy) return (this, null);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (busyLastEventMs > 0 &&
        now - busyLastEventMs > FaTuiModel.busyWatchdogMs) {
      faTuiBusyDiagnostics?.call(
        'busy watchdog release source='
        '${busySource.isEmpty ? '?' : busySource} '
        'elapsed=${busyStartedAtMs < 0 ? 0 : (now - busyStartedAtMs) ~/ 1000}s '
        'quiet=${(now - busyLastEventMs) ~/ 1000}s',
      );
      return (
        copyWith(
          busy: false,
          busyStartedAtMs: -1,
          busyPhase: '',
          busySource: '',
          busyLastEventMs: -1,
          stickyLines: const [],
          stickyIndex: -1,
        ),
        null,
      );
    }
    // The tick counter drives the kaomoji cadence (issue #1374): every
    // kKaomojiSwapTicks ticks (~0.9 s at the 100 ms chain) the face is
    // re-picked — randomly, and never to the face already showing. The
    // chain itself dies with the busy bracket, so an idle row never
    // animates (AC4). A FA_KAOMOJI_FACE pin freezes the face entirely —
    // deterministic frames for the visual fixtures.
    final frame = spinnerFrame + 1;
    final face = frame % kKaomojiSwapTicks == 0 && _kaomojiFacePin() == null
        ? kaomojiNextFaceIndex(kaomojiPick, kaomojiFace)
        : kaomojiFace;
    return (
      copyWith(spinnerFrame: frame, kaomojiFace: face),
      _scheduleSpinnerTick(),
    );
  }
}
