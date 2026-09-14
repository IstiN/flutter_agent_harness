/// The composer-submit glue for clipboard chips (issue #276) — split out of
/// `agent_cli.dart` to keep it under the repo's 2800-line size gate. Same
/// library (a `part of`), so the extension sees the AgentCli's private
/// members (`_agent`, `_settled`, `_abortRequested`, `_exited`).
part of 'agent_cli.dart';

extension ComposerChipsSubmit on AgentCli {
  /// A TUI submit: runs the line, waits for the run to settle, drains the
  /// queued messages, and schedules the quit when `/exit` marked the
  /// session exited.
  Future<void> _handleTuiSubmit(
    FaTuiController controller,
    String line,
    List<TuiImageAttachment> images,
  ) async {
    controller.sendBusy(true, source: 'submit');
    try {
      await _handleLine(line, images: images);
      // Runs are fire-and-forget (_startRun only records the future):
      // wait for the run to actually settle so the busy spinner lives
      // for the whole stream instead of flashing for one frame.
      await _settled;
      await _drainTuiQueue(controller);
    } finally {
      _abortRequested = false;
      controller.sendBusy(false, source: 'submit');
    }
    // `/exit` marks the session exited during handling. Quit in a later
    // event-loop batch: dart_tui drains the whole queue before rendering
    // and skips the render when a quit lands in the same batch, which
    // would swallow the farewell output just pushed above.
    if (_exited) {
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 100),
          controller.sendQuit,
        ),
      );
    }
  }

  /// Test seam: builds the real TUI controller (the wiring under test:
  /// callbacks, clipboard reader, busy gate) without booting a terminal,
  /// and runs a composer submit through the full
  /// busy-gate → _handleLine → settle → queue-drain path (issue #276).
  @visibleForTesting
  Future<void> tuiSubmitForTest(
    String line,
    List<TuiImageAttachment> images,
  ) {
    final controller = _tuiController ?? _createTuiController();
    _tuiController = controller;
    return _handleTuiSubmit(controller, line, images);
  }
}
