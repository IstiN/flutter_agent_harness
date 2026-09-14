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
    _outputBuffer.write(text);
    if (newline) _outputBuffer.write('\n');
    if (_running) {
      _outputFlushTimer ??= Timer(FaTuiController._outputFlushInterval, _flushOutput);
    } else {
      _flushOutput();
    }
  }

  void _flushOutput() {
    _outputFlushTimer?.cancel();
    _outputFlushTimer = null;
    if (_outputBuffer.isEmpty) return;
    final text = _outputBuffer.toString();
    _outputBuffer.clear();
    _send(OutputMsg(text));
  }

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
  void pushHub(FaHubState state) {
    _send(HubStateMsg(state));
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
