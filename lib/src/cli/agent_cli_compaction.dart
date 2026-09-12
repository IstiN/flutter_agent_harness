/// The auto-compaction UI hooks — split out of `agent_cli.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// class sees the AgentCli's private members (`_logDiagnostic`).
part of 'agent_cli.dart';

/// [AutoCompactorHooks] impl that drives the CLI TUI / stderr and the
/// diagnostic log file (`~/.fah/logs/fa.log`). One per run; cheap to
/// allocate.
/// The memory LLM slot resolution — an extension so agent_cli.dart stays
/// under the repo's 2800-line size gate.
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
  _AutoCompactorCliHooks(this.cli);

  final AgentCli cli;

  DateTime? _lastDeltaPhase;
  String _compactionTail = '';

  @override
  void onDelta(String delta) {
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
    cli._tuiController?.setBusyPhase('Compacting context… $_compactionTail');
  }

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {
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
    if (pass.tokensAfter == pass.tokensBefore) {
      // No-op pass (already compacted at the leaf): nothing changed —
      // stay quiet instead of printing a fake "N tokens summarized".
      cli._logDiagnostic('auto-compact pass ${pass.pass} no-op');
      return;
    }
    cli.io.writeln(
      '[auto-compacted${pass.pass == 1 ? '' : ' pass=${pass.pass}'}] '
      '${pass.tokensBefore} tokens summarized',
    );
    cli._logDiagnostic(
      'auto-compact pass ${pass.pass} '
      'fallback=${pass.fallback ?? '-'} '
      'tokens ${pass.tokensBefore}→${pass.tokensAfter} '
      'ok=${pass.ok} error=${pass.error ?? '-'}',
    );
  }

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
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

/// Auto/manual compaction run methods (moved from agent_cli.dart under the
/// repo's 2800-line size gate). Same library, so private state is in scope.
extension AgentCliCompactionRun on AgentCli {
  /// Runs the auto-compaction when the live transcript crosses the
  /// threshold. Returns whether a compaction pass actually ran and
  /// succeeded — the over-window guard's auto-continuation keys off this
  /// to resume only when the window was really freed.
  Future<bool> _maybeAutoCompact() async {
    final session = _session;
    if (session == null) return false;
    if (_agent.state.messages.isEmpty) return false;
    final tokens = estimateContextTokens(_agent.state.messages).tokens;
    if (!shouldCompact(
      tokens,
      _agent.state.model.contextWindow,
      _effectiveCompactionSettings,
    )) {
      return false;
    }
    _tuiController?.setBusyPhase('Compacting context…');
    _logDiagnostic('auto-compact start sid=$_logSid tokens=$tokens');
    await _runAutoCompact('[auto-compacted]');
    // Hand the busy row back to the run: a stale 'Compacting context…'
    // over the streamed turn reads as a compaction hang.
    _tuiController?.setBusyPhase('');
    // [_runAutoCompact] reports '[auto-compacted]' only on success; treat
    // the transcript size as the source of truth for the caller.
    final after = estimateContextTokens(_agent.state.messages).tokens;
    return after < tokens;
  }

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
    _tuiController?.setBusyPhase('Compacting context…');
    await _runAutoCompact('[compacted]');
  }

  /// Builds the per-host smol/main summarizers and runs the shared
  /// [AutoCompactor]. Used by both [_maybeAutoCompact] (gated by
  /// [shouldCompact]) and [_runManualCompact] (unconditional).
  Future<void> _runAutoCompact(String label) async {
    // Backend agent mode (issue #155): bracket the run so the supervisor
    // sees why a turn stalled. Pre-flight runs carry the upcoming turn id
    // (the following agent_start reuses it). The end frame comes from the
    // pass result in [_AutoCompactorCliHooks.onPass] — the honest numbers.
    _hep?.compactionStart();
    final smol = config.modelRolesResolver?.resolveRole(smolModelRole);
    final ok = await AutoCompactorFactory(
      session: _session!,
      state: _agent.state,
      window: _agent.state.model.contextWindow,
      settings: _effectiveCompactionSettings,
      sources: AutoCompactorSources(
        smolStream: smol?.stream,
        smolModel: smol?.model,
        mainStream: _streamFunction,
        mainModel: _agent.state.model,
      ),
      hooks: _AutoCompactorCliHooks(this),
      prompts: CompactionPrompts.fromOverrides(config.promptOverrides),
      engine: config.compactionEngine ?? CompactionEngine.classic,
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
        final deadline = Timer(AgentCli._memoryExtractionDeadline, source.cancel);
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
          tui?.setBusyPhase('Compacting context…');
        }
      },
      force: label == '[compacted]',
    ).run();
    _persistedCount = _agent.state.messages.length;
    if (label == '[compacted]' && ok) {
      // Manual `/compact` echoes the legacy "compacted" line; the
      // auto-trigger prints its own per-pass "[auto-compacted]" line via
      // [_AutoCompactorCliHooks.onPass].
      io.writeln('$label $_persistedCount messages kept');
    }
  }
}
