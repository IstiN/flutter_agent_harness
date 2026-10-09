/// The auto-compaction UI hooks — split out of `agent_cli.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// class sees the AgentCli's private members (`_logDiagnostic`).
part of 'agent_cli.dart';

/// [AutoCompactorHooks] impl that drives the CLI TUI / stderr and the
/// diagnostic log file (`~/.fah/logs/fa.log`). One per run; cheap to
/// allocate.
/// The memory LLM slot resolution — an extension so agent_cli.dart stays
/// under the repo's 2800-line size gate.
/// The effective context window of the live model under the owner cap
/// (`agent.contextWindowCap`, issue #273): the compaction thresholds, the
/// ctx meter/footer, and the loop's over-window guard all key off this
/// basis — one clamp point ([effectiveContextWindow]), not one per
/// consumer. Lives in this part file so agent_cli.dart stays under the
/// 2800-line size gate.
///
/// Resolved through the shared host wiring (gh-1077): identical output to
/// the bare `effectiveContextWindow` call (no overhead, smol irrelevant
/// to the window), but the parity test compares THIS path against the
/// app's, so the semantics stay pinned in one place.
extension EffectiveContextWindow on AgentCli {
  int get _effectiveContextWindow => resolveCompactionHostWiring(
    mainModel: _agent.state.model,
    contextWindowCap: config.contextWindowCap,
  ).window;
}

extension MemoryLlmSlotResolution on AgentCli {
  /// Resolves the LLM slot for long-term-memory work PER CALL: the `memory`
  /// role, else `smol`, else the main model. The roles resolver is mutable
  /// (`/settings` pins chains mid-session), so caching would go stale.
  HarnessLlmSlot? _resolveMemoryLlmSlot() {
    final resolver = config.modelRolesResolver;
    final role =
        resolver?.resolveRole(memoryModelRole) ??
        resolver?.resolveRole(smolModelRole);
    if (role != null) return role;
    return (model: _agent.state.model, stream: _streamFunction);
  }
}

class _AutoCompactorCliHooks implements AutoCompactorHooks {
  _AutoCompactorCliHooks(this.cli, {required this.auto});

  final AgentCli cli;

  /// Whether this run is the auto-trigger (vs the manual `/compact`): the
  /// report header names what happened — a manual compact must not read
  /// as "auto-compacted".
  final bool auto;

  /// Whether [onPass] rendered a real report block this run — the
  /// manual-compact no-op note must not fire over a printed report.
  bool reportedPass = false;

  DateTime? _lastDeltaPhase;
  String _compactionTail = '';

  /// Whether [onDelta] streamed dimmed summary bytes on the log face
  /// (gh-1433 E4): the next compaction-facing line closes the stream
  /// line first, so the report never glues onto the live summary.
  bool _deltaStreamed = false;

  /// Closes the E4 live-summary stream line (one newline on the primary
  /// channel) before the next compaction-facing output lands.
  void _closeDeltaStreamLine() {
    if (!_deltaStreamed) return;
    _deltaStreamed = false;
    cli.io.write('\n');
  }

  @override
  void onDelta(String delta) {
    // gh-1433 E4: the log face renders the summarizer's deltas live,
    // dimmed, through the SAME redaction seam as every other rendered
    // token — a compaction turn is a provider request, and the log must
    // have no silent windows. The other faces keep the busy-row tail.
    if (cli._logIsUi) {
      cli.io.write(cli._style.dim(cli._redactRendered(delta)));
      _deltaStreamed = true;
      return;
    }
    // Live tail of the summary being written, shown in the busy row so
    // compaction reads as work, not a hang. Throttled — deltas are hot.
    final merged = (_compactionTail + delta).replaceAll('\n', ' ');
    _compactionTail = _rollingTail(merged);
    final now = DateTime.now();
    final last = _lastDeltaPhase;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastDeltaPhase = now;
    cli._pushBusyPhase('Compacting context… $_compactionTail');
  }

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {
    _closeDeltaStreamLine();
    // A slow/dead summarizer endpoint must read as a bounded wait, not a
    // silent hang: name the endpoint being tried and its time cap.
    cli._tuiController?.setBusyPhase(
      'Compacting context… $label (attempt $attempt, '
      '${budget.inSeconds}s cap)',
    );
    _compactionTail = '';
    _lastDeltaPhase = null;
  }

  /// The last 60 chars of the merged tail (newlines flattened) — a helper
  /// so [onDelta] stays at the repo's CC gate.
  static String _rollingTail(String merged) =>
      merged.length > 60 ? merged.substring(merged.length - 60) : merged;

  @override
  void onPass(AutoCompactorPass pass) {
    _closeDeltaStreamLine();
    _runTokensBefore ??= pass.tokensBefore;
    if (!pass.ok) {
      // The pass failed: onBothRolesFailed already prints the user-facing
      // hint. Printing the success-looking "auto-compacted" line here
      // claimed context was summarized when nothing was.
      cli._logDiagnostic(
        'auto-compact pass ${pass.pass} FAILED '
        'tokens ${pass.tokensBefore}→${pass.tokensAfter} '
        'error=${pass.error ?? '-'}',
      );
      return;
    }
    if (pass.fallback == 'local-trim') {
      // Mechanical in-memory trim (summarizer down): honest wording, no
      // "summarized" claim.
      cli.io.writeln(
        '[context trimmed] ${pass.tokensBefore} → ${pass.tokensAfter} '
        'tokens (summarizer unavailable — kept the most recent messages '
        'locally; the session file keeps the full history)',
      );
      cli._logDiagnostic(
        'auto-compact pass ${pass.pass} local-trim '
        'tokens ${pass.tokensBefore}→${pass.tokensAfter}',
      );
      return;
    }
    if (pass.tokensAfter == pass.tokensBefore &&
        pass.hiddenRecords == 0 &&
        pass.summarizedMessages == 0) {
      // No-op pass (already compacted at the leaf): nothing changed —
      // stay quiet instead of printing a fake "N tokens summarized".
      // Honest zeros print only when nothing happened; a pass that hid
      // or summarized records prints even on a flat token estimate
      // (issue #438 E3).
      cli._logDiagnostic('auto-compact pass ${pass.pass} no-op');
      return;
    }
    cli._printCompactionReport(pass, auto: auto);
    reportedPass = true;
    // The over-window badge: a real fold freed (or reshaped) the window
    // mid-run — the run is alive and continuing (issue #438 AC3). The
    // badge rides the busy row (the surface that repaints mid-run) until
    // the turn settles.
    if (auto) {
      cli._autoFoldCount++;
      cli._pushBusyPhase('Compacting context…');
    }
    cli._logDiagnostic(
      'auto-compact pass ${pass.pass} '
      'fallback=${pass.fallback ?? '-'} '
      'tokens ${pass.tokensBefore}→${pass.tokensAfter} '
      'ok=${pass.ok} error=${pass.error ?? '-'}',
    );
  }

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
    _closeDeltaStreamLine();
    cli.io.writeln(
      'compaction transient error (attempt $attempt/$maxAttempts); '
      'retrying in ${backoff.inSeconds}s — $error',
    );
    cli._logDiagnostic(
      'compact retry attempt=$attempt backoff=${backoff.inSeconds}s '
      'error=$error',
    );
  }

  /// The run's first pass's before-count — set by [onPass], read by
  /// [onDone] to compute the freed delta for the HEP end frame.
  int? _runTokensBefore;

  @override
  void onDone(int passes, int tokens) {
    if (passes > 0) {
      cli._logDiagnostic('auto-compact done passes=$passes tokens=$tokens');
    }
    // Backend agent mode (issue #155): close the compaction bracket once
    // per run with the net freed delta (clamped — a restamped estimator
    // can report a slightly larger after-count than the usage-anchored
    // before-count).
    final before = _runTokensBefore;
    if (before != null) {
      final freed = before - tokens;
      cli._hep?.compactionEnd(freed < 0 ? 0 : freed);
      _runTokensBefore = null;
    }
  }

  /// Returns a user-facing hint for a compaction failure, pointing at the
  /// `smol` role config when the summarization model hit a provider limit.
  /// Moved here from agent_cli.dart (2800-line gate) — used only by the
  /// hooks' failure reporting.
  String _compactionFailureHint(Object error) {
    final text = error.toString();
    if (text.contains('usage limit') ||
        text.contains('access_terminated_error') ||
        text.contains('rate limit') ||
        text.contains('429')) {
      return '$error\n\n'
          'Compaction uses the `smol` role model (see `roles.smol` in '
          '~/.fah/config.yaml). The current smol model/provider returned '
          'the error above. Switch it to a model/key with available quota, '
          'e.g. via `/settings` → Agent models, or edit ~/.fah/config.yaml.';
    }
    return text;
  }

  @override
  void onBothRolesFailed(Object lastError) {
    final hint = _compactionFailureHint(lastError);
    cli.io.writeln('compaction both roles failed: $hint');
    cli.io.writeln(
      'compaction both roles failed; the agent cannot make progress '
      'until you switch models (e.g. `/model`) or start a new session '
      '(`/new`).',
    );
  }
}

/// The busy-row phase push (issue #653): a plain passthrough. The busy
/// row names the CURRENT activity — `Compacting context…` while the fold
/// runs, then the post-fold handback (`''`) clears the marker the moment
/// the compaction finishes, and later tool/stream labels stay marker-free.
/// The «[auto-compacted · continuing]» badge used to be appended to every
/// label here, so after any fold the row led with the stale marker for
/// the rest of the run (owner screenshot: `[auto-compacted ×7 · c…` over
/// active tool work). The badge lives on the status row only
/// (`_statusLine`, until the turn settles — issue #438 AC3).
extension AgentCliBusyPhase on AgentCli {
  /// Pushes a phase label onto the TUI busy row.
  void _pushBusyPhase(String phase) {
    busyPhasesForTest.add(phase);
    _tuiController?.setBusyPhase(phase);
  }
}

/// Auto/manual compaction run methods (moved from agent_cli.dart under the
/// repo's 2800-line size gate). Same library, so private state is in scope.

/// Formats the in-chat compaction report block (issue #276): tokens
/// before → after, freed count/percent, WHICH ENGINE did the summarizing
/// (the `smol`/`main` role — review major 3: a report that doesn't name
/// the engine can't be judged), how many records were hidden vs
/// summarized, and — when the pass actually wrote summary text — the
/// summary in a fenced block so the user can eyeball — and copy — what
/// the transcript was condensed to. A pass with no summary text (all
/// evictions went to hide, or the model returned blank — issue #578)
/// omits the block: an empty ```-fence says nothing and reads as a bug.
/// Pure; [_AgentCliCompactionReportPrinter.print] renders it.
List<String> formatCompactionReport(
  AutoCompactorPass pass, {
  required bool auto,
}) {
  final freedRaw = pass.tokensBefore - pass.tokensAfter;
  // A restamped estimator can report a slightly larger after-count (same
  // clamp as onDone's HEP end frame): "-30 freed" reads as a bug.
  final freed = freedRaw < 0 ? 0 : freedRaw;
  final pct = pass.tokensBefore == 0
      ? 0
      : (freed * 100 / pass.tokensBefore).round();
  final engine = pass.fallback == null ? '' : ' · ${pass.fallback}';
  final passSuffix = pass.pass == 1 ? '' : ' · pass ${pass.pass}';
  final summary = pass.summary?.trim();
  return [
    '${auto ? 'auto-compacted' : 'compacted'}$engine$passSuffix',
    'tokens: ${pass.tokensBefore} → ${pass.tokensAfter} '
        '($freed freed · $pct%)',
    // Issue #673 AC3: the local-trim valve frees tokens WITHOUT hiding
    // session records or folding a summary — a bare "0 hidden · 0
    // summarized" next to a big freed count cannot describe a real
    // compaction. Name the in-memory drop so the line is truthful for
    // BOTH engines.
    if (pass.droppedMessages > 0)
      'records: ${pass.droppedMessages} dropped (in-memory) · '
          '${pass.hiddenRecords} hidden · '
          '${pass.summarizedMessages} summarized'
    else
      'records: ${pass.hiddenRecords} hidden · '
          '${pass.summarizedMessages} summarized',
    if (summary != null && summary.isNotEmpty) ...[
      'summary:',
      '```',
      summary,
      '```',
    ],
  ];
}

/// Renders [formatCompactionReport] through the styled transcript writer
/// so both line mode and the TUI see the same block.
extension _AgentCliCompactionReportPrinter on AgentCli {
  void _printCompactionReport(AutoCompactorPass pass, {required bool auto}) {
    final lines = formatCompactionReport(pass, auto: auto);
    final header = lines.first;
    final body = lines.sublist(1);
    io.writeln(_style.teal('● $header'));
    for (final line in body) {
      io.writeln(line == '```' ? _style.dim(line) : line);
    }
  }
}

extension AgentCliCompactionRun on AgentCli {
  /// Runs the auto-compaction when the live transcript crosses the
  /// threshold. Returns whether a compaction pass actually ran and
  /// succeeded — the over-window guard's auto-continuation keys off this
  /// to resume only when the window was really freed.
  Future<bool> _maybeAutoCompact() async {
    final session = _session;
    if (session == null) return false;
    if (_agent.state.messages.isEmpty) return false;
    // An aborted turn gets no fresh compaction pass (issue #1085 round-2
    // review): the sticky abort flag used to belt-throw CancelledException
    // out of the post-run compaction and print a spurious `error:` line
    // after the abort was already reported. The over-window guard simply
    // re-fires on the next turn if the transcript is still too big.
    if (_runAbortRequested) return false;
    // The same request-size basis as the loop's over-window guard and the
    // status-line meter (transcript + system-prompt/tool-schema overhead
    // when unanchored) — the threshold must trip on what the next request
    // actually carries.
    final tokens = _liveRequestTokens();
    if (!shouldCompact(
      tokens,
      _effectiveContextWindow,
      _effectiveCompactionSettings,
    )) {
      return false;
    }
    _pushBusyPhase('Compacting context…');
    _logDiagnostic('auto-compact start sid=$_logSid tokens=$tokens');
    try {
      await _runAutoCompact('[auto-compacted]');
    } finally {
      // Hand the busy row back to the run even when the compaction throws
      // or is cancelled (issue #1085): a stale 'Compacting context…'
      // over the streamed turn reads as a compaction hang.
      _pushBusyPhase('');
    }
    // [_runAutoCompact] reports '[auto-compacted]' only on success; treat
    // the transcript size as the source of truth for the caller.
    // Issue #1085 M2a: continuation success = the transcript FITS THE
    // WINDOW now, not "any reduction". A reduce-but-still-over pass used
    // to read as success, the guard re-fired on the retried turn, and the
    // one-shot resume budget was burned on a transcript that still could
    // not be sent.
    final after = _liveRequestTokens();
    return after <= _effectiveContextWindow;
  }

  /// The shared request-size estimate for compaction decisions (see
  /// [estimateRequestTokens]): identical basis to the status-line meter
  /// and the loop guard.
  int _liveRequestTokens() => estimateRequestTokens(
    _agent.state.messages,
    systemPrompt: _agent.state.systemPrompt,
    tools: _agent.state.tools,
  );

  /// `/compact` manual override: same AutoCompactor pipeline as the
  /// auto-trigger, but unconditional — honours the user's explicit ask
  /// even when the threshold isn't crossed.
  Future<void> _runManualCompact() async {
    final session = _session;
    if (session == null) return;
    if (_agent.state.messages.isEmpty) {
      io.writeln('nothing to compact');
      return;
    }
    // An explicit /compact is a fresh user intent (issue #1085 round-1):
    // it overrides a stale abort marker from an earlier stopped run.
    _runAbortRequested = false;
    _pushBusyPhase('Compacting context…');
    final before = _liveRequestTokens();
    try {
      final reported = await _runAutoCompact('[compacted]');
      if (!reported && _liveRequestTokens() >= before) {
        // A no-op manual /compact (already compacted at the leaf) prints no
        // report block — say why instead of looking like a silent hang.
        // A run that DID report (or trimmed) never gets the note: its
        // receipt is already on screen, and a tiny transcript can free
        // nothing while still really compacting.
        io.writeln(
          _style.dim(
            'nothing to compact — every message is already summarized or '
            'the transcript is at its smallest',
          ),
        );
      }
    } on CancelledException {
      // Compaction-ONLY interrupt (issue #1085 round-2 review): Ctrl+C
      // during a bare /compact stops the compaction, not the session —
      // a dim receipt, no `error:` line, the REPL keeps working.
      io.writeln(_style.dim('compaction interrupted'));
    } finally {
      _pushBusyPhase('');
    }
  }

  /// Builds the per-host smol/main summarizers and runs the shared
  /// [AutoCompactor]. Used by both [_maybeAutoCompact] (gated by
  /// [shouldCompact]) and [_runManualCompact] (unconditional).
  /// Returns whether a pass reported success (a rendered report block).
  Future<bool> _runAutoCompact(String label) async {
    // The user's explicit stop wins over any compaction (issue #1085
    // round-1): the abort must not merely cancel the IN-FLIGHT pass — it
    // must not be answered with a FRESH pass either (an aborted run's
    // post-fold, a relief retry after a cancelled relief). The engines
    // report cancelled summarizers as failed passes, so the funnel cannot
    // see this off the return value; the sticky flag can.
    _throwIfUserAborted();
    // Honest attempt accounting for the funnel's exhaustion verdict
    // (issue #1085 round-1): only passes that actually started count.
    _compactionPassesStarted++;
    // Backend agent mode (issue #155): bracket the run so the supervisor
    // sees why a turn stalled. Pre-flight runs carry the upcoming turn id
    // (the following agent_start reuses it). The end frame comes from the
    // pass result in [_AutoCompactorCliHooks.onPass] — the honest numbers.
    _hep?.compactionStart();
    // User-wired compaction cancellation (issue #1085 M3): a compaction
    // can run 15-30 min (pre-flight, mid-run relief, post-run) and the
    // run's own token does not exist for two of those windows — Ctrl+C
    // used to be a no-op for the whole duration. The token is also
    // LINKED to the live run token when one exists (mid-run relief), so
    // `_agent.abort()` cancels the in-flight summarizer too. Explicit
    // aborts only: the run idle watchdog is suspended around relief and
    // never cancels through here.
    final abort = CancelTokenSource();
    _activeCompactionAbort = abort;
    final runToken = _agent.cancelToken;
    if (runToken != null) {
      unawaited(
        runToken.onCancel.then((_) => abort.cancel(runToken.cancelReason)),
      );
    }
    try {
      return await _runAutoCompactWithToken(label, abort.token);
    } finally {
      _activeCompactionAbort = null;
      // Issue #1085 round-1 (review 🚨): a cancelled compaction must
      // surface as an ABORT, not as a failed pass. Both engines convert
      // the cancelled summarizer into `ok: false` (the classic `_attempt`
      // catch-all, and the structured judge's `on Object` fallback, which
      // then fires a SECOND provider call after the abort), so the
      // funnel's `on CancelledException` could never fire off the return
      // value alone and the loop relaunched compaction the user just
      // stopped.
      abort.token.throwIfCancelled();
    }
  }

  Future<bool> _runAutoCompactWithToken(String label, CancelToken token) async {
    final smol = config.modelRolesResolver?.resolveRole(smolModelRole);
    final hooks = _AutoCompactorCliHooks(
      this,
      auto: label == '[auto-compacted]',
    );
    await AutoCompactorFactory(
      session: _session!,
      state: _agent.state,
      window: _effectiveContextWindow,
      settings: _effectiveCompactionSettings,
      sources: AutoCompactorSources(
        smolStream: smol?.stream,
        smolModel: smol?.model,
        mainStream: _streamFunction,
        mainModel: _agent.state.model,
      ),
      hooks: hooks,
      prompts: CompactionPrompts.fromOverrides(config.promptOverrides),
      // Issue #287: structured is the default fallback; an explicit
      // config choice (config.compactionEngine) or a live override from
      // the settings flow (config.liveCompactionEngine, #288) still wins.
      engine:
          config.liveCompactionEngine ??
          config.compactionEngine ??
          CompactionEngine.structured,
      // Judge budget knob (issue #541): null keeps the 300s default
      // (gh-740 M1: raised from 90s — a 262k-token checkpoint on a slow
      // provider could not be summarized within 90s, bricking sessions).
      attemptBudget: Duration(
        seconds: config.compactionJudgeBudgetSeconds ?? 300,
      ),
      // Issue #1085 M1/M3: linked cancellation — see [_runAutoCompact].
      runToken: token,
      memoryExtractionHook: (text) async {
        final tui = _tuiController;
        tui?.setBusyPhase('Extracting memory…');
        // Best-effort and BOUNDED: a wedged smol endpoint used to keep the
        // phase label up for the whole role-chain retry ladder (minutes
        // per pass — the "Extracting memory… 1025s" stall). Cancel the
        // extraction stream after the deadline, hard-cap the wait anyway,
        // and restore the compaction phase label either way. A timeout
        // skips extraction for this pass only — never the compaction.
        final source = CancelTokenSource();
        final deadline = Timer(
          AgentCli._memoryExtractionDeadline,
          source.cancel,
        );
        try {
          final hook = compactionMemoryHook(
            memory: _memory,
            stream: smol?.stream ?? _streamFunction,
            model: smol?.model ?? _agent.state.model,
            cancelToken: source.token,
          );
          if (hook != null) {
            await hook(text).timeout(AgentCli._memoryExtractionHardCap);
          }
        } on TimeoutException {
          _logDiagnostic(
            'memory extraction skipped: exceeded '
            '${AgentCli._memoryExtractionHardCap.inSeconds}s hard cap',
          );
        } finally {
          deadline.cancel();
          _pushBusyPhase('Compacting context…');
        }
      },
      force: label == '[compacted]',
    ).run();
    _persistedCount = _agent.state.messages.length;
    return hooks.reportedPass;
  }
}

/// Issue #387: emergency relief for the loop's over-window guard — an
/// extension so agent_cli.dart stays under the 2800-line size gate.
extension OverWindowGuardRelief on AgentCli {
  /// ONE synchronous compaction pass over the live transcript, run when
  /// the loop's guard is about to refuse an over-window request. Returns
  /// the relieved message list to retry with, or `null` when nothing
  /// hideable remains (or the pass failed to shrink anything) — the loop
  /// then surfaces its verbatim guard error. The loop re-measures the
  /// returned list on the same basis ([_liveRequestTokens]), so a list
  /// that is still over the window is refused there too (E1 fail-fast,
  /// never a loop).
  Future<List<Message>?> _relieveOverWindow(List<Message> overWindow) async {
    if (_session == null) return null;
    _logDiagnostic(
      'over-window relief start sid=$_logSid '
      'messages=${_agent.state.messages.length}',
    );
    final beforeTokens = estimateRequestTokens(
      overWindow,
      systemPrompt: _agent.state.systemPrompt,
      tools: _agent.state.tools,
    );
    // Issue #1085 M3: the relief path never showed the busy label — a
    // 15-30 min compaction read as a dead, silent stall. Same label as
    // the auto-compact path.
    _pushBusyPhase('Compacting context…');
    try {
      await _runAutoCompact('[auto-compacted]');
    } finally {
      _pushBusyPhase('');
    }
    final after = _agent.state.messages.toList();
    final afterTokens = _liveRequestTokens();
    if (afterTokens >= beforeTokens) {
      _logDiagnostic('over-window relief no-op sid=$_logSid');
      return null;
    }
    _logDiagnostic(
      'over-window relief done sid=$_logSid tokens=$afterTokens '
      '(was $beforeTokens, ${after.length} messages)',
    );
    // Issue #1085 M3: the relieved turn CONTINUES — say so visibly, the
    // post-compaction silence is exactly what this run must never do. A
    // reduce-but-still-over relief stays unmarked: the guard's verbatim
    // error is the honest next line there (the loop re-measures the
    // returned list on the window basis).
    if (afterTokens <= _effectiveContextWindow) {
      io.writeln(
        _style.dim('[resuming] continuing the turn on the compacted context'),
      );
    }
    return after;
  }
}

/// Over-window continuation funnel (issue #1085 M2; moved from
/// agent_cli.dart under the repo's 2800-line size gate). Same library, so
/// private state is in scope.
///
/// The bounded-retry budget: the old single shot died quietly whenever one
/// compaction pass freed less than the whole window.
const int _overWindowContinueAttempts = 2;

/// Delivered to the model when the over-window guard stopped a run and
/// the post-run compaction freed the window: names what happened and
/// how to avoid re-filling the context.
const String _overWindowContinuationNotice =
    '<system-notice>\n'
    'The previous run was stopped by the context-window guard: the '
    'outgoing request exceeded the model window and was NOT sent. The '
    'transcript was auto-compacted just now (most of it is preserved as '
    'a summary; the session file keeps the full history). Continue the '
    'interrupted task from where it stopped. Avoid re-reading whatever '
    'filled the window (huge tool outputs, whole files) — use targeted '
    'reads (offset/limit or :A-B selectors) instead.\n'
    '</system-notice>';

extension OverWindowContinuation on AgentCli {
  /// The continuation prompt for an over-window resume, naming what the
  /// compaction hid — record kinds + turn spans — and how to recover it
  /// via `compact_expand` (issue #438 AC4). Nothing hidden (classic
  /// compaction) keeps the fixed notice.
  Future<String> _overWindowContinuationPrompt() async {
    final session = _session;
    final recoverables = session == null
        ? ''
        : hiddenRecoverablesSummary(await session.getEntries());
    if (recoverables.isEmpty) return _overWindowContinuationNotice;
    return _overWindowContinuationNotice.replaceFirst(
      '</system-notice>',
      '$recoverables\n</system-notice>',
    );
  }

  /// Over-window auto-continuation: on a context-window-exhausted stop,
  /// persist, auto-compact and — when the window was actually freed —
  /// resume the interrupted task on its own (ending the run there left
  /// live agents idle mid-task, a harness hang). `true` = turn consumed.
  ///
  /// Issue #1085 M2: the old single shot died quietly. Now the compaction
  /// is retried in a bounded loop (success = the transcript FITS the
  /// window, not "any reduction") and exhaustion ends the task with a
  /// LOUD terminal error naming the exit reason — calm yellow notes are
  /// for recoverable states, not task abandonment.
  Future<bool> _maybeOverWindowContinue(
    AssistantMessage lastMessage, {
    required bool isAutoContinue,
  }) async {
    if (isAutoContinue ||
        _overWindowAutoResumed ||
        !isContextWindowExhaustedError(lastMessage.errorMessage)) {
      return false;
    }
    _overWindowAutoResumed = true;
    await _ttsr?.settled;
    await _persistMessages();
    final passesBefore = _compactionPassesStarted;
    String? lastFailure;
    for (var attempt = 1; attempt <= _overWindowContinueAttempts; attempt++) {
      // The user's explicit stop wins over any retry (issue #1085
      // round-1, review 🚨): the engines report a cancelled compaction as
      // a failed pass, so without this gate the loop would relaunch a
      // fresh compaction after Ctrl+C and even resume the stopped task.
      _throwIfUserAborted();
      try {
        if (await _maybeAutoCompact()) {
          // Abort gate between a successful funnel compaction and the
          // resumed run (issue #1085 round-2 review): the fresh prompt
          // below RESETS the sticky flag, so the belt alone cannot see
          // an abort that lands in this window.
          _throwIfUserAborted();
          io.writeln(
            tuiWarning(
              '[context overflowed — auto-compacted; continuing the turn]',
            ),
          );
          io.writeln(_style.dim('[resuming] continuing the interrupted task'));
          await _runContinuationPromptSafe();
          return true;
        }
      } on CancelledException {
        // A user abort (Ctrl+C, issue #1085) must stay an abort: no
        // retry, no loud-continue error — it propagates to
        // [_handleRunError] like any cancelled run. Reached via the
        // [_runAutoCompact] rethrow of a cancelled token; the belt above
        // covers the aborts that land between attempts.
        rethrow;
      } on Object catch (error) {
        lastFailure = '$error';
        _logDiagnostic(
          'over-window compaction attempt $attempt failed '
          'sid=$_logSid: $error',
        );
      }
    }
    _throwIfUserAborted();
    await _reportContinuationExhausted(
      _compactionPassesStarted - passesBefore,
      lastFailure,
    );
    return true;
  }

  /// The funnel's abort gate (issue #1085 round-1): an explicit user stop
  /// surfaces as [CancelledException] — no retry, no false "exhausted"
  /// verdict, no resumed task.
  void _throwIfUserAborted() {
    if (_runAbortRequested) {
      throw CancelledException('interrupted by user');
    }
  }

  /// The resumed prompt run with its failure armor: ANY failure inside the
  /// continuation machinery (the recoverables scan over the resident set,
  /// the notice build, the resumed prompt's pre-flight) surfaces as a
  /// NAMED error and leaves the session resumable — never a bare "Null
  /// check operator used on a null value" line killing the turn
  /// (issue #673 AC4).
  Future<void> _runContinuationPromptSafe() async {
    try {
      final prompt = await _overWindowContinuationPrompt();
      await _runPrompt(prompt, isAutoContinue: true);
    } on Object catch (error) {
      _logDiagnostic('over-window continuation failed sid=$_logSid: $error');
      io.writeln(tuiError('error: compaction continuation failed: $error'));
    }
  }

  /// The bounded-retry exhaustion path (issue #1085 M2c): persist the
  /// compacted transcript so nothing rides on the dead turn, then end the
  /// task with the real exit reason — never silence. The verdict names
  /// what actually happened: how many compaction passes ran (zero is
  /// possible — compaction disabled or refused), the last failure, and
  /// the honest token/window numbers.
  Future<void> _reportContinuationExhausted(
    int passesRan,
    String? lastFailure,
  ) async {
    final tokens = _liveRequestTokens();
    // Same ordering as [_afterRun]: let an in-flight TTSR abort/inject/
    // retry chain finish before the panels report completion.
    await _ttsr?.settled;
    await _persistMessages();
    // The turn is consumed with no inner run, so the normal finish path
    // ([_afterRun]) never runs — its hub-panel bookkeeping must not be
    // skipped (issue #1085 round-1), while its post-run compaction must
    // (the transcript is still over the window; another automatic pass
    // would fight the verdict just printed).
    _hubCompletePanels();
    _logDiagnostic(
      'over-window continuation exhausted sid=$_logSid '
      'passes=$passesRan tokens=$tokens '
      'window=$_effectiveContextWindow failure=$lastFailure',
    );
    final attemptsNote = passesRan == 0
        ? 'compaction did not run (disabled or nothing to summarize)'
        : '$passesRan compaction ${passesRan == 1 ? 'pass' : 'passes'} '
              'did not free it';
    final cause = lastFailure == null ? '' : ' Last failure: $lastFailure.';
    io.writeln(
      tuiError(
        'error: the transcript is still ~$tokens tokens vs a '
        '$_effectiveContextWindow-token window — $attemptsNote. '
        'The task was NOT continued.$cause Run /compact (or start a '
        'fresh session with /new), then repeat your message.',
      ),
    );
  }

  /// Whether an empty assistant reply should get the one-shot "continue"
  /// nudge: clean stop, nothing actionable, nudge budget left.
  ///
  /// Issue #1085 M2b: auto-continued runs get the nudge LIKE ANY RUN —
  /// the old `!isAutoContinue` exclusion left a degenerate continuation
  /// idle forever (silent after the compaction, again). The budget is
  /// per logical turn (reset at every real user prompt, [_beginUserPrompt];
  /// auto-continues skip that reset on purpose), so the nudged run itself
  /// cannot re-nudge: empty → nudge → empty settles instead of looping
  /// forever.
  bool _shouldContinueAfterEmptyReply(Message? lastMessage) {
    if (_emptyReplyNudgesLeft <= 0) return false;
    return lastMessage is AssistantMessage &&
        lastMessage.stopReason != StopReason.error &&
        lastMessage.stopReason != StopReason.aborted &&
        _assistantMessageIsEmpty(lastMessage);
  }
}
