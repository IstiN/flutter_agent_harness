part of 'agent_cli.dart';

/// `fa wire-serve` boot (issue #1103): heads the agent stack WITHOUT any
/// REPL/TUI and hands a pure [WireServeServer] to the transport loop in
/// [serve] (NDJSON-stdio or loopback WebSocket — both live in `bin/`).
///
/// Boot mirrors [run]'s session machinery (lease, presence, subagent
/// rehydrate, job watcher) minus everything interactive; teardown mirrors
/// [_teardownAfterRepl] so the session JSONL persists exactly as a REPL
/// session would and stays resumable via `fa --session`. Host-interaction
/// surfaces (approval prompt, `ask`, `request_secret`) are re-wired onto
/// the wire protocol: the silent [CliIO] is non-interactive, so the
/// constructor's null callbacks are REPLACED here — a host that cannot
/// answer must never silently deny a critical-pattern call.
extension WireServeBoot on AgentCli {
  /// Runs the wire-serve loop until [serve] completes (stdin EOF, SIGTERM
  /// handling, or a fatal transport error — the transport decides). An
  /// in-flight run is aborted and given a bounded settle window first;
  /// the transcript persists, then normal teardown runs. Returns the
  /// process exit code (0; 3 when an ownership lease blocks the boot).
  Future<int> runWireServe({
    required Future<void> Function(WireServeServer server) serve,
    void Function(String line)? onDiagnostic,
  }) async {
    final server = WireServeServer(
      runPrompt: _runPrompt,
      steer: _steerResolved,
      abort: () {
        if (isBusy) {
          _abortRequested = true;
          _agent.abort();
        }
      },
      isBusy: () => isBusy,
      onLog: onDiagnostic,
    );
    // Host-interaction over the wire (E1): the same three surfaces the
    // TUI wires, driven by protocol frames instead of a terminal.
    _approval.prompt = server.approvalPrompt;
    _toolRegistry.unregister('ask');
    _toolRegistry.register(askTool(callback: server.answerAsk));
    _toolRegistry.unregister('request_secret');
    _toolRegistry.register(requestSecretTool(callback: server.answerSecret));
    _agent.state.tools = _toolRegistry.tools;
    // Every agent event becomes a wire frame; unknown-to-v1 kinds ride
    // the passthrough. The CLI's own listener stays attached but writes
    // through the silent io — nothing TUI-shaped can reach the stream.
    final pumpSub = _agent.subscribe(
      (event, cancelToken) => server.handleAgentEvent(event),
    );

    await _cubeBootRestore();
    await _waiting.captureLostJobs();
    _session = await _initializeSession();
    // Ownership lease (#428): a wire-serve NEVER spawns a second writer
    // over a live lease — refuse with the banner, exit 3.
    final leaseBlocked = await _claimSessionLeaseHeadless();
    if (leaseBlocked != null) {
      io.writeln(viewerBannerText(leaseBlocked, stale: false));
      pumpSub();
      return 3;
    }
    await _subagentManager.rehydrate();
    unawaited(AgentCliTools(this).rebuildToolAvailability());
    await acquirePowerAssertions();
    runPowerAssertionsStarted();
    await _warmModelCacheQuietly();
    await _maybeAutoCompact();
    _headlessMode = true;
    _logDiagnostic('fa wire-serve boot sid=$_logSid version=$_version');
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) {
        _abortRequested = true;
        _agent.abort();
      }
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    _hubEnsureEventSubs();
    final inboxTimer = _startInboxWatcher();
    try {
      await serve(server);
    } finally {
      // Graceful: an in-flight run gets abort + a bounded settle (a
      // wedged provider cannot hold the exit), then the normal persist.
      if (isBusy) {
        _abortRequested = true;
        _agent.abort();
      }
      await _settled.timeout(const Duration(seconds: 10), onTimeout: () {});
      await _afterRun();
      pumpSub();
      await _teardownAfterRepl(interruptSub, taskSub, inboxTimer);
    }
    return 0;
  }
}
