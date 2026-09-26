/// The REPL entries of [AgentCli]: the line-mode read-dispatch loop and
/// the TUI boot (with `_setTuiIo`/`_createTuiController`). Their public
/// helpers — `sessionResumeHint`, `waitForIdle`, `deleteSessionIfEmpty` —
/// stay class members of `agent_cli.dart`: callers outside this library
/// (the executable's SIGINT path, tests) cannot see a private extension.
/// Split out of `agent_cli.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for the REPL entries.
extension on AgentCli {
  /// The line-mode REPL: banner, restored-session replay, then the
  /// read-dispatch loop.
  Future<void> _runLineRepl() async {
    await _printBanner();
    await _printViewerBannerIfAny();
    // Warm the model cache here too (the TUI path does): the endpoint-
    // reported context window lands on the active model only through this
    // refresh, and line-mode `/model <id>` switches read the same map.
    unawaited(_refreshModelCache());
    final resumedLabel = await _resumedSessionLabel();
    if (resumedLabel != null) {
      _replayRestoredHistory(_agent.state.messages, resumedLabel);
    }
    // One-time consent question for third-party skill roots: reads answers
    // straight from the line stream (the dispatch loop is not running yet).
    final lineIterator = StreamIterator<String>(io.lines);
    await _maybePromptSkillsAccess(lineIterator: lineIterator);
    // Fresh install (issue #969): nothing configured, no key anywhere —
    // open the guided add-provider wizard before the first prompt. The
    // dispatch loop below answers its prompts (the pre-loop lineIterator
    // cannot route to `_pendingPromptAnswer`). The wizard completes
    // OUTSIDE `_handleLine`: once its last answer lands, the loop is
    // already parked in `moveNext` — so the idle prompt is restored from
    // the flow's own completion (also after a Ctrl-C cancel).
    final freshInstallFlow = _maybeStartFreshInstallProviderFlow();
    if (freshInstallFlow != null) {
      unawaited(
        freshInstallFlow.whenComplete(() {
          if (!_exited && !isBusy && !_providerFlowActive) {
            _writeIdlePrompt();
          }
        }),
      );
    }
    if (!_providerFlowActive) _writeIdlePrompt();
    while (await lineIterator.moveNext()) {
      var line = lineIterator.current;
      // A fresh user line clears the abort marker: the settle path already
      // dropped (or ran) the interrupted run's leftover steering.
      _abortRequested = false;
      if (line.trim() == '/') {
        final choice = await _showLineModeMenu(lineIterator);
        if (choice != null) line = choice;
      }
      await _handleLine(line);
      if (_exited) break;
      // No idle prompt while a guided flow owns input: its questions
      // would interleave with the status bar, and each answered prompt
      // would print a redundant one.
      if (!isBusy && !_providerFlowActive) _writeIdlePrompt();
    }
  }

  Future<void> _runTuiRepl() async {
    // Busy-row forensics: every arm/release/drop/watchdog-fire lands in
    // fa.log with its source — a wedged "Working…" names its owner.
    faTuiBusyDiagnostics = _logDiagnostic;
    final controller = _createTuiController();
    _tuiController = controller;
    _setTuiIo(controller);
    // Pending scheduled follow-ups light the indicator row on boot (#115).
    unawaited(_pushScheduledStatus());

    // The banner is part of the TUI output history so it stays visible above
    // the input line inside the alternate screen.
    await _printBanner();
    await _printViewerBannerIfAny();
    // The first _loadAgentContext() ran before the TUI owned the terminal —
    // its "found but disabled" hint never reached the transcript. Re-print.
    _printThirdPartySkillsDisabledHint();
    // Issue #503: the reconciliation notices paint BEFORE the history
    // replay — the replay is the final paint, so the resumed session's
    // tail (the last assistant message) stays on the first glass.
    await _rehydrateJobBoard();

    await _replayRestoredSession();
    // One-time consent question for third-party skill roots: a TUI picker
    // over the first frame (Esc = "Not now", asked again next launch).
    // The visible-waiting row lights up on boot too (issue #450): armed
    // timers from previous runs + the restart-honesty note.
    unawaited(_waiting.push());
    // Consent first; the fresh-install wizard (issue #969) chains after it
    // so two wizard pickers never race for one answer completer.
    unawaited(
      _maybePromptSkillsAccess().then(
        (_) => _maybeStartFreshInstallProviderFlow(),
      ),
    );

    // An ambiguous `--session <name>` (same name in several folders or
    // several in one): the scoped choice picker over the first frame —
    // the auto-resolved session stays when dismissed.
    unawaited(_offerStartupSessionChoice());

    await controller.run();
    _setTuiIo(null);
    _tuiController = null;
  }

  /// Routes [io]'s output through the TUI controller while it runs (null
  /// detaches after the run).
  void _setTuiIo(FaTuiController? controller) {
    final tuiIo = io;
    if (tuiIo is _TuiCliIO) tuiIo._tui = controller;
  }

  /// Wires the TUI controller's callbacks to the line handler, pickers, and
  /// interrupt/steer paths.
  FaTuiController _createTuiController() {
    late final FaTuiController controller;
    controller = FaTuiController(
      mouseCapture: config.tuiMouseCapture,
      syncOutput: config.tuiSyncOutput,
      sttyRunner: config.sttyRunner,
      sigintPolicy: sigintPolicy,
      callbacks: FaTuiCallbacks(
        onSubmit: (line, {images = const []}) =>
            _handleTuiSubmit(controller, line, images),
        onModelSelected: _tuiSelectModel,
        buildSlashMenu: _buildSlashMenu,
        buildModelMenu: _buildModelMenu,
        statusLine: _statusLine,
        // The band composer (#806): the omp status line attaches as the
        // composer's top band unless the `tui.classic` kill switch pins
        // the legacy chrome (byte-identical rule + dim footer).
        statusSnapshot: config.tuiClassic ? null : _statusLineSnapshot,
        statusLineEngine: config.tuiClassic
            ? null
            : TuiStatusLine(
                spec: resolveStatusLineSpec(config.statusLine),
              ),
        prompt: prompt,
        onInterrupt: () {
          // Marks the drain loop to discard queued messages (kimi-cli drops
          // the queue on cancel instead of starting new turns).
          _abortRequested = true;
          if (isBusy) _agent.abort();
        },
        // Double-press Ctrl+C press 2 (issue #830): the same SIGINT-parity
        // exit the host's SIGINT handler runs — abort-if-running bounded,
        // session resume hint, exit 130.
        onCtrlCExit: onCtrlCExitRequest,
        isShiftPressed: config.isShiftPressed,
        opensPicker: (key) => const {
          '/sessions',
          '/mode',
          '/approval',
          '/provider',
          '/settings',
        }.contains(key),
        onPickerSelected: _tuiPickerSelected,
        onPickerCancelled: _tuiPickerCancelled,
        onSteer: _steerTuiMessages,
        pathCandidates: pathCandidatesFor,
        onHubAction: (action, key) => _onHubAction(action, key),
        readClipboardImage: () => readPasteboardImage(),
      ),
      isExited: () => _exited,
      programHooks: config.tuiProgramHooks,
    );
    return controller;
  }
}
