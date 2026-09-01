/// Approval prompt and TUI rendering split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line size gate.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for approval prompts.
extension ApprovalCommands on AgentCli {
  /// Answers any pending approval/ask prompt defensively so a tool call
  /// never waits on an answer that cannot arrive.
  void _cancelPendingAnswers() {
    _pendingApprovalAnswer?.complete('n');
    _pendingApprovalAnswer = null;
    _pendingAskAnswer?.complete(null);
    _pendingAskAnswer = null;
  }

  Future<ApprovalDecision> _promptForApproval(ApprovalRequest request) async {
    // TUI mode: prompt through the on-screen approval zone (y/a/n keys).
    final tui = _tuiController;
    if (_useTui && tui != null) return _promptForApprovalTui(tui, request);
    return _promptForApprovalLine(request);
  }

  /// The TUI branch of [_promptForApproval]: the on-screen approval zone;
  /// a cancel (Esc) or an unexpected answer type denies. A typed note rides
  /// along as steering feedback so the model sees it at the next step.
  Future<ApprovalDecision> _promptForApprovalTui(
    FaTuiController tui,
    ApprovalRequest request,
  ) async {
    final result = await tui.openPrompt(ApprovalPromptSpec(request: request));
    if (result is! ApprovalPromptAnswer) return ApprovalDecision.deny;
    final note = result.note.trim();
    if (note.isNotEmpty) {
      _agent.steer(
        UserMessage.text(
          'Note from the user while approving "${request.toolName}": $note',
        ),
      );
    }
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
      io.writeln('approval modes: always-ask, write, yolo, unattended');
      final allowed = _approval.alwaysAllowedTools;
      io.writeln(
        'always-allowed tools: ${allowed.isEmpty ? '(none)' : allowed.join(', ')}',
      );
      return;
    }
    final mode = approvalModeFromLabel(rest);
    if (mode == null) {
      io.writeln(
        'unknown approval mode: $rest '
        '(want always-ask|write|yolo|unattended)',
      );
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
    // Hide the price when the model carries no cost data — a permanent
    // "$0.0000" reads as a bug (and we genuinely don't know the price).
    final cost = total.cost.total;
    final costPart = cost > 0 ? ' · \$${cost.toStringAsFixed(4)}' : '';
    final cwd = _env.cwd;
    // Live context pressure: provider-reported usage up to the last reported
    // turn plus an estimate of the trailing messages (what the NEXT request
    // carries) — moves mid-run as tool results and the stream land, instead
    // of freezing at the last turn's prompt size.
    final contextTokens = _liveContextTokens();
    // Live token counter: settled turns plus the in-flight stream estimate.
    var totalTokens = total.totalTokens;
    final streaming = _agent.state.streamingMessage;
    if (streaming != null) totalTokens += estimateTokens(streaming);
    final window = model.contextWindow;
    final pct = window > 0 ? (contextTokens / window * 100).round() : 0;
    // kimi's toolbar badge: active background agents, when any. Variant A
    // (agents visualization): named live badges — up to 3 active children
    // with type and elapsed seconds, then a +N overflow counter.
    final badge = _agentsBadge();
    return '$cwd · ctx $pct% '
        '(${_formatTokenCount(contextTokens)}/${_formatTokenCount(window)}) · '
        '${_formatTokenCount(totalTokens)}tok'
        '$costPart · turn ${_usage.turns}$badge · '
        '${_statusProviderLabel(model)}/${model.id}';
  }

  /// Status-bar provider label: the saved custom entry's name when the
  /// model's endpoint belongs to one — the user picked "z.ai"/"codemie",
  /// while the model's `provider` field carries the catalog protocol kind
  /// ("openai") that means nothing to them. Falls back to the catalog
  /// provider name when no saved entry matches the endpoint.
  String _statusProviderLabel(Model model) {
    final entries = config.customProviders?.entries;
    if (entries == null) return model.provider;
    // The explicitly ACTIVE saved entry wins over the endpoint scan:
    // two entries can share one baseUrl (two accounts on the same
    // host — kimi-ira1 + kimi_me), and the first-match scan would
    // label the model with the OTHER account's name.
    final active = _activeCustomName;
    if (active != null) {
      for (final entry in entries) {
        if (entry.name == active &&
            _sameEndpoint(entry.baseUrl, model.baseUrl)) {
          return entry.name;
        }
      }
    }
    return _endpointEntryLabel(entries, model) ?? model.provider;
  }

  /// The saved entry name for [model]'s endpoint. A restored session
  /// has no [_activeCustomName], but the persisted roles chain pins
  /// the endpoint's apiKeyName — it identifies WHICH of several
  /// same-endpoint accounts was picked. Without a pin the first
  /// endpoint match labels the model (legacy behavior).
  String? _endpointEntryLabel(List<CustomProviderEntry> entries, Model model) {
    final pinnedKey = _chainKeyNameFor(model.provider, model.baseUrl);
    String? first;
    for (final entry in entries) {
      if (!_sameEndpoint(entry.baseUrl, model.baseUrl)) continue;
      if (pinnedKey != null && entry.keyName == pinnedKey) {
        return entry.name;
      }
      first ??= entry.name;
    }
    return first;
  }

  /// The apiKeyName the default roles chain pins for
  /// ([provider], [baseUrl]) — null without a resolver or a pinned key.
  String? _chainKeyNameFor(String provider, String baseUrl) {
    final resolver = config.modelRolesResolver;
    if (resolver == null) return null;
    final refs =
        resolver.config.chainFor(
          defaultModelRole,
          cwd: config.env.cwd,
          homeDir: config.homeDir,
        ) ??
        const <ModelRef>[];
    for (final ref in refs) {
      final refBase = ref.baseUrl;
      if (ref.provider == provider &&
          refBase != null &&
          _sameEndpoint(refBase, baseUrl)) {
        return ref.apiKeyName;
      }
    }
    return null;
  }

  /// Test hook for [_statusProviderLabel] on the current model.
  @visibleForTesting
  String statusProviderLabelForTest() =>
      _statusProviderLabel(_agent.state.model);

  /// Endpoint equality ignoring a trailing slash (saved entries and pinned
  /// chains disagree on it routinely).
  bool _sameEndpoint(String a, String b) {
    String norm(String u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u;
    return norm(a) == norm(b);
  }

  /// Live context pressure for the status line: provider-reported usage up
  /// to the last reported turn plus an estimate of the trailing messages
  /// (what the NEXT request carries) — moves mid-run as tool results and
  /// the stream land, instead of freezing at the last turn's prompt size.
  /// The SETTLED part is memoized on the message list identity + length
  /// ([SettledContextEstimate]); the in-flight stream message is estimated
  /// per call and never touches the memo. Keying the settled memo on the
  /// stream's growing length would invalidate it on EVERY delta — a full
  /// O(context) re-scan dozens of times per second (the "typing lag").
  int _liveContextTokens() {
    final messages = _agent.state.messages;
    final streaming = _agent.state.streamingMessage;
    var tokens = _ctxEstimate.settled(messages);
    if (streaming != null) tokens += estimateTokens(streaming);
    return tokens;
  }

  /// Live agents badge for the status line: active subagent handles with
  /// their type and elapsed time (e.g. `bg:explore:A1(12s),+2`), or empty.
  String _agentsBadge() {
    final badge = formatActiveAgentsBadge(_subagentManager.handles);
    if (badge.isNotEmpty) return ' · $badge';
    final queuedJobs = _taskConfig.jobManager.jobs
        .where((job) => job.status == TaskJobStatus.queued)
        .length;
    return queuedJobs > 0 ? ' · bg:$queuedJobs' : '';
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
  /// Shows a numbered list of commands and skills, and reads the user's
  /// choice from the same [lineIterator] that drives the REPL loop. A skill
  /// choice resolves to `/skill:<name>` (line mode has no input field to
  /// pre-fill, so the skill runs immediately, without args).
  Future<String?> _showLineModeMenu(StreamIterator<String> lineIterator) async {
    for (final line in lineModeMenuLines(_style, skills: _skills)) {
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

  String? _resolveMenuChoice(String trimmed) =>
      resolveLineModeMenuChoice(trimmed, _skills);

  /// The numbered command list of the line-mode menu.
  void _printHelp({String filter = ''}) {
    for (final line in helpLines(
      filter: filter,
      pluginSlashCommands: _pluginSlashCommands,
      templates: _templates,
      style: _style,
      skills: _skills,
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

  /// `/tasks [cancel <id>]` — lists the session's background agents and
  /// background shell jobs with their states (kimi's TaskList surface;
  /// cancelling a running job aborts its child run / stops the process,
  /// which then settles as aborted).
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
    final shellJobs = _shellJobs.jobs;
    if (jobs.isEmpty && shellJobs.isEmpty) {
      io.writeln('no background jobs this session');
      return;
    }
    if (jobs.isNotEmpty) {
      for (final line in taskJobLines(jobs, dim: _style.dim)) {
        io.writeln(line);
      }
    }
    if (shellJobs.isNotEmpty) {
      io.writeln('background shell jobs:');
      for (final entry in shellJobs) {
        io.writeln(_shellJobLine(entry));
      }
    }
  }

  /// One `/tasks` row for a background shell job.
  String _shellJobLine(ShellJobEntry entry) {
    final state = entry.isRunning ? '● running' : '✓ exited(${entry.exitCode})';
    final command = entry.command.length > 60
        ? '${entry.command.substring(0, 59)}…'
        : entry.command;
    return '  ${entry.id}: $state — $command '
        '${_style.dim('(log: ${entry.logPath})')}';
  }

  /// `/tasks cancel <id>`: aborts the job's child run / stops the process.
  void _cancelTaskJob(List<String> parts) {
    if (parts.length < 2) {
      io.writeln('usage: /tasks cancel <id>');
      return;
    }
    _cancelTaskJobById(parts[1]);
  }

  /// Cancels the task job or stops the shell job named [id], or reports it
  /// as unknown.
  void _cancelTaskJobById(String id) {
    final job = _taskConfig.jobManager.job(id);
    if (job != null) {
      job.cancel();
      io.writeln('cancelled ${job.id}');
      return;
    }
    final shellOutput = _cancelShellJobById(id, _shellJobs);
    if (shellOutput != null) {
      io.writeln(shellOutput);
      return;
    }
    io.writeln('unknown job: $id');
  }

  /// Stops the shell job [id] and returns the message to print, or null if
  /// there is no such shell job.
  String? _cancelShellJobById(String id, ShellJobRegistry jobs) {
    final shellJob = jobs.job(id);
    if (shellJob == null) return null;
    if (!shellJob.isRunning) {
      return '$id already finished (exit code ${shellJob.exitCode})';
    }
    unawaited(shellJob.stop());
    return 'stopped ${shellJob.id}';
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken cancelToken) async {
    // Run-lifecycle forensics to fa.log: one line per phase transition, so
    // a wedged "Working…"/"Compacting…" row can be attributed to the exact
    // phase (provider turn vs named tool vs run) that never finished.
    switch (event) {
      case AgentStartEvent():
        _logDiagnostic('run start sid=$_logSid');
      case TurnStartEvent():
        _logDiagnostic('turn start sid=$_logSid');
      case ToolExecutionStartEvent(:final toolName):
        _logDiagnostic('tool start sid=$_logSid name=$toolName');
      case ToolExecutionEndEvent(:final toolName, :final isError):
        _logDiagnostic('tool end sid=$_logSid name=$toolName error=$isError');
      case TurnEndEvent(:final message):
        _logDiagnostic('turn end sid=$_logSid stop=${message.stopReason.name}');
      case AgentEndEvent():
        _logDiagnostic('run end sid=$_logSid');
      default:
    }
    await _persistIncremental(event);
    handleAgentEvent(
      event,
      onMessageLifecycle: _onMessageLifecycle,
      onMessageUpdate: _onMessageUpdate,
      onToolExecutionStart: _onToolExecutionStart,
      onToolExecutionEnd: _onToolExecutionEnd,
      onTurnEnd: (message) => _usage.add(message.usage),
    );
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

  /// Tool call header line: the bold indigo name plus dimmed args. Also
  /// records file-path args into [_touchedPaths] so path-gated skills
  /// (`paths:` frontmatter) join the prompt on the next turn.
  void _onToolExecutionStart(String toolName, Map<String, dynamic> args) {
    for (final key in const ['path', 'file', 'filePath', 'target']) {
      final value = args[key];
      if (value is String && value.isNotEmpty) _touchedPaths.add(value);
    }
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
      // Even reasoning snippets benefit from inline markdown (bold spans
      // for emphasis, inline code for self-references) — we apply the
      // same inline renderer the answer text gets, then dim the whole
      // result so the thinking still reads as background context.
      final inline = renderInlineMarkdown(assistantMessageEvent.delta);
      io.write(_style.dim(inline));
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
        // The CLI auto-reauthorizes CodeMie sessions after expiry; skip the
        // generic error line here so [_runPrompt] can print the actionable
        // prompt and launch the browser SSO flow instead.
        if (authExpiredProvider(message.errorMessage ?? '') == 'codemie') {
          return;
        }
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
