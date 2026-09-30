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
  /// [onReady] fires after the boot (and its lease gate) succeeded but
  /// before the transport starts — the WS host prints its one stdout
  /// startup line there, so a parent never reads a startup line for a
  /// serve that refuses to boot. Decomposed into one-decision helpers —
  /// each stays at cyclomatic 3 or under, the CRAP ratchet floor for
  /// code CI cannot cover (the CRAP lcov excludes integration tests,
  /// and only an integration run can drive this boot).
  Future<int> runWireServe({
    required Future<void> Function(WireServeServer server) serve,
    void Function(String line)? onDiagnostic,
    void Function()? onReady,
  }) async {
    final server = _wireServeServer(onDiagnostic);
    _wireHostInteraction(server);
    final pumpSub = _wirePump(server);
    final runtime = await _wireServeBoot(pumpSub);
    if (runtime == null) {
      return 3;
    }
    onReady?.call();
    try {
      await serve(server);
    } finally {
      await _wireServeTeardown(server, pumpSub, runtime);
    }
    return 0;
  }

  /// The pure protocol server over this CLI's agent seams.
  WireServeServer _wireServeServer(void Function(String line)? onDiagnostic) =>
      WireServeServer(
        runPrompt: _runPrompt,
        steer: _steerResolved,
        abort: _abortIfBusy,
        isBusy: () => isBusy,
        onLog: onDiagnostic,
      );

  /// Host-interaction over the wire (E1): the same three surfaces the
  /// TUI wires, driven by protocol frames instead of a terminal.
  void _wireHostInteraction(WireServeServer server) {
    _approval.prompt = server.approvalPrompt;
    _toolRegistry.unregister('ask');
    _toolRegistry.register(askTool(callback: server.answerAsk));
    _toolRegistry.unregister('request_secret');
    _toolRegistry.register(requestSecretTool(callback: server.answerSecret));
    _agent.state.tools = _toolRegistry.tools;
  }

  /// Every agent event becomes a wire frame; unknown-to-v1 kinds ride
  /// the passthrough. The CLI's own listener stays attached but writes
  /// through the silent io — nothing TUI-shaped can reach the stream.
  void Function() _wirePump(WireServeServer server) =>
      _agent.subscribe((event, cancelToken) => server.handleAgentEvent(event));

  /// The boot sequence up to (and including) the ownership-lease gate:
  /// returns the live subscriptions the teardown needs, or null when a
  /// live lease blocks the serve (#428) — a wire-serve NEVER spawns a
  /// second writer, it refuses with the banner, exit 3.
  Future<_WireServeRuntime?> _wireServeBoot(void Function() pumpSub) async {
    await _cubeBootRestore();
    await _waiting.captureLostJobs();
    _session = await _initializeSession();
    final leaseBlocked = await _claimSessionLeaseHeadless();
    if (leaseBlocked != null) {
      io.writeln(viewerBannerText(leaseBlocked, stale: false));
      pumpSub();
      return null;
    }
    await _subagentManager.rehydrate();
    unawaited(AgentCliTools(this).rebuildToolAvailability());
    await acquirePowerAssertions();
    runPowerAssertionsStarted();
    await _warmModelCacheQuietly();
    await _maybeAutoCompact();
    _headlessMode = true;
    _logDiagnostic('fa wire-serve boot sid=$_logSid version=$_version');
    final interruptSub = io.interrupts.listen((_) => _abortIfBusy());
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    _hubEnsureEventSubs();
    final inboxTimer = _startInboxWatcher();
    return (
      interruptSub: interruptSub,
      taskSub: taskSub,
      inboxTimer: inboxTimer,
    );
  }

  /// Graceful: an in-flight run gets abort + a bounded settle (a wedged
  /// provider cannot hold the exit), then the normal persist — the
  /// session JSONL lands exactly as a REPL session's would. The pure
  /// server's [WireServeServer.shutdown] resolves every still-pending
  /// approval/ask/secret with its safe refusal first (review #1113 r2).
  Future<void> _wireServeTeardown(
    WireServeServer server,
    void Function() pumpSub,
    _WireServeRuntime runtime,
  ) async {
    await server.shutdown();
    _abortIfBusy();
    await _settled.timeout(const Duration(seconds: 10), onTimeout: () {});
    await _afterRun();
    pumpSub();
    await _teardownAfterRepl(
      runtime.interruptSub,
      runtime.taskSub,
      runtime.inboxTimer,
    );
  }

  /// Aborts the in-flight run, if any (bounded settle happens outside).
  void _abortIfBusy() {
    if (isBusy) {
      _abortRequested = true;
      _agent.abort();
    }
  }
}

/// The live subscriptions a wire-serve boot hands its teardown.
typedef _WireServeRuntime = ({
  StreamSubscription<dynamic> interruptSub,
  StreamSubscription<dynamic> taskSub,
  Timer inboxTimer,
});
