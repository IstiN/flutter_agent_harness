/// Approval prompt and TUI rendering split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line size gate.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for approval prompts.
extension on AgentCli {
  Future<ApprovalDecision> _promptForApproval(ApprovalRequest request) async {
    // TUI mode: prompt through the on-screen approval zone (y/a/n keys).
    final tui = _tuiController;
    if (_useTui && tui != null) return _promptForApprovalTui(tui, request);
    return _promptForApprovalLine(request);
  }

  /// The TUI branch of [_promptForApproval]: the on-screen approval zone;
  /// a cancel (Esc) or an unexpected answer type denies.
  Future<ApprovalDecision> _promptForApprovalTui(
    FaTuiController tui,
    ApprovalRequest request,
  ) async {
    final result = await tui.openPrompt(ApprovalPromptSpec(request: request));
    if (result is! ApprovalPromptAnswer) return ApprovalDecision.deny;
    _noteApproveAlwaysAnswer(result.value);
    return result.value;
  }

  /// Persists the "always" preference change when [decision] is
  /// [ApprovalDecision.approveAlways] (both prompt surfaces).
  void _noteApproveAlwaysAnswer(ApprovalDecision decision) {
    if (decision == ApprovalDecision.approveAlways) {
      config.onApprovalChanged?.call();
    }
  }

  /// The line-mode branch of [_promptForApproval]: prints the prompt lines
  /// and waits for [_handleLine] to route the answer line (or an interrupt
  /// to answer "no").
  Future<ApprovalDecision> _promptForApprovalLine(
    ApprovalRequest request,
  ) async {
    // Tool calls prepare sequentially (even in parallel batches), so at most
    // one prompt is pending; complete a stray one defensively.
    _pendingApprovalAnswer?.complete('n');
    final pending = Completer<String>();
    _pendingApprovalAnswer = pending;
    _writeApprovalPromptLines(request);
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete('n');
    });
    final answer = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingApprovalAnswer, pending)) {
      _pendingApprovalAnswer = null;
    }
    final decision = _approvalDecisionFor(answer);
    _noteApproveAlwaysAnswer(decision);
    return decision;
  }

  /// The three `[approval]` prompt lines (reason, tool + args, choices).
  void _writeApprovalPromptLines(ApprovalRequest request) {
    io.writeln('[approval] ${request.reason}');
    io.writeln(
      '[approval] tool: ${request.toolName} (${request.tier.name} tier) — '
      '${formatArgs(request.arguments)}',
    );
    io.writeln(
      '[approval] allow? [y]es once / [n]o / [a]lways for '
      '"${request.toolName}"',
    );
  }

  /// Maps the typed approval answer to a decision; anything unrecognized
  /// denies (safe default).
  ApprovalDecision _approvalDecisionFor(String answer) =>
      switch (answer.toLowerCase()) {
        'y' || 'yes' => ApprovalDecision.approveOnce,
        'a' || 'always' => ApprovalDecision.approveAlways,
        _ => ApprovalDecision.deny,
      };

  /// Reads one input line for the ask menu. Resolves to `null` on cancel
  /// (Ctrl-C interrupt or input shutdown), which the menu maps to "ask
  /// cancelled by user".
  Future<String?> _nextAskLine() async {
    // Ask forces its tool batch to sequential execution, so at most one
    // prompt is pending; complete a stray one defensively as cancelled.
    final stray = _pendingAskAnswer;
    if (stray != null && !stray.isCompleted) stray.complete(null);
    final pending = Completer<String?>();
    _pendingAskAnswer = pending;
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete(null);
    });
    final line = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingAskAnswer, pending)) {
      _pendingAskAnswer = null;
    }
    return line;
  }

  /// against a second `/provider custom` while one is running). While true,
  /// input lines buffer here instead of steering or starting runs.

  /// outruns the flow); consumed by the next `_promptLine` call.

  /// Answers an `ask` question set by walking [questions] one at a time.
  Future<List<AskAnswer>?> _answerAskQuestions(
    List<AskQuestion> questions,
  ) async {
    // TUI mode: each question runs through the on-screen prompt zone.
    final tui = _tuiController;
    if (_useTui && tui != null) return _answerAskQuestionsTui(tui, questions);
    final answers = <AskAnswer>[];
    for (var i = 0; i < questions.length; i++) {
      final answer = await _askOneQuestion(questions[i], i, questions.length);
      if (answer == null) return null;
      answers.add(answer);
    }
    return answers;
  }

  /// The TUI branch of [_answerAskQuestions]: walks [questions] through the
  /// on-screen prompt zone; any cancel (Esc on the zone) or unexpected
  /// answer type aborts the whole batch, matching line mode.
  Future<List<AskAnswer>?> _answerAskQuestionsTui(
    FaTuiController tui,
    List<AskQuestion> questions,
  ) async {
    final answers = <AskAnswer>[];
    for (var i = 0; i < questions.length; i++) {
      final answer = await _answerOneAskQuestionTui(
        tui,
        questions[i],
        i,
        questions.length,
      );
      if (answer == null) return null;
      answers.add(answer);
    }
    return answers;
  }

  /// One TUI ask question: the prompt-zone answer, or null when cancelled
  /// (or the zone resolved with an unexpected type).
  Future<AskAnswer?> _answerOneAskQuestionTui(
    FaTuiController tui,
    AskQuestion question,
    int index,
    int total,
  ) async {
    final result = await tui.openPrompt(
      AskPromptSpec(
        header: 'Ask',
        question: question.question,
        index: index,
        total: total,
        options: question.options,
        multiSelect: question.multiSelect,
        recommended: question.recommended,
      ),
    );
    return result is AskPromptAnswer ? result.value : null;
  }

  /// Answers a `request_secret` call: prompts the user for the credential
  /// value via the same input mechanism as ask. Returns `null` on cancel
  /// (the agent sees "user declined"). The value is injected into the live
  /// shell env via the session-correlation env decorator so `$NAME` works
  /// in subsequent bash commands, and registered with the secret redactor.
  Future<RequestSecretResult?> _answerSecretRequest(
    String name,
    String reason,
  ) async {
    final tui = _tuiController;
    if (_useTui && tui != null) return _answerSecretTui(tui, name, reason);
    return _answerSecretLineMode(name, reason);
  }

  /// The TUI branch of [_answerSecretRequest].
  Future<RequestSecretResult?> _answerSecretTui(
    FaTuiController tui,
    String name,
    String reason,
  ) async {
    final result = await tui.openPrompt(
      SecretPromptSpec(name: name, reason: reason),
    );
    if (result is! SecretPromptAnswer) return null;
    _runtimeSecrets[name] = result.value.value;
    config.onSecretGranted?.call(name, result.value.value);
    return result.value;
  }

  /// The line-mode branch of [_answerSecretRequest].
  Future<RequestSecretResult?> _answerSecretLineMode(
    String name,
    String reason,
  ) async {
    io.writeln('[secret] $name needed: $reason');
    io.write('[secret] Enter value for $name (empty = decline): ');
    final line = await _nextAskLine();
    if (line == null || line.trim().isEmpty) return null;
    final value = line.trim();
    _runtimeSecrets[name] = value;
    config.onSecretGranted?.call(name, value);
    return RequestSecretResult(name: name, value: value, persisted: false);
  }

  /// env vars so `$NAME` works in bash tool executions.

  /// Renders one question as a numbered menu (+ "(Recommended)" marker) and
  /// reads the answer: a number selects an option, `m` opens the
  /// multi-select toggle (multiSelect questions only), empty input switches
  /// to free-text entry, any other non-number text is taken as the free-text
  /// answer directly, and `!` cancels the whole ask.
  Future<AskAnswer?> _askOneQuestion(
    AskQuestion question,
    int index,
    int total,
  ) async {
    _printAskQuestion(question, index, total);
    if (question.options.isEmpty) return _readFreeTextAnswer();
    final multiHint = question.multiSelect ? ', m = multi-select' : '';
    io.writeln(
      '[ask] 1-${question.options.length} = select$multiHint, '
      'empty = your own answer, ! = cancel',
    );
    return _askSelectOption(question);
  }

  /// The question header and numbered option list (recommended flagged) —
  /// the lines come from [askQuestionLines].
  void _printAskQuestion(AskQuestion question, int index, int total) {
    for (final line in askQuestionLines(question, index, total)) {
      io.writeln(line);
    }
  }

  /// The single-select loop: a number picks an option, empty input falls
  /// through to free-text, `m` enters multi-select, `!` cancels.
  Future<AskAnswer?> _askSelectOption(AskQuestion question) async {
    while (true) {
      final line = await _nextAskLine();
      if (line == null || line == '!') return null;
      if (line.isEmpty) return _readFreeTextAnswer();
      if (question.multiSelect && line.toLowerCase() == 'm') {
        return _askMultiSelect(question);
      }
      final parsed = _parseOptionAnswer(question, line);
      if (parsed.answer != null) return parsed.answer;
      io.writeln('[ask] no option ${parsed.number} — try again');
    }
  }

  /// Parses one select-loop line: a valid number becomes a selection, a
  /// non-number becomes free text, and an out-of-range number comes back as
  /// ([AskAnswer?].answer = null, number) so the loop can complain and
  /// retry.
  ({AskAnswer? answer, int? number}) _parseOptionAnswer(
    AskQuestion question,
    String line,
  ) {
    final number = int.tryParse(line);
    if (number == null) return (answer: AskAnswer.text(line), number: null);
    if (number >= 1 && number <= question.options.length) {
      return (
        answer: AskAnswer.selection([question.options[number - 1].label]),
        number: number,
      );
    }
    return (answer: null, number: number);
  }

  /// The multi-select toggle loop: numbers toggle options, `d` (or empty
  /// input) confirms — falling back to free-text entry when nothing is
  /// selected — and `!` cancels.
  Future<AskAnswer?> _askMultiSelect(AskQuestion question) async {
    final selected = <int>{};
    while (true) {
      io.writeln(
        '[ask] multi-select: numbers toggle, d = done, ! = cancel '
        '(selected: ${pickedLabel(selected)})',
      );
      final line = await _nextAskLine();
      if (line == null || line == '!') return null;
      if (line.isEmpty || line.toLowerCase() == 'd') {
        return _finishMultiSelect(question, selected);
      }
      if (_toggleMultiSelectParts(question, selected, line)) {
        io.writeln('[ask] invalid selection "$line" — try again');
      }
    }
  }

  /// Done with multi-select: the toggled options as a selection, or
  /// free-text entry when nothing is selected.
  Future<AskAnswer?> _finishMultiSelect(
    AskQuestion question,
    Set<int> selected,
  ) async {
    if (selected.isNotEmpty) {
      return AskAnswer.selection([
        for (final i in selected.toList()..sort()) question.options[i].label,
      ]);
    }
    return _readFreeTextAnswer();
  }

  /// Toggles every number in [line] (space/comma separated). Returns whether
  /// any part was invalid.
  bool _toggleMultiSelectParts(
    AskQuestion question,
    Set<int> selected,
    String line,
  ) {
    for (final part in line.split(RegExp(r'[\s,]+'))) {
      final number = int.tryParse(part);
      if (number == null || number < 1 || number > question.options.length) {
        return true;
      }
      if (!selected.remove(number - 1)) selected.add(number - 1);
    }
    return false;
  }

  /// Free-text entry for the ask menu; an empty line cancels the whole ask.
  Future<AskAnswer?> _readFreeTextAnswer() async {
    io.writeln('[ask] type your answer (empty = cancel):');
    final text = await _nextAskLine();
    if (text == null || text.isEmpty) return null;
    return AskAnswer.text(text);
  }

  void _handleApprovalMode(String rest) {
    if (rest.isEmpty) {
      io.writeln('approval mode: ${_approval.mode.label}');
      io.writeln('approval modes: always-ask, write, yolo');
      final allowed = _approval.alwaysAllowedTools;
      io.writeln(
        'always-allowed tools: ${allowed.isEmpty ? '(none)' : allowed.join(', ')}',
      );
      return;
    }
    final mode = approvalModeFromLabel(rest);
    if (mode == null) {
      io.writeln('unknown approval mode: $rest (want always-ask|write|yolo)');
      return;
    }
    _approval.mode = mode;
    io.writeln('approval mode set to ${mode.label}');
    config.onApprovalChanged?.call();
  }

  void _handleAllow(String rest) {
    if (rest.isEmpty) {
      final allowed = _approval.alwaysAllowedTools;
      io.writeln(
        'always-allowed tools: ${allowed.isEmpty ? '(none)' : allowed.join(', ')}',
      );
      return;
    }
    final name = rest.split(RegExp(r'\s+')).first;
    final known = _agent.state.tools.any((tool) => tool.name == name);
    if (!known) {
      io.writeln('unknown tool: $name');
      return;
    }
    _approval.allowAlways(name);
    io.writeln('"$name" always allowed (persisted)');
    config.onApprovalChanged?.call();
  }

  Future<void> _switchMode(String name) async {
    final mode = _modes[name];
    if (mode == null) {
      io.writeln('unknown mode: $name');
      return;
    }
    _currentMode = mode;
    _applyPromptComposition();
    io.writeln('switched mode to ${mode.name}');
    config.onModeChanged?.call(mode.name);
  }

  /// Renders the model-roles no-silent-degrade note: every retry, key
  /// rotation, and chain failover is announced inline, and the display
  /// model tracks the active chain entry.
  void _onRolesNotice(FallbackNotice notice) {
    io.writeln('[roles] ${notice.describe()}');
    final resolved = config.modelRolesResolver?.resolveRole(defaultModelRole);
    if (resolved != null) _agent.state.model = resolved.model;
  }

  /// Runs a raw shell command prefixed with `!` through [config.env] and
  /// prints its stdout/stderr/exit code directly.
  Future<void> _runShellCommand(String command) async {
    final result = await config.env.exec(command);
    switch (result) {
      case Ok(:final value):
        if (value.stdout.isNotEmpty) {
          io.write(value.stdout);
          if (!value.stdout.endsWith('\n')) io.write('\n');
        }
        if (value.stderr.isNotEmpty) io.writeln(value.stderr);
        if (value.exitCode != 0) {
          io.writeln('exit code: ${value.exitCode}');
        }
      case Err(:final error):
        io.writeln('shell error: ${error.message}');
    }
  }

  /// A compact status bar shown above every idle prompt: cwd, model, tokens,
  /// cost, and turn count.
  String _statusLine() {
    final model = _agent.state.model;
    final total = _usage.total;
    final cost = total.cost.total.toStringAsFixed(4);
    final cwd = config.env.cwd;
    // Current context pressure: the last assistant message's prompt size
    // against the model's context window (pi's `context: N% (used/max)`).
    // Error/aborted terminal messages carry Usage.zero — skip them, or the
    // gauge snaps back to 0% right after a failed run. Scanned from the END:
    // this runs on every rendered frame, so a full-history forward scan
    // (allocating lazy iterables over hundreds of messages) is wasted work.
    final lastAssistant = _agent.state.messages.reversed
        .whereType<AssistantMessage>()
        .where((m) => m.usage.input > 0)
        .firstOrNull;
    final contextTokens = lastAssistant?.usage.input ?? 0;
    final window = model.contextWindow;
    final pct = window > 0 ? (contextTokens / window * 100).round() : 0;
    // kimi's toolbar badge: active background agents, when any. Variant A
    // (agents visualization): named live badges — up to 3 active children
    // with type and elapsed seconds, then a +N overflow counter.
    final badge = _agentsBadge();
    return '$cwd · ctx $pct% '
        '(${_formatTokenCount(contextTokens)}/${_formatTokenCount(window)}) · '
        '${total.totalTokens}tok · \$$cost · turn ${_usage.turns}$badge · '
        '${model.id}';
  }

  /// Live agents badge for the status line: active subagent handles with
  /// their type and elapsed time (e.g. `bg:explore:A1(12s),+2`), or empty.
  String _agentsBadge() {
    final active = _subagentManager.handles
        .where(
          (h) =>
              h.status == SubagentStatus.queued ||
              h.status == SubagentStatus.running ||
              h.status == SubagentStatus.idle,
        )
        .toList();
    if (active.isEmpty) {
      final queuedJobs = _taskConfig.jobManager.jobs
          .where((job) => job.status == TaskJobStatus.queued)
          .length;
      return queuedJobs > 0 ? ' · bg:$queuedJobs' : '';
    }
    final now = DateTime.now();
    final shown = active
        .take(3)
        .map((h) {
          final created = DateTime.tryParse(h.createdAt);
          final elapsed = created == null
              ? 0
              : now.difference(created).inSeconds;
          return '${h.agentType}:${h.id}(${elapsed}s)';
        })
        .join(',');
    final overflow = active.length > 3 ? ',+${active.length - 3}' : '';
    return ' · bg:$shown$overflow';
  }

  /// Compact token counts like pi's `275k` / `1M`.
  static String _formatTokenCount(int value) {
    if (value >= 1000000) {
      final m = value / 1000000;
      return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
    }
    if (value >= 1000) {
      final k = value / 1000;
      return '${k.toStringAsFixed(k >= 100 ? 0 : 1)}k';
    }
    return '$value';
  }

  /// Prints a divider, the status bar, and the input prompt. Used whenever the
  /// REPL becomes idle after a command or a run. In TUI mode the prompt is
  /// already part of the rendered frame, so this is a no-op there.
  void _writeIdlePrompt() {
    if (_useTui) return;
    if (!_exited) {
      io.writeln(_style.dim('─' * 60));
      io.writeln(_style.dim(_statusLine()));
      io.write(_style.bold(_style.cyan(prompt)));
    }
  }

  /// Prompt-based slash menu for terminals that cannot enter raw/ANSI mode.
  /// Shows a numbered list of commands and reads the user's choice from the
  /// same [lineIterator] that drives the REPL loop.
  Future<String?> _showLineModeMenu(StreamIterator<String> lineIterator) async {
    for (final line in lineModeMenuLines(_style)) {
      io.writeln(line);
    }
    io.write('Pick a command (number or name), or press Enter to cancel: ');
    if (!await lineIterator.moveNext()) return null;
    final trimmed = lineIterator.current.trim();
    if (trimmed.isEmpty) return null;
    final choice = _resolveMenuChoice(trimmed);
    if (choice == null) io.writeln('unknown choice: $trimmed');
    return choice;
  }

  /// Resolves a line-mode menu answer: a 1-based number, or a command name
  /// with or without the leading slash. Null when neither matches.
  String? _resolveMenuChoice(String trimmed) {
    final commands = builtinSlashCommands.entries.toList();
    // Numeric choice.
    final index = int.tryParse(trimmed);
    if (index != null && index >= 1 && index <= commands.length) {
      return commands[index - 1].key;
    }
    // Name choice; accept with or without leading slash.
    final name = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    if (builtinSlashCommands.containsKey(name)) return name;
    return null;
  }

  /// The numbered command list of the line-mode menu.
  void _printHelp({String filter = ''}) {
    for (final line in helpLines(
      filter: filter,
      pluginSlashCommands: _pluginSlashCommands,
      templates: _templates,
      style: _style,
    )) {
      io.writeln(line);
    }
  }

  void _printStats() {
    final total = _usage.total;
    io.writeln('turns: ${_usage.turns}');
    io.writeln('input tokens: ${total.input}');
    io.writeln('output tokens: ${total.output}');
    io.writeln('cache read tokens: ${total.cacheRead}');
    io.writeln('cache write tokens: ${total.cacheWrite}');
    io.writeln('total tokens: ${total.totalTokens}');
    io.writeln('cost: \$${total.cost.total.toStringAsFixed(4)}');
  }

  /// Called when a background `task` job settles (omp's async-result flow):
  /// renders a transcript notification and injects the result back into the
  /// parent conversation — steered mid-run, or as a fresh re-wake run while
  /// idle (omp's idle flush via `agent.prompt`).
  void _onTaskJobCompleted(TaskJob job) {
    final result = job.result;
    final seconds = result == null
        ? ''
        : ' in ${(result.duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
    io.writeln(
      _style.dim(
        '[task] ${job.id} (${job.agent}) ${job.status.name}$seconds — '
        'agent://${job.id}',
      ),
    );
    if (_exited) return;
    final message = _buildAsyncResultMessage(job);
    if (isBusy) {
      // Mid-run: the steering queue delivers it at the next step boundary
      // (omp's non-interrupting aside between requests).
      _agent.steer(UserMessage.text(message));
    } else {
      _startRun(message);
    }
  }

  /// The async-result message re-injected into the parent conversation when
  /// a background job settles (omp's `<system-notice>` + `<task-result>`
  /// envelope, reduced: no artifact spill — the pointer is `agent://<id>`).
  static const _asyncResultPreviewChars = 4000;

  String _buildAsyncResultMessage(TaskJob job) {
    final result = job.result;
    final buffer = StringBuffer()
      ..writeln('<system-notice>')
      ..writeln(
        'Background agent ${job.id} (${job.agent}) finished with status: '
        '${job.status.name}.',
      )
      ..writeln('Task: ${job.task}')
      ..writeln()
      ..write(
        '<task-result id="${job.id}" agent="${job.agent}" '
        'status="${job.status.name}">',
      );
    final output = result?.output ?? '';
    if (output.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          output.length > _asyncResultPreviewChars
              ? '${output.substring(0, _asyncResultPreviewChars)}\n…\n'
                    '[Full output: agent://${job.id}]'
              : output,
        );
    }
    final error = result?.error;
    if (error != null) buffer.write('\nerror: $error');
    buffer
      ..write('\n</task-result>')
      ..write('\n</system-notice>');
    return buffer.toString();
  }

  /// `/tasks [cancel <id>]` — lists the session's background agents with
  /// their states (kimi's TaskList surface; cancelling a running job aborts
  /// its child run, which then settles as aborted).
  void _listTaskJobs(String rest) {
    final parts = rest
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    final verb = parts.isEmpty ? '' : parts.first;
    if (verb == 'cancel') {
      _cancelTaskJob(parts);
      return;
    }
    final jobs = _taskConfig.jobManager.jobs;
    if (jobs.isEmpty) {
      io.writeln('no background agents this session');
      return;
    }
    for (final line in taskJobLines(jobs, dim: _style.dim)) {
      io.writeln(line);
    }
  }

  /// `/tasks cancel <id>`: aborts the job's child run.
  void _cancelTaskJob(List<String> parts) {
    if (parts.length < 2) {
      io.writeln('usage: /tasks cancel <id>');
      return;
    }
    _cancelTaskJobById(parts[1]);
  }

  /// Cancels the job named [id], or reports it as unknown.
  void _cancelTaskJobById(String id) {
    final job = _taskConfig.jobManager.job(id);
    if (job == null) {
      io.writeln('unknown task job: $id');
      return;
    }
    job.cancel();
    io.writeln('cancelled ${job.id}');
  }

  void _onAgentEvent(AgentEvent event, CancelToken cancelToken) {
    switch (event) {
      case MessageStartEvent(:final message) || MessageEndEvent(:final message):
        _onMessageLifecycle(message, start: event is MessageStartEvent);
      case MessageUpdateEvent(:final assistantMessageEvent):
        _onMessageUpdate(assistantMessageEvent);
      case ToolExecutionStartEvent(:final toolName, :final args):
        _onToolExecutionStart(toolName, args);
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
        _onToolExecutionEnd(toolName, result, isError: isError);
      case TurnEndEvent(:final message):
        _usage.add(message.usage);
      default:
    }
  }

  /// Message lifecycle for assistant turns: a start re-arms the
  /// once-per-message prefix; an end flushes the stream and reports the
  /// stop reason.
  void _onMessageLifecycle(Message message, {required bool start}) {
    if (message is! AssistantMessage) return;
    if (start) {
      _assistantPrefixPrinted = false;
      return;
    }
    _onAssistantMessageEnd(message);
  }

  /// Tool call header line: the bold indigo name plus dimmed args.
  void _onToolExecutionStart(String toolName, Map<String, dynamic> args) {
    io.writeln(
      '${_style.bold(_style.indigo('[$toolName]'))} '
      '${_style.dim(formatArgs(args))}',
    );
  }

  /// Streaming deltas: answer text (with the once-per-message prefix) and —
  /// TUI only — dimmed thinking as the progress signal.
  void _onMessageUpdate(AssistantMessageEvent assistantMessageEvent) {
    if (assistantMessageEvent is TextDeltaEvent) {
      // The answer text starts on its own line after the dimmed
      // thinking block.
      if (_streamedThinking && !_streamedText) io.write('\n');
      _writeAssistantPrefix();
      io.write(assistantMessageEvent.delta);
      _streamedText = true;
    } else if (assistantMessageEvent is ThinkingDeltaEvent && _useTui) {
      // Reasoning models stream long thinking before any text; showing
      // it dimmed under the user message is the TUI's progress signal.
      io.write(_style.dim(assistantMessageEvent.delta));
      _streamedThinking = true;
    }
  }

  /// End of an assistant message: flush the stream newline, then report the
  /// stop reason (errors, aborts, silent truncations, empty responses).
  void _onAssistantMessageEnd(AssistantMessage message) {
    if (_streamedText || _streamedThinking) {
      // The trailing newline of the streamed text belongs to the
      // primary channel (write), not to diagnostics (writeln) — a
      // headless host routes only writeln to stderr.
      io.write('\n');
      _streamedText = false;
      _streamedThinking = false;
    }
    switch (message.stopReason) {
      case StopReason.error:
        io.writeln(_errorLine(message.errorMessage ?? 'unknown error'));
      case StopReason.aborted:
        // A TTSR abort is a rule trigger, not a failure — the
        // controller already announced it (omp renders a
        // notification instead of the aborted stop reason).
        if (!(_ttsr?.isAbortPending ?? false)) {
          io.writeln('aborted: ${message.errorMessage ?? 'aborted'}');
        }
      default:
        _noteQuietMessageEnd(message);
    }
  }

  /// The non-error/non-abort stop reasons: a tolerated silent truncation
  /// warning, or a note when the turn produced neither text nor tool calls.
  void _noteQuietMessageEnd(AssistantMessage message) {
    // A tolerated silent truncation (no finish_reason) is flagged
    // on the message — tell the user the reply may be cut off.
    if (message.errorMessage != null) {
      io.writeln(_style.dim('(${message.errorMessage})'));
      return;
    }
    // A turn that ends with neither text nor tool calls leaves the
    // user staring at silence (seen with OpenRouter free models
    // that burn the whole completion on reasoning). Say so.
    final hasText = message.content.any(
      (c) => c is TextContent && c.text.trim().isNotEmpty,
    );
    final hasToolCalls = message.content.any((c) => c is ToolCall);
    if (!hasText && !hasToolCalls) {
      io.writeln(
        _style.dim(
          '(empty response: the model returned no text — '
          'it may be rate-limited or reasoning-only)',
        ),
      );
    }
  }

  /// Tool result line: a red error snippet or a teal done marker.
  void _onToolExecutionEnd(
    String toolName,
    ToolExecutionResult result, {
    required bool isError,
  }) {
    final tool = _style.bold(_style.indigo('[$toolName]'));
    if (isError) {
      final text = result.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
      var snippet = text.split('\n').first;
      if (snippet.length > 120) {
        snippet = '${snippet.substring(0, 120)}...';
      }
      io.writeln('$tool ${_style.red('error')}: $snippet');
    } else {
      io.writeln('$tool ${_style.teal('done')}');
    }
  }

  /// Prints the `>_Fa ` prefix once per assistant message, before the first
  /// text delta. TUI-only: headless and line-mode output stay plain (a piped
  /// headless response must remain the bare assistant text).
  void _writeAssistantPrefix() {
    if (!_useTui || _assistantPrefixPrinted) return;
    io.write('${_style.bold(_style.teal('>_'))}${_style.bold('Fa')} ');
    _assistantPrefixPrinted = true;
  }
}
