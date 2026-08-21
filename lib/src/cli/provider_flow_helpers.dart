/// Shared REPL/TUI prompt helpers used by the provider/key setup flows.
///
/// Kept in a separate `part` so [provider_commands.dart] stays under the
/// repo's 2800-line file-size gate.
part of 'agent_cli.dart';

extension on AgentCli {
  /// The flow's free-form questions: a TUI text prompt when the controller
  /// is up (masked input for secrets), a plain line prompt otherwise.
  Future<String?> _askLine(String question, {bool secret = false}) async {
    final tui = _tuiController;
    if (_useTui && tui != null) {
      return _askLineTui(tui, question, secret);
    }
    return _promptLine(question);
  }

  /// The TUI branch of [_askLine].
  Future<String?> _askLineTui(
    FaTuiController tui,
    String question,
    bool secret,
  ) async {
    final spec = TextPromptSpec(
      question: question,
      defaultValue: _extractDefault(question),
      secret: secret,
    );
    final result = await tui.openPrompt(spec);
    return result is TextPromptAnswer ? result.value : null;
  }

  /// Parses a `(empty = X):` or `(empty keeps 'X'):` hint from [question],
  /// returning `X` so the TUI prompt can show it as the default value, or
  /// null when no default hint is present.
  String? _extractDefault(String question) => extractDefaultValue(question);

  /// Reads one input line for a guided-flow prompt (printed inline).
  /// Resolves to `null` on cancel (Ctrl-C interrupt or input shutdown),
  /// which the flow maps to "setup cancelled". Answers buffered while no
  /// prompt was pending (piped input) are drained synchronously.
  Future<String?> _promptLine(String question) async {
    // Guided flows run sequentially (one command at a time); complete a
    // stray pending prompt defensively as cancelled.
    final stray = _pendingPromptAnswer;
    if (stray != null && !stray.isCompleted) stray.complete(null);
    // Assign before writing/checking: the input gate routes lines to this
    // completer from here on, so an answer arriving mid-setup can no
    // longer fall between the buffer check and the assignment (deadlock).
    final pending = Completer<String?>();
    _pendingPromptAnswer = pending;
    io.write(question);
    if (_promptLineBuffer.isNotEmpty) {
      final buffered = _promptLineBuffer.removeAt(0);
      // Piped lines are not echoed by the terminal; keep the transcript
      // readable like the interactively typed answers.
      io.writeln(buffered);
      pending.complete(buffered);
    }
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete(null);
    });
    final line = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingPromptAnswer, pending)) {
      _pendingPromptAnswer = null;
    }
    // The answer replaced the prompt line; keep output tidy.
    if (line != null) io.writeln('');
    return line;
  }

  /// The flow's multiple-choice questions: a TUI menu when the controller
  /// is up (answer arrives via `_tuiPickerSelected` / cancel via
  /// `_tuiPickerCancelled`), a numbered list plus line prompt otherwise.
  Future<String?> _pickOption(
    String title,
    List<FlowOption> options, {
    String? initialKey,
  }) async {
    final controller = _tuiController;
    if (_useTui && controller != null) {
      return _pickOptionTui(controller, title, options, initialKey: initialKey);
    }
    _printFlowOptions(title, options, initialKey);
    return _promptOptionNumber(options);
  }

  /// The line-mode option list of [_pickOption]: the numbered options with
  /// descriptions and a `(current)` marker on [initialKey].
  void _printFlowOptions(
    String title,
    List<FlowOption> options,
    String? initialKey,
  ) {
    io.writeln(title);
    for (var i = 0; i < options.length; i++) {
      final (key, label, description) = options[i];
      final desc = description.isNotEmpty ? ' — $description' : '';
      final current = key == initialKey ? ' (current)' : '';
      io.writeln('  ${i + 1}) $label$desc$current');
    }
  }

  /// The line-mode answer loop of [_pickOption]: re-prompts until a valid
  /// 1-based number arrives; null on cancel.
  Future<String?> _promptOptionNumber(List<FlowOption> options) async {
    for (;;) {
      final answer = await _promptLine('type a number: ');
      if (answer == null) return null;
      final number = int.tryParse(answer.trim());
      if (number != null && number >= 1 && number <= options.length) {
        return options[number - 1].$1;
      }
      io.writeln(
        'invalid selection: ${answer.trim()} '
        '(1-${options.length}, Ctrl-C to cancel)',
      );
    }
  }

  /// The TUI variant of [_pickOption]: opens the menu on the controller
  /// and resolves with the picked key (or null on cancel). A stray pending
  /// picker answer is completed defensively as cancelled.
  Future<String?> _pickOptionTui(
    FaTuiController controller,
    String title,
    List<FlowOption> options, {
    String? initialKey,
  }) {
    final pending = _replaceWizardPickerAnswer();
    controller.openPicker('wizard:$title', title, [
      for (final (key, label, description) in options)
        MenuItem(key: key, label: label, description: description),
    ], initialKey: initialKey);
    return pending.future;
  }

  /// Installs a fresh wizard-picker answer completer; a stray pending one is
  /// completed defensively as cancelled.
  Completer<String?> _replaceWizardPickerAnswer() {
    final stray = _wizardPickerAnswer;
    if (stray?.isCompleted == false) stray!.complete(null);
    final pending = Completer<String?>();
    _wizardPickerAnswer = pending;
    return pending;
  }
}
