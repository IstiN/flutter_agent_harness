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
  /// the ceiling the loop gives up and the detach summary below applies;
  /// `shellJobDrainMs: 0` disables the drain entirely.
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
    final quietMs = config.headless.shellJobQuietMs;
    final deadline = _waitingClock().add(Duration(milliseconds: drainMs));
    // Per-job liveness bookkeeping: the last quiet bucket consumed
    // (steered or skipped) and the probe generation seen at that
    // consumption. Generation counters, not timestamps — the comparison
    // stays valid under a fake DateTime test clock.
    final consumedBucket = <String, int>{};
    final seenProbeGen = <String, int>{};
    var namedWaiting = false;
    for (var round = 0; round < 10; round++) {
      final subActive = _taskConfig.jobManager.jobs.any(
        (job) =>
            job.status == TaskJobStatus.queued ||
            job.status == TaskJobStatus.running,
      );
      // A suppressed job's result already landed in-turn (the inline
      // consumer reported it) — it is not a waiter (gh-1459 edge case).
      final shellActive = [
        for (final job in _shellJobs.jobs)
          if (job.isRunning && job.notifyOnSettle) job,
      ];
      final action = headlessJobDrainAction(
        hasActiveJobs: subActive || shellActive.isNotEmpty,
        now: _waitingClock(),
        deadline: deadline,
      );
      if (action != HeadlessDrainAction.drain) break;
      // The #1055-parity waiting line, once per drain: the run stays
      // alive for these and says so.
      if (!namedWaiting) {
        namedWaiting = true;
        final snap = await _waiting.snapshot();
        io.writeln('⏳ waiting: ${_waiting.describe(snap)}');
      }
      // All active settles at once — bounded by the remaining ceiling AND
      // by the next liveness threshold (ask #4), so a due steer fires on
      // cadence even while the job keeps running.
      await Future.any([
        Future.wait([
          if (subActive) _taskConfig.jobManager.settled,
          for (final job in shellActive) job.settled,
        ]),
        _waitingSleep(
          _headlessLivenessWake(shellActive, quietMs, consumedBucket, deadline),
        ),
      ]);
      // A settle notice starts its reaction run one event-loop turn later
      // (the registry's settle listener leg); pump it, then steer any due
      // liveness notices BEFORE awaiting the reaction run.
      await Future<void>.delayed(Duration.zero);
      await _steerHeadlessLiveness(
        shellActive,
        quietMs,
        consumedBucket,
        seenProbeGen,
      );
      if (isBusy) {
        await _settled;
        await _afterRun();
      }
    }
    // A settle notice that landed outside a drain round (the window
    // between the last active check and here) still starts its reaction
    // run — never return mid-run (gh-1459).
    if (isBusy) {
      await _settled;
      await _afterRun();
    }
    // Anything still live when the drain gives up was cut short by the
    // ceiling (or its 10-round cap racing the same wall budget — the
    // wake legs ride the monotonic timer clock, the deadline the wall
    // clock): say so once, then let the detach summary below name the
    // jobs — the documented degradation, never a silent hang (gh-1459).
    final stillActive =
        _taskConfig.jobManager.jobs.any(
          (job) =>
              job.status == TaskJobStatus.queued ||
              job.status == TaskJobStatus.running,
        ) ||
        _shellJobs.jobs.any((job) => job.isRunning && job.notifyOnSettle);
    if (stillActive) {
      io.writeln(
        _style.dim(
          '⏳ background-job drain ceiling ($drainMs ms) reached — '
          'detaching',
        ),
      );
    }
  }

  /// The next drain wake bound: the remaining ceiling, pulled earlier by
  /// the next liveness threshold of any active shell job (gh-1459 ask #4)
  /// so a due notice fires on cadence. Pure time arithmetic on the
  /// waiting clock — unit-tested through the drain ITs.
  Duration _headlessLivenessWake(
    List<ShellJobEntry> active,
    int quietMs,
    Map<String, int> consumedBucket,
    DateTime deadline,
  ) {
    var wake = deadline.difference(_waitingClock());
    if (quietMs <= 0 || active.isEmpty) return wake;
    final now = _waitingClock();
    for (final job in active) {
      final bucket = (consumedBucket[job.id] ?? 0) + 1;
      final due = job.startedAt.add(Duration(milliseconds: quietMs * bucket));
      final d = due.difference(now);
      if (d < wake) wake = d;
    }
    return wake;
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
    int quietMs,
    Map<String, int> consumedBucket,
    Map<String, int> seenProbeGen,
  ) async {
    if (quietMs <= 0) return;
    for (final job in active) {
      if (!job.isRunning || !job.notifyOnSettle) continue;
      final elapsed = _waitingClock().difference(job.startedAt);
      final elapsedMs = elapsed.isNegative ? 0 : elapsed.inMilliseconds;
      final action = headlessJobLivenessAction(
        elapsedMs: elapsedMs,
        quietMs: quietMs,
        lastConsumedBucket: consumedBucket[job.id] ?? 0,
        probedSinceLastConsumption:
            job.probeGeneration !=
            (seenProbeGen[job.id] ??= job.probeGeneration),
      );
      if (action == HeadlessLivenessAction.wait) continue;
      // Both a steer and a skip consume the crossing — exactly one
      // notice budget per threshold per job.
      consumedBucket[job.id] = elapsedMs ~/ quietMs;
      seenProbeGen[job.id] = job.probeGeneration;
      if (action == HeadlessLivenessAction.skip) continue;
      final tail = (await _shellJobs.tail(job.id, maxLines: 5)).trimRight();
      final message =
          '<system-notice>\n'
          'Job ${job.id} running · ${headlessLivenessElapsedText(elapsed)} '
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
