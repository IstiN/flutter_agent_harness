part of 'agent_cli.dart';

// The run engine of [AgentCli] — one prompt turn end to end:
// redaction, [_runPrompt], the pre-flight ([_beginUserPrompt]), the
// outcome settle ([_settleAfterPrompt]: CodeMie re-auth, over-window
// continue, empty-reply nudge), run-error handling, the heartbeat /
// shell-job settle notices, and [_afterRun] finalization. The mutable
// per-run fields (_runStarting, _headlessMode, _autoFoldCount, …) stay
// class members of `agent_cli.dart` (extensions cannot declare instance
// fields). Also hosts [_keyStatusView], the key/error-line renderer the
// run-error and command paths share. Split out to keep that file under
// the repo's line gate. Same library (a `part of`), so the extension
// sees the class's private members with no visibility change.

extension AgentCliRun on AgentCli {
  /// Key-status and error-line rendering over the live config values; built
  /// per render so `/provider` switches and the active-entry marker stay
  /// current.
  KeyStatusRenderer get _keyStatusView => KeyStatusRenderer(
    rolesDriven: _rolesDriven,
    providerKind: _providerKind,
    explicitToken: _explicitToken,
    activeCustomName: _activeCustomName,
    red: tuiError,
    secureKeys: config.secureKeys,
    customProviders: config.customProviders,
    envVarIsSet: config.envVarIsSet,
    envVarValue: config.envVarValue,
  );

  /// Ctrl+C (issue #1085 M3): stop the streaming run AND any in-flight
  /// compaction. During pre-flight / post-run compaction `_activeRun` is
  /// null (and during relief the run token alone would not reach the
  /// summarizer), so the user-wired compaction token carries the abort.
  void _abortRunOrCompaction() {
    _runAbortRequested = true;
    _activeCompactionAbort?.cancel('interrupted by user');
    _agent.abort();
  }

  /// Runs one prompt turn: pre-flight ([_beginUserPrompt]) → the agent
  /// stream → outcome settle ([_settleAfterPrompt], `true` = turn finished
  /// normally) → finalize ([_afterRun]); thrown errors land in
  /// [_handleRunError]. Auto-continuations recurse with [isAutoContinue]
  /// set, which skips the pre-flight phases.
  /// Masks secrets in user prompt text before it reaches the agent (and
  /// therefore the session JSONL) — issue #24 AC8. No-op without a
  /// pipeline (hosts without the redact wiring).
  String _redactUserText(String text) {
    final pipeline = config.redactionPipeline;
    if (pipeline == null) return text;
    return redactPrompt(pipeline, text);
  }

  Future<void> _runPrompt(
    String text, {
    bool isAutoContinue = false,
    List<TuiImageAttachment> images = const [],
  }) async {
    await _beginUserPrompt(isAutoContinue: isAutoContinue);
    try {
      if (images.isEmpty) {
        await _agent.prompt(_redactUserText(text));
      } else {
        // Clipboard chips (issue #276): the images ride the user message
        // as ImageContent blocks next to the text — same shape as --attach.
        await _agent.promptMessage(
          UserMessage(
            content: [
              TextContent(text: _redactUserText(text)),
              for (final image in images)
                ImageContent(
                  data: base64Encode(image.bytes),
                  mimeType: image.mimeType,
                ),
            ],
            timestamp: DateTime.now(),
          ),
        );
      }
      final lastMessage = _agent.state.messages.lastOrNull;
      final finished = await _settleAfterPrompt(
        lastMessage,
        isAutoContinue: isAutoContinue,
      );
      if (finished) await _afterRun();
    } catch (error) {
      await _handleRunError(error);
    }
  }

  /// [_runPrompt] pre-flight, real user prompts only: fresh over-window
  /// resume budget (see [_overWindowAutoResumed]) plus pre-flight
  /// compaction of an already-over-window transcript.
  Future<void> _beginUserPrompt({required bool isAutoContinue}) async {
    // Wall-clock catch-up (issue #259): records that came due while the
    // host slept (or while no tick ran) are delivered HERE, at turn start —
    // awaited before the prompt so this turn's first steering poll already
    // sees the fired reminder, instead of waiting for the next timer tick.
    try {
      if (await _scheduledMessages.deliverDue() > 0) {
        unawaited(_pushScheduledStatus());
      }
    } on Object {
      // Best-effort: a broken sweep must never block a turn.
    }
    if (isAutoContinue) return;
    _overWindowAutoResumed = false;
    // A fresh user text clears the over-window badge: the new run starts
    // clean, and only THIS run's folds may badge it (issue #438 E1).
    _autoFoldCount = 0;
    // One empty-reply nudge per logical turn (issue #1085 M2b).
    _emptyReplyNudgesLeft = 1;
    // The stuck-call nudge budget refills per turn (issue #1185 E2).
    _waiting.resetToolNudges();
    // The user's explicit stop ends with the turn that was stopped
    // (issue #1085 round-1): a fresh prompt re-arms the funnel's abort
    // gate.
    _runAbortRequested = false;
    // Pre-flight context guard: when the LIVE context already exceeds the
    // compaction threshold, compact BEFORE sending the request — a failed
    // post-run compaction (quota-limited smol role, provider outage) used to
    // leave every request carrying an over-window payload (ctx 240% gauge).
    await _maybeAutoCompact();
  }

  /// Settles a finished agent stream: error-stop handling and the
  /// auto-continuations. Returns `true` when the turn completed and the
  /// caller should finalize with [_afterRun].
  Future<bool> _settleAfterPrompt(
    Message? lastMessage, {
    required bool isAutoContinue,
  }) async {
    if (lastMessage is AssistantMessage &&
        lastMessage.stopReason == StopReason.error) {
      if (await _maybeHandleCodeMieError(lastMessage.errorMessage ?? '')) {
        return false;
      }
      // The loop's over-window guard refused to send: compact and continue.
      if (await _maybeOverWindowContinue(
        lastMessage,
        isAutoContinue: isAutoContinue,
      )) {
        return false;
      }
    }

    // An assistant turn that produced nothing actionable (no text, no tool
    // calls) reads as a hang; nudge the model once with "continue".
    if (_shouldContinueAfterEmptyReply(lastMessage)) {
      _emptyReplyNudgesLeft--;
      await _runPrompt('continue', isAutoContinue: true);
      return false;
    }
    return true;
  }

  /// Handles a CodeMie auth-session expiry if [message] matches one. Returns
  /// `true` when the expiry was handled and the turn is finished.
  Future<bool> _maybeHandleCodeMieError(String message) async {
    // Headless: the browser SSO re-auth awaits a human that is not there —
    // surface the error instead and let the exit code carry the failure.
    if (_headlessMode) return false;
    if (authExpiredProvider(message) != 'codemie') return false;
    await _handleCodeMieAuthExpired(message);
    return true;
  }

  /// Handles provider/runtime errors thrown outside the assistant stream.
  Future<void> _handleRunError(Object error) async {
    final message = '$error';
    if (await _maybeHandleCodeMieError(message)) return;
    io.writeln(_keyStatusView.errorLine(message, _agent.state.model.baseUrl));
  }

  /// Whether the assistant message produced nothing actionable: no non-empty
  /// text content and no tool calls.
  bool _assistantMessageIsEmpty(AssistantMessage message) {
    final hasText = message.content.any(
      (c) => c is TextContent && c.text.trim().isNotEmpty,
    );
    final hasToolCalls = message.content.any((c) => c is ToolCall);
    return !hasText && !hasToolCalls;
  }

  /// Shared handler for a detected CodeMie auth-session expiry: strips the
  /// machine marker, prints a short error, launches the browser SSO flow, and
  /// tells the user to repeat the message.
  Future<void> _handleCodeMieAuthExpired(String rawMessage) async {
    final stripped = stripAuthExpiredMarker(compactProviderError(rawMessage));
    io.writeln(tuiError('error: $stripped'));
    io.writeln(
      tuiWarning(
        'CodeMie session expired — opening browser to re-authorize...',
      ),
    );
    final orgUrl = codeMieOrgUrl(_agent.state.model.baseUrl);
    await _handleCodeMieSsoCommand(orgUrl);
    if (!_exited) {
      io.writeln(tuiSuccess('Re-authorized. Repeat your message to continue.'));
    }
  }

  /// Delivers a background-subagent heartbeat digest (issue #383) through
  /// the SAME channel as completion notices: busy → the steering queue
  /// (delivered at the next step boundary, the turn is never aborted);
  /// idle → a fresh run (the parent wakes). Text-only — the digest never
  /// spawns or cancels anything.
  void _deliverHeartbeatDigest(String digest) {
    if (_exited) return;
    if (isBusy) {
      _agent.steer(UserMessage.text(digest));
    } else {
      _startRun(digest);
    }
  }

  /// Called at most once per session when a background-job log with the old
  /// pre-unique-id name (`sh-<n>.log`) is written after this process booted
  /// (see [ShellJobRegistry.onStaleJobLog]): another fa on an OLDER build is
  /// running in this directory and can interleave output into shared files.
  /// Surfaced loudly — this exact skew silently poisoned tool output for a
  /// whole day before anyone found it.
  void _onStaleJobLog(String path) {
    final name = path.split('/').last;
    io.writeln(
      tuiWarning(
        'warning: $name was just written by an older fa build also running '
        'in this directory — its output can interleave with stale job logs. '
        'Restart that fa instance on this binary to fix.',
      ),
    );
    _logDiagnostic('stale old-format job log detected: $path');
  }

  /// Low-disk guard fired at most once per background job (issue #919):
  /// its log writes stopped (free space under the safety threshold), the
  /// job itself keeps running with degraded capture.
  void _onJobLogWarning(String message) {
    io.writeln(tuiWarning('warning: $message'));
    _logDiagnostic('job log guard: $message');
  }

  Future<void> _afterRun() async {
    // A TTSR abort/inject/retry chain may still be in flight when the
    // aborted run settles; persist only once the whole chain completed.
    await _ttsr?.settled;
    _hubCompletePanels();
    await _persistMessages();
    try {
      await _maybeAutoCompact();
    } on CancelledException {
      // Abort during the POST-RUN compaction window (issue #1085 round-4
      // review): the turn has already settled and reported its outcome —
      // rethrowing here would re-enter error handling and print a
      // spurious `error: CancelledException` line over a finished turn.
      // The dim note is the receipt; the next prompt starts clean.
      io.writeln(_style.dim('compaction interrupted'));
    }
  }
}
