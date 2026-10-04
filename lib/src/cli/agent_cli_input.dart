part of 'agent_cli.dart';

// Input routing of [AgentCli] — the line-level dispatch pipeline
// (_handleLine → _routePendingInput → _dispatchInput → _sendUserMessage →
// _startRun) plus the path-led-chat guard and the restored-session replay.
// Split out of `agent_cli.dart` to keep it under the repo's line gate.
// Same library (a `part of`), so the extension sees the class's private
// members (`_agent`, `_settled`, `_viewer`, …) with no visibility change.

extension AgentCliInput on AgentCli {
  /// Whether [trimmed] is chat that merely starts with a path-shaped token
  /// (`/a/b`, `~/…`, `./…`, `../…`): more text after the token means the
  /// user is talking to the agent, not invoking a command (issue #1152),
  /// and a bare token naming an existing file is an attachment paste —
  /// either takes the message route instead of the command dispatcher.
  ///
  /// The path-prefix/token shape comes from the shared
  /// [leadingPathLikeToken]; a bare single-segment `/word` is excluded —
  /// that shape is a slash command (`/model gpt` must keep dispatching),
  /// not a path.
  bool _isPathLedChat(String trimmed) {
    final token = leadingPathLikeToken(trimmed);
    if (token == null) return false;
    if (token.startsWith('/') && !token.contains('/', 1)) return false;
    if (trimmed.length > token.length) return true;
    return resolveInteractiveFileReference(trimmed) != trimmed;
  }

  /// Replays the transcript when the TUI opens on a restored session.
  Future<void> _replayRestoredSession() async {
    final resumedLabel = await _resumedSessionLabel();
    if (resumedLabel != null) {
      _replayRestoredHistory(_agent.state.messages, resumedLabel);
    }
  }

  Future<void> _handleLine(
    String line, {
    List<TuiImageAttachment> images = const [],
  }) async {
    final trimmed = line.trim();
    if (_routePendingInput(trimmed)) return;
    if (trimmed.isEmpty) return;
    // Real user input resets the inbox wake streak (the ping-pong guard).
    _inboxWakePolicy.resetStreak();
    // A tool call waiting on an approval decision owns the next input line;
    // it must not be steered into the agent as a user message.
    final pendingApproval = _pendingApprovalAnswer;
    if (pendingApproval != null && !pendingApproval.isCompleted) {
      pendingApproval.complete(trimmed);
      return;
    }
    if (isBusy) {
      // While a run streams, plain input steers the agent (pi semantics) —
      // but slash and bang commands still execute: /settings, /approval or
      // a quick !shell check must not wait out the stream (user report:
      // settings were unreachable mid-run; the line was steered as chat
      // text instead). Run-starting commands are refused by _startRun's
      // busy guard below.
      if (trimmed.startsWith('/') || trimmed.startsWith('!')) {
        // EXCEPT path-led chat: a message that begins with a path-shaped
        // token is chat with an optional attachment (issue #1152 — a
        // folder or nonexistent path plus prose is a message, never a
        // command), not a command. It used to reach the command
        // dispatcher, fall through to _startRun, and die on the busy guard
        // — silently dropped (user report: "messages that start with a
        // file go straight into the session or vanish"). Steer it with
        // the attachment marker instead.
        if (!trimmed.startsWith('!') && _isPathLedChat(trimmed)) {
          _steerResolved(trimmed, images: images);
          return;
        }
        await _dispatchInput(line, trimmed, images);
        return;
      }
      _steerResolved(trimmed, images: images);
      return;
    }
    await _settled;
    await _dispatchInput(line, trimmed, images);
  }

  /// Routes input owned by a pending prompt (ask question, guided provider
  /// flow, or a prompted slash command like `/key set NAME` — including
  /// empty lines, which buffer or complete the pending answer). Returns
  /// whether the line was consumed.
  bool _routePendingInput(String trimmed) {
    final pendingAsk = _pendingAskAnswer;
    if (pendingAsk != null && !pendingAsk.isCompleted) {
      pendingAsk.complete(trimmed);
      return true;
    }
    // A pending prompt answer can come from the guided provider flow OR
    // from a prompted slash command (e.g. `/key set NAME` in line mode).
    final pendingPrompt = _pendingPromptAnswer;
    if (pendingPrompt != null && !pendingPrompt.isCompleted) {
      pendingPrompt.complete(trimmed);
      return true;
    }
    // While a guided provider flow is active but between prompts, buffer
    // the lines so the flow's next _promptLine call drains them.
    if (_providerFlowActive) {
      _promptLineBuffer.add(trimmed);
      return true;
    }
    return false;
  }

  /// Settled, non-empty input: a shell command, a skill invocation, a slash
  /// command, or a prompt for the agent.
  Future<void> _dispatchInput(
    String line,
    String trimmed,
    List<TuiImageAttachment> images,
  ) async {
    if (trimmed.startsWith('!')) {
      await _runShellCommand(trimmed.substring(1));
      return;
    }
    if (trimmed.startsWith('/skill:')) {
      await _runSkillCommand(trimmed.substring('/skill:'.length));
      return;
    }
    // Chat that merely starts with a path-shaped token (issue #1152) is
    // never a command: it skips the dispatcher entirely and falls through
    // to the shared message tail below (viewer routing, per-turn grant
    // reset, clipboard-image passthrough).
    if (trimmed.startsWith('/') && !_isPathLedChat(trimmed)) {
      await _handleCommand(trimmed, images: images);
      return;
    }
    await _sendUserMessage(line, images);
  }

  /// The shared pre-run message tail of [_dispatchInput]: viewer mode
  /// routes composer mail to the driving agent (#428 — zero local bytes),
  /// a new user message ends the previous turn's per-turn skill tool
  /// grants, then the run starts with any clipboard images riding along.
  /// The path-guard's multi-word fallback arm reuses it so every message
  /// path gets the same bookkeeping (issue #1152 round-1).
  Future<void> _sendUserMessage(
    String text,
    List<TuiImageAttachment> images,
  ) async {
    if (_viewer != null) {
      await _viewerSend(text);
      return;
    }
    _approval.clearTurnGrants();
    _startRun(text, images: images);
  }

  void _startRun(String text, {List<TuiImageAttachment> images = const []}) {
    // One streaming run at a time: a run-starting command typed mid-stream
    // (/skill:, a command alias) lands here while isBusy — refuse it with
    // a visible note instead of interleaving a second run into the same
    // session.
    if (isBusy) {
      io.writeln(
        _style.dim(
          'a run is already streaming — wait for it to settle (or Ctrl+C '
          'to stop it), then retry',
        ),
      );
      return;
    }
    // Mark the run in flight SYNCHRONOUSLY: pre-flight compaction awaits
    // before the first streamed byte, and isBusy readers (inbox watcher,
    // shell-job settle, steer-vs-start) must not start a parallel run here.
    _runStarting = true;
    // Issue #429: a new agent turn opens a fresh board bucket — jobs from
    // this turn collapse/count together and older buckets age out.
    _jobBoard.newTurn();
    // Issue #514: a fresh run starts unstalled — the previous run's stall
    // episode must never leak into the new bracket.
    _setRunStalled(false);
    // Per-run sleep prevention (#326): the default hold acquires with the
    // run going in flight — fire-and-forget, never a reason to delay the
    // turn.
    runPowerAssertionsStarted();
    // Busy bracket HERE, not in the TUI submit handler: every run trigger
    // (submit, inbox wake, shell-job settle, scheduled message) must spin,
    // and an unbracketed trigger leaves the spinner on after the run
    // settles (the "Working… forever with an idle agent" wedge). The
    // counter is reference-counted, so the submit handler's own bracket
    // nests safely.
    _tuiController?.sendBusy(true, source: 'run');
    // Path-gated skills (`paths:` frontmatter) join the prompt once the
    // agent has touched a matching file; recomposing here is idempotent.
    _applyPromptComposition();
    // A pasted file path becomes an explicit [attached file: …] reference —
    // the model is told there is a file and decides itself whether and how
    // much to read (content is never inlined: paste size is unknown).
    final resolved = resolveInteractiveFileReference(text);
    if (resolved != text) {
      io.writeln(_style.dim('[file] pasted path attached for the agent'));
    }
    final settled = _runPrompt(resolved, images: images);
    _settled = settled;
    unawaited(
      settled.whenComplete(() {
        _tuiController?.sendBusy(false, source: 'run');
        _runStarting = false;
        // Per-run sleep prevention (#326): the run has fully settled —
        // drop the assertion so an idle agent lets the machine sleep.
        unawaited(runPowerAssertionsSettled());
        _setRunStalled(false);
        // The fold badge clears at settle whatever the outcome (issue
        // #438 AC3 «until the turn settles»; #653 — error settles too).
        _autoFoldCount = 0;
        _settleLeftoverSteering();
        // Waiting-row refresh (issue #450): the busy→idle edge is where
        // the waiting row takes over from the busy row (E3/E4).
        unawaited(_waiting.push());
        if (!_exited) _writeIdlePrompt();
      }),
    );
  }
}
