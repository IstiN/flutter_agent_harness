/// FaTuiController's outbound send helpers — split out of `fa_tui.dart`
/// to keep it under the repo's 2800-line size gate. Same library (a
/// `part of`), so the extension sees the controller's private members
/// (`_send`, `_outputBuffer`, `_running`).
part of 'fa_tui.dart';

extension FaTuiControllerIo on FaTuiController {
  void sendOutput(String text, {bool newline = false}) {
    // Merge semantics match sending the pieces separately: text just
    // concatenates and the newline flag is a trailing '\n' (the model's
    // _appendOutput splits on '\n' and its trailing empty part plays the
    // role of the flag's extra empty line).
    // Issue #2069 — except across a line boundary. A newline-terminated
    // write is a COMPLETE line (a steering/watchdog/job notice, a tool
    // row, command output); when the buffer holds an unterminated
    // streamed delta, that line is closed first so the notice renders
    // intact on its own row above the busy row instead of gluing onto
    // the mid-word tail of streamed answer text. Plain write() deltas
    // still merge (streaming paragraph shapes are unchanged).
    final boundary = newline && _outputTailOpen;
    if (boundary) _outputBuffer.write('\n');
    _outputBuffer.write(text);
    if (newline) _outputBuffer.write('\n');
    _sentNewlines +=
        '\n'.allMatches(text).length + (newline ? 1 : 0) + (boundary ? 1 : 0);
    _outputTailOpen = !newline && !text.endsWith('\n');
    if (_running) {
      _outputFlushTimer ??= Timer(
        FaTuiController._outputFlushInterval,
        _flushOutput,
      );
    }
    // Pre-run: keep buffering — run()'s drain flushes once (issue #503:
    // per-writeln OutputMsgs made the boot drain run one markdown+wrap
    // sync per line — 5.7s for a 1913-line marathon resume, painted as a
    // blank terminal). Ordering is preserved because _send flushes the
    // buffer ahead of any non-output message.
  }

  void _flushOutput() {
    _outputFlushTimer?.cancel();
    _outputFlushTimer = null;
    if (_outputBuffer.isEmpty) return;
    final text = _outputBuffer.toString();
    _outputBuffer.clear();
    // gh-2094: the flag describes the last PAINTED byte, not the last
    // buffered write — a real flush PAINTS the text, so an unterminated
    // flush keeps the tail open. An unconditional reset here made the
    // next newline-terminated write (settled tool card, notice) skip its
    // boundary newline and glue onto the painted mid-line tail. The
    // empty-buffer early return above keeps empty flushes a no-op.
    _outputTailOpen = !text.endsWith('\n');
    _send(OutputMsg(text));
  }

  /// Test seam (gh-2094 AC2): the arbiter's tail-open truth. The
  /// state-truth invariant — after every real (non-empty) flush the flag
  /// equals `!flushedText.endsWith('\n')` — is only assertable from
  /// outside the library through this getter.
  @visibleForTesting
  bool get outputTailOpenForTest => _outputTailOpen;

  void sendModelsRefresh() {
    _send(_ModelsRefreshMsg());
  }

  void sendThemeChanged() {
    _send(_ThemeChangedMsg());
  }

  void openModelMenu() {
    _send(_OpenModelMenuMsg());
  }

  /// Opens a generic host picker (sessions, mode, approval, ...) with a
  /// static item list; selection resolves via [FaTuiCallbacks.onPickerSelected].
  void openPicker(
    String pickerId,
    String title,
    List<MenuItem> items, {
    String? initialKey,
  }) {
    var selected = 0;
    if (initialKey != null) {
      final index = items.indexWhere((item) => item.key == initialKey);
      if (index >= 0) selected = index;
    }
    _send(OpenPickerMsg(pickerId, title, items, initialIndex: selected));
  }

  /// Opens or refreshes the agents-hub overlay with a whole new state
  /// (issue #277). Pass hub = null-equivalent via `closeHub` to hide it.
  /// [refreshOnly] (issue #382): a background refresh — no-ops while the
  /// overlay is closed instead of force-opening it over the chat.
  void pushHub(FaHubState state, {bool refreshOnly = false}) {
    _send(HubStateMsg(state, refreshOnly: refreshOnly));
  }

  /// Hides the agents-hub overlay.
  void closeHub() {
    _send(const _CloseHubMsg());
  }

  void sendQuit() {
    _send(_QuitRequestedMsg());
  }

  /// Replaces the composer text (the `/skills` menu prefills `/skill:<name> `
  /// so the user can type arguments before pressing Enter).
  void sendInputText(String text) {
    _send(_SetInputTextMsg(text));
  }

  /// Replaces the submitted-message history (a resumed session restores
  /// its recorded messages so ↑ recalls them instead of scrolling).
  void setInputHistory(List<String> history) {
    _send(SetInputHistoryMsg(history));
  }

  /// Marks the resumed boot's replay anchor (issue #446 wave-14): the
  /// newline count captured HERE — before the summary/replay writes —
  /// rides the message, so the queue lag after the boot backlog can never
  /// re-name the anchor (CI round 2: a model-side count consumed after
  /// the drain named the transcript END and folded the whole banner).
  void markReplayAnchor() {
    _flushOutput();
    _send(SetBootAnchorMsg(_sentNewlines));
  }

  /// Opens the interactive prompt zone (ask/secret/approval) and resolves
  /// when the user answers (or cancels). The caller awaits the returned
  /// future, which completes from the model once the prompt key handler
  /// produces an answer.
  Future<TuiPromptAnswer?> openPrompt(TuiPromptSpec spec) {
    final completer = Completer<TuiPromptAnswer?>();
    _send(OpenPromptMsg(spec, completer));
    return completer.future;
  }
}
