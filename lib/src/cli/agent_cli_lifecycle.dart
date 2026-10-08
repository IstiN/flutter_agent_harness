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
  Future<void> _awaitHeadlessBackgroundJobs() async {
    for (var round = 0; round < 10; round++) {
      final hasActive = _taskConfig.jobManager.jobs.any(
        (job) =>
            job.status == TaskJobStatus.queued ||
            job.status == TaskJobStatus.running,
      );
      if (!hasActive) break;
      await _taskConfig.jobManager.settled;
      await _settled;
      await _afterRun();
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
    // gh-1409: publish the operative-pin source set at boot — the agent's
    // requests rebuild the pin registry from THIS list (derived state, P2).
    _agent.operativeSkills = List.of(_enabledSkills);
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
