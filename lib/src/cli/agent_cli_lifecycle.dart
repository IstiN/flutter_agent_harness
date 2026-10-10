part of 'agent_cli.dart';

// Run-lifecycle helpers of [AgentCli] — the pieces of the [AgentCli.run]
// boot/teardown that are not the REPL loops themselves (those live in
// agent_cli_repl_boot.dart): live-session presence, the inbox watcher
// timer, REPL teardown, headless job draining, and the context load.
// Split out of `agent_cli.dart` to keep it under the repo's line gate.
// Same library (a `part of`), so the extension sees the class's private
// members with no visibility change.

extension AgentCliLifecycle on AgentCli {
  /// Live-session presence: this process now owns the session — the Fa
  /// app (sharing the sessions root) marks it live and can attach. The
  /// heartbeat refreshes on the inbox timer; unregistering happens in
  /// [_teardownAfterRepl] (crash coverage is the staleness window).
  Future<({SessionPresenceStore store, String sessionId})?>
  _registerLivePresence() async {
    final store = config.presenceStore;
    final sessionId = _session?.cachedId;
    if (store != null && sessionId != null && _viewer == null) {
      await store.register(sessionId, pid: config.processId);
      return (store: store, sessionId: sessionId);
    }
    return null;
  }

  /// The inbox watcher: incoming inter-agent mail while IDLE wakes the
  /// agent into a turn (mid-run mail is delivered by the steering poll).
  /// The same tick refreshes the presence heartbeat (every other tick ≈
  /// 4s, well inside the 15s staleness window).
  Timer _startInboxWatcher() {
    var heartbeatTick = 0;
    return Timer.periodic(const Duration(seconds: 2), (_) {
      // Viewer mode: follow the lease only — the owner's mail, presence,
      // and orphan reclaims are the OWNER's job, never a viewer's.
      if (_viewer != null) {
        unawaited(_viewerTick());
        return;
      }
      unawaited(_reclaimOrphanFabricMail());
      unawaited(_wakeOnInboxMail());
      // gh-970: reminders/sibling mail that fired into a FINISHED child's
      // inbox resume that child in its own session (no-op without the
      // child-resume wiring).
      unawaited(_subagentManager.wakeChildrenWithPendingMail());
      // #437: wedge watchdog for mid-run steering + the idle wake for
      // steering recovered from the previous session.
      _checkPendingSteeringHealth();
      _wakeOnRecoveredSteering();
      if (heartbeatTick++ % 2 == 0) {
        // Touches the CURRENT session's row and re-registers after a
        // /session switch (a viewer keeps no row at all).
        unawaited(_touchPresenceForCurrentSession());
        // The messaging-fabric heartbeat: agent_directory reports this
        // instance as live even when no mail is pending.
        _touchFabricHeartbeat();
      } else {
        // Our lease heartbeat (≈4s, inside the 15s window): a false
        // return means the lease was lost — demote to viewer.
        unawaited(_leaseHeartbeat());
      }
    });
  }

  /// Input ended (EOF) or the REPL is shutting down: never leave a tool
  /// call waiting on an answer that cannot arrive.
  Future<void> _teardownAfterRepl(
    StreamSubscription<dynamic> interruptSub,
    StreamSubscription<dynamic> taskSub,
    Timer inboxTimer,
  ) async {
    _cancelPendingAnswers();
    _hubTeardown();
    unawaited(_subagentBoardSub?.cancel());
    _subagentBoardSub = null;
    _subagentBoard.dispose();
    await releasePowerAssertions();
    final exitSpec = _cubeEnv.activeSpec;
    if (exitSpec != null) {
      try {
        await CubeCacheManager(_cubeEnv, exitSpec).save();
      } on Object catch (error) {
        io.writeln('cube: cache save failed: $error');
      }
    }
    await interruptSub.cancel();
    await taskSub.cancel();
    inboxTimer.cancel();
    await _settled;
    // Live-session presence off: the session stops being "running in
    // the CLI" for app viewers.
    await _extSessionEndBounded();
    if (_livePresence != null) {
      await _livePresence!.store.unregister(_livePresence!.sessionId);
      _livePresence = null;
    }
    // Lease bookkeeping: release OUR lease (graceful exit, #428); a
    // viewer never touches the owner's lease.
    await _releaseSessionLease();
    // A session nobody wrote to leaves no file behind (never a viewer's
    // call — the owner's file is not ours to delete).
    if (_viewer == null) await deleteSessionIfEmpty();
    // gh-1241: close the usage segment AFTER the empty-session cleanup —
    // a deleted session has no chain to fold and no artifact should
    // outlive it.
    await _flushUsageLedger();
  }

  /// Warm the endpoint metadata (model list, dial features, reported
  /// limits) BEFORE the first turn; failures are silent — the catalog
  /// defaults keep applying.
  Future<void> _warmModelCacheQuietly() async {
    try {
      await _refreshModelCache();
    } on Object {
      // Swallowed: see _refreshModelCache.
    }
  }

  /// Background jobs (kimi's print-mode): don't exit while agents are in
  /// flight. Settled jobs inject async-result messages through the
  /// listener (re-wake runs), so loop until every job is terminal and
  /// those reaction runs settle too (capped like kimi's drain limit).
  ///
  /// gh-1459: live background SHELL jobs (`bash background:true`) drain
  /// the same way — their settles ride the same fresh-turn notice path
  /// (`_onShellJobSettled`) — and BOTH loops share ONE wall-clock ceiling
  /// (`headless.shellJobDrainMs`, default 30 min): a job that never
  /// settles (an infinite watch-loop) cannot hang headless forever. Past
  /// the ceiling the loop gives up and the detach summary below applies.
  /// `shellJobDrainMs: 0` is the shell-job kill switch: live shell jobs
  /// detach immediately, while the pre-existing subagent drain stays
  /// unconditional.
  ///
  /// gh-1459 ask #4: while the drain waits, every
  /// `headless.shellJobQuietMs` (default 5 min) of a still-running
  /// awaited shell job steers ONE compact system-notice (elapsed + log
  /// tail + the bash_job escape hatch) into a fresh turn — the model can
  /// keep waiting, inspect, or kill instead of blocking blindly to the
  /// ceiling. A notice is skipped when the model itself probed the job
  /// (a `bash_job status/output` call bumps
  /// [ShellJobEntry.probeGeneration]) since the last consumed threshold —
  /// one steer budget per crossing, never a spam loop.
  Future<void> _awaitHeadlessBackgroundJobs() async {
    final drainMs = config.headless.shellJobDrainMs;
    // gh-1459 rework: `0` is the SHELL-job kill switch — the pre-existing
    // subagent drain stays unconditional (see `_headlessDrainAction`).
    final shellDrainDisabled = drainMs == 0;
    final deadline = _waitingClock().add(Duration(milliseconds: drainMs));
    final liveness = _HeadlessDrainLiveness(config.headless.shellJobQuietMs);
    var namedWaiting = false;
    for (var round = 0; round < 10; round++) {
      if (_headlessDrainAction(
            deadline,
            shellDrainDisabled: shellDrainDisabled,
          ) !=
          HeadlessDrainAction.drain) {
        break;
      }
      // The #1055-parity waiting line, once per drain: the run stays
      // alive for these and says so.
      if (!namedWaiting) {
        namedWaiting = true;
        await _nameHeadlessWaiting();
      }
      await _headlessDrainRound(
        deadline,
        liveness,
        shellDrainDisabled: shellDrainDisabled,
      );
    }
    // The loop can also end because the 10-round cap exhausted while the
    // wall-clock ceiling still had budget — thread the real cause into
    // the detach line instead of always blaming the ceiling.
    final roundCapEnded =
        _headlessDrainAction(
          deadline,
          shellDrainDisabled: shellDrainDisabled,
        ) ==
        HeadlessDrainAction.drain;
    await _finishHeadlessDrain(drainMs, roundCapEnded: roundCapEnded);
  }

  /// The active shell jobs of this drain round: still running and still
  /// owed a model-facing settle notice (gh-1459 — a suppressed job's
  /// result already landed in-turn; it is not a waiter).
  List<ShellJobEntry> _headlessActiveShellJobs() => [
    for (final job in _shellJobs.jobs)
      if (job.isRunning && job.notifyOnSettle) job,
  ];

  bool _headlessSubAgentsActive() => _taskConfig.jobManager.jobs.any(
    (job) =>
        job.status == TaskJobStatus.queued ||
        job.status == TaskJobStatus.running,
  );

  /// One round of the pure drain decision (gh-1459): active jobs keep
  /// draining while the ceiling has budget; nothing active exits; a
  /// spent ceiling detaches. With the shell-job kill switch (`0`) live
  /// shell jobs detach at once while in-flight subagents keep the
  /// legacy unconditional drain.
  HeadlessDrainAction _headlessDrainAction(
    DateTime deadline, {
    required bool shellDrainDisabled,
  }) => headlessJobDrainAction(
    hasActiveSubAgents: _headlessSubAgentsActive(),
    hasActiveShellJobs: _headlessActiveShellJobs().isNotEmpty,
    now: _waitingClock(),
    deadline: deadline,
    shellDrainDisabled: shellDrainDisabled,
  );

  /// The `⏳ waiting: …` line (#1055 parity), once per drain.
  Future<void> _nameHeadlessWaiting() async {
    final snap = await _waiting.snapshot();
    io.writeln('⏳ waiting: ${_waiting.describe(snap)}');
  }

  /// One drain round: wait for every active settle at once — bounded by
  /// the remaining ceiling AND by the next liveness threshold (ask #4),
  /// so a due steer fires on cadence even while the job keeps running —
  /// then steer due liveness notices BEFORE awaiting the reaction run.
  /// A settle notice starts its reaction run one event-loop turn after
  /// the wake (the registry's settle listener leg); the zero-delay pump
  /// lets it land first.
  Future<void> _headlessDrainRound(
    DateTime deadline,
    _HeadlessDrainLiveness liveness, {
    required bool shellDrainDisabled,
  }) async {
    final subActive = _headlessSubAgentsActive();
    final shellActive = _headlessActiveShellJobs();
    final waits = <Future<void>>[
      if (subActive) _taskConfig.jobManager.settled,
      for (final job in shellActive) job.settled,
    ];
    if (shellDrainDisabled && subActive) {
      // The `0` kill switch is shell-job-scoped: a subagent-only round
      // is the legacy pre-gh-1459 drain — await the settles directly,
      // with no ceiling sleep (a zero deadline would wake it at once
      // and spin the round cap).
      await Future.wait(waits);
    } else {
      await Future.any([
        Future.wait(waits),
        _waitingSleep(liveness.wakeIn(shellActive, _waitingClock(), deadline)),
      ]);
    }
    await Future<void>.delayed(Duration.zero);
    await _steerHeadlessLiveness(shellActive, liveness);
    if (isBusy) {
      await _settled;
      await _afterRun();
    }
  }

  /// The drain wrap-up (gh-1459): a settle notice that landed outside a
  /// drain round (the window between the last active check and here)
  /// still starts its reaction run — never return mid-run — and anything
  /// still live was cut short by the ceiling OR by its 10-round cap
  /// racing the same wall budget: name the actual cause once (`_finish`
  /// threads [roundCapEnded]), then let the detach summary name the jobs
  /// — the documented degradation, never a silent hang.
  Future<void> _finishHeadlessDrain(
    int drainMs, {
    required bool roundCapEnded,
  }) async {
    if (isBusy) {
      await _settled;
      await _afterRun();
    }
    if (_headlessSubAgentsActive() || _headlessActiveShellJobs().isNotEmpty) {
      io.writeln(
        _style.dim(
          '⏳ background-job drain ${headlessDrainDetachCause(drainMs: drainMs, roundCapEnded: roundCapEnded)} '
          'reached — detaching',
        ),
      );
    }
  }

  /// Steers the due interim liveness notices of the active shell jobs
  /// (gh-1459 ask #4): one compact `<system-notice>` per newly-crossed
  /// quiet threshold (`job <id> running · <elapsed> elapsed · tail: …`
  /// plus the bash_job escape hatch). A crossing the model already
  /// inspected itself (a `bash_job status/output` probe — the probe
  /// generation advanced since the last consumption) is SKIPPED but
  /// still consumed: the next steer waits for the NEXT threshold, never
  /// a per-timer retry. The notices ride the same path as the settle
  /// notice — the first starts a fresh run while idle, the rest steer
  /// into it — and the caller then awaits the reaction run.
  Future<void> _steerHeadlessLiveness(
    List<ShellJobEntry> active,
    _HeadlessDrainLiveness liveness,
  ) async {
    if (liveness.quietMs <= 0) return;
    for (final job in active) {
      if (!job.isRunning || !job.notifyOnSettle) continue;
      final elapsed = _waitingClock().difference(job.startedAt);
      final elapsedMs = elapsed.isNegative ? 0 : elapsed.inMilliseconds;
      final currentBucket = elapsedMs ~/ liveness.quietMs;
      final lastBucket = liveness.consumedBucket[job.id] ?? 0;
      if (currentBucket <= lastBucket) continue; // no new crossing
      final probed =
          job.probeGeneration !=
          (liveness.seenProbeGen[job.id] ??= job.probeGeneration);
      // The whole burst is consumed either way — exactly one steer
      // budget per threshold crossing per job, never a per-timer retry.
      liveness.consumedBucket[job.id] = currentBucket;
      liveness.seenProbeGen[job.id] = job.probeGeneration;
      // A late wake (a reaction run that outlived its windows) crosses
      // SEVERAL thresholds at once: the ticket's budget is one notice
      // PER crossing ("N crossings ⇒ exactly N notices"), so steer each
      // newly-crossed bucket separately, stamped from its OWN threshold
      // — never one collapsed steer that silently eats buckets 2..N.
      // A model probe since the last consumption suppresses the whole
      // burst instead: it was watching, not blind — the next steer
      // waits for the next uncrossed threshold.
      if (probed) continue;
      final tail = (await _shellJobs.tail(job.id, maxLines: 5)).trimRight();
      for (var bucket = lastBucket + 1; bucket <= currentBucket; bucket++) {
        final noticeElapsed = Duration(milliseconds: bucket * liveness.quietMs);
        final message =
            '<system-notice>\n'
            'Job ${job.id} running · ${headlessLivenessElapsedText(noticeElapsed)} '
            'elapsed · tail: ${tail.isEmpty ? '(no output yet)' : tail}\n'
            'Escape hatch: bash_job output ${job.id} (inspect) / '
            'bash_job stop ${job.id} (kill). Log: ${job.logPath}\n'
            '</system-notice>';
        // Same persistence/steering path as the settle notice
        // (`_onShellJobSettled`): the echo keeps resume matching live.
        _tuiController?.sendOutput('$message\n');
        if (isBusy) {
          _agent.steer(UserMessage.text(message));
        } else {
          _startRun(message);
        }
      }
    }
  }

  /// Loads prompt templates, skills, and project context files, then applies
  /// the prompt composition. Third-party (Claude/Copilot/Codex) roots are
  /// gated behind the user's consent ([AgentCliConfig.skillsAccess]); while
  /// access is not granted their presence is still detected (directory
  /// metadata only) to drive the startup consent dialog / hint.
  Future<void> _loadAgentContext() async {
    _templates = await loadPromptTemplates(_env, config.promptTemplateDirs);
    final roots = defaultSkillRoots(cwd: _env.cwd, homeDir: config.homeDir);
    _skills = await discoverSkills(
      _env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      allowedSources: _skillsAllowedSources,
      builtins: builtinSkills(),
    );
    await _resolveSkillAvailability();
    _thirdPartySkillDirsPresent = await _detectThirdPartySkillDirs();
    // Line mode / headless: this print is visible as-is. TUI: the terminal
    // is not ours yet — the alternate screen would wipe this line, so
    // `_runTuiRepl` re-prints the hint right after the banner.
    _printThirdPartySkillsDisabledHint();
    _contextFiles = await loadProjectContextFiles(
      _env,
      userFile: config.homeDir == null
          ? null
          : '${config.homeDir}/.fah/AGENTS.md',
    );
    _applyPromptComposition();
    // Durable facts from past sessions join the prompt asynchronously
    // (memory stores initialize lazily; recompose on arrival).
    unawaited(_refreshMemorySection());
  }
}

/// Per-drain liveness bookkeeping for gh-1459 ask #4: the quiet cadence
/// knob plus, per job, the last quiet bucket consumed (steered or
/// skipped) and the probe generation seen at that consumption.
/// Generation counters, not timestamps — the comparison stays valid
/// under a fake DateTime test clock.
final class _HeadlessDrainLiveness {
  _HeadlessDrainLiveness(this.quietMs);

  /// `headless.shellJobQuietMs`; `0` disables the interim steers.
  final int quietMs;
  final consumedBucket = <String, int>{};
  final seenProbeGen = <String, int>{};

  /// The next drain wake bound: [deadline] pulled earlier by the next
  /// liveness threshold of any active shell job, so a due notice fires
  /// on cadence even while the job keeps running. Pure time arithmetic
  /// on the waiting clock — unit-tested through the drain ITs.
  Duration wakeIn(List<ShellJobEntry> active, DateTime now, DateTime deadline) {
    var wake = deadline.difference(now);
    if (quietMs <= 0 || active.isEmpty) return wake;
    for (final job in active) {
      final bucket = (consumedBucket[job.id] ?? 0) + 1;
      final due = job.startedAt.add(Duration(milliseconds: quietMs * bucket));
      final d = due.difference(now);
      if (d < wake) wake = d;
    }
    return wake;
  }
}
