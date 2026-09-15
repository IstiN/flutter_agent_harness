part of 'agent_cli.dart';

// The agents-hub driver (issue #277): owns the projection, pushes overlay
// content into the TUI, subscribes to the live subagent/task events, and
// renders the background-task blocks + deferred (btw) panels into the
// transcript. Split out of `agent_cli.dart` to keep it under the repo's
// 2800-line size gate. Same library (a `part of`), so the extension sees
// the class's private fields with no visibility change.

/// The transcript live-follow re-push cadence while a subject is running.
const Duration _hubFollowInterval = Duration(milliseconds: 500);

extension AgentCliHubDriver on AgentCli {
  // ----------------------------------------------------------------------
  // Tree / overlay
  // ----------------------------------------------------------------------

  /// The live fleet snapshot upserted into [_hubProjection]: main first,
  /// then every retained subagent handle.
  void _hubUpsertFleet() {
    final now = DateTime.now();
    _hubProjection.upsert(_hubMainAgent(now));
    for (final handle in _subagentManager.handles) {
      _hubProjection.upsert(_hubSubagentAgent(handle, now: now));
    }
    // Stale-agent eviction: a terminal agent idle >1h leaves the tree.
    _hubProjection.evictStale();
  }

  /// The always-present main agent row from the live usage counters.
  HubAgent _hubMainAgent(DateTime now) {
    final usage = _usage.total;
    return HubAgent(
      id: 'main',
      name: 'main',
      agentType: 'orchestrator',
      status: isBusy ? HubStatus.running : HubStatus.waiting,
      startedAt: _hubMainStartedAt,
      lastActivity: now,
      isMain: true,
      tokens: usage.totalTokens,
      requests: _usage.turns,
      costUsd: usage.cost.total > 0 ? usage.cost.total : null,
    );
  }

  /// One [HubAgent] from a live [SubagentHandle] (metrics where reported).
  HubAgent _hubSubagentAgent(SubagentHandle handle, {required DateTime now}) {
    return HubAgent(
      id: handle.id,
      name: handle.name,
      agentType: handle.agentType,
      status: switch (handle.status) {
        SubagentStatus.queued => HubStatus.queued,
        SubagentStatus.running => HubStatus.running,
        SubagentStatus.idle => HubStatus.waiting,
        SubagentStatus.completed => HubStatus.done,
        SubagentStatus.failed => HubStatus.failed,
        SubagentStatus.aborted => HubStatus.aborted,
      },
      startedAt: DateTime.tryParse(handle.createdAt) ?? now,
      lastActivity: DateTime.tryParse(handle.lastActivity) ?? now,
      parentId: 'main',
      tokens: handle.tokens > 0 ? handle.tokens : null,
      requests: handle.requests > 0 ? handle.requests : null,
    );
  }

  /// Rebuilds and pushes the tree-mode overlay. No-op when the TUI is not
  /// attached (line mode renders the same rows via the bare `/agents`
  /// fallback) — unless [target] overrides the destination (test seam).
  /// [refreshOnly] (issue #382): event-driven refreshes pass it so a
  /// closed overlay stays closed — only a user action (`/agents`, the
  /// tree's `back`) may open the hub.
  void _pushHubTree({FaTuiController? target, bool refreshOnly = false}) {
    final controller = target ?? _tuiController;
    if (controller == null) return;
    _hubUpsertFleet();
    final rows = _hubProjection.rows();
    controller.pushHub(
      FaHubState.tree(
        rows: [
          for (final row in rows) HubLine(hubAgentRow(row), key: row.agent.id),
        ],
        footer: hubFooterLine(_hubProjection.footer()),
      ),
      refreshOnly: refreshOnly,
    );
  }

  /// Test seam: pushes the tree overlay into [controller] — the same
  /// `_pushHubTree` assembly the TUI-attached `/agents` runs — so driver
  /// tests can cover it without a PTY model loop.
  @visibleForTesting
  void pushHubTreeForTest(FaTuiController controller) =>
      _pushHubTree(target: controller);

  /// Test seam: the live fleet snapshot + aggregates the tree overlay
  /// renders from (the same upsert + rows assembly as `_pushHubTree`).
  @visibleForTesting
  (List<HubRow>, HubFooter) hubTreeForTest() {
    _hubUpsertFleet();
    final rows = _hubProjection.rows();
    return (rows, _hubProjection.footer());
  }

  /// Test seam: the transcript push for [id] (the overlay's enter target).
  @visibleForTesting
  Future<(List<String>, bool)> hubTranscriptForTest(String id) =>
      _hubTranscriptLines(id, 80);

  /// Test seam: the overlay action router (enter / back / close) the TUI
  /// routes its hub keys onto.
  @visibleForTesting
  Future<void> hubActionForTest(String action, String? key) =>
      _onHubAction(action, key);

  /// Opens the hub overlay (`/agents` bare in the TUI). Line mode keeps
  /// the Variant-B picker (no full-screen surface to render into).
  Future<void> openAgentsHubOverlay() async {
    _hubEnsureEventSubs();
    if (_tuiController == null) {
      await _agentsTreePanel();
      return;
    }
    _pushHubTree();
  }

  Future<void> _onHubAction(String action, String? key) async {
    switch (action) {
      case 'enter':
        await _hubEnterTranscript(key);
      case 'back':
        _hubCloseTranscript();
        _pushHubTree();
      case 'close':
        _hubCloseTranscript();
    }
  }

  /// `enter` on a tree row: drill into that agent's transcript.
  Future<void> _hubEnterTranscript(String? key) async {
    if (key == null || key.isEmpty) return;
    await _pushHubTranscript(key);
  }

  /// Leaves transcript mode: the live-follow timer stops first.
  void _hubCloseTranscript() {
    _armHubFollow(null, running: false);
    _hubTranscriptId = null;
  }

  /// Pushes [id]'s transcript (main = the session ledger, a child = its
  /// JSONL) into the overlay, and arms the live-follow re-push timer while
  /// the subject is running. Every caller refreshes an overlay the user
  /// already opened (enter from the tree, live-follow tick, event
  /// refresh), so the push is always refresh-only and can never force the
  /// hub open over the chat (issue #382).
  Future<void> _pushHubTranscript(String id) async {
    final controller = _tuiController;
    if (controller == null) return;
    // Claim the slot BEFORE the (async) read: a user close landing
    // mid-read nulls it and the bail below drops this push instead of
    // resurrecting the follow state over a closed overlay.
    _hubTranscriptId = id;
    final (lines, running) = await _hubTranscriptLines(
      id,
      controller.termWidth,
    );
    controller.pushHub(
      FaHubState.transcript(agentId: id, lines: lines, running: running),
      refreshOnly: true,
    );
    _armHubFollow(id, running: running);
  }

  /// The overlay content for [id]: rendered transcript lines plus the
  /// subject's live flag (main = the session ledger, a child = its JSONL).
  Future<(List<String>, bool)> _hubTranscriptLines(String id, int width) {
    if (id == 'main') {
      return _hubMainTranscriptLines(width);
    }
    return _hubChildTranscriptLines(id, width);
  }

  Future<(List<String>, bool)> _hubMainTranscriptLines(int width) async {
    final records = await _session?.getEntries() ?? const [];
    return (
      _renderedTranscript(records, width, empty: '(no transcript yet)'),
      isBusy,
    );
  }

  Future<(List<String>, bool)> _hubChildTranscriptLines(
    String id,
    int width,
  ) async {
    final handle = _subagentManager[id];
    final session = await _openChildSession(handle?.sessionId ?? '');
    final records = await session?.getEntries() ?? const [];
    return (
      _renderedTranscript(
        records,
        width,
        empty: '(no records yet — the child appends as it runs)',
      ),
      _hubChildRunning(handle),
    );
  }

  List<String> _renderedTranscript(
    List<SessionRecord> records,
    int width, {
    required String empty,
  }) {
    return records.isEmpty
        ? [empty]
        : trajectoryLines(trajectorySnapshotOf(records), width: width);
  }

  /// A child counts as live until its terminal status lands.
  bool _hubChildRunning(SubagentHandle? handle) => switch (handle?.status) {
    SubagentStatus.running || SubagentStatus.queued => true,
    _ => false,
  };

  /// The live-follow ticker: re-reads the open transcript every
  /// [_hubFollowInterval] while its subject runs; a null [id] cancels it.
  void _armHubFollow(String? id, {required bool running}) {
    _hubFollowTimer?.cancel();
    _hubFollowTimer = null;
    if (id == null || !running) return;
    _hubFollowTimer = Timer.periodic(
      _hubFollowInterval,
      (_) => _hubFollowTick(),
    );
  }

  /// One live-follow tick: re-push the open transcript, or disarm when the
  /// subject closed meanwhile.
  void _hubFollowTick() {
    final current = _hubTranscriptId;
    if (current == null) {
      _hubFollowTimer?.cancel();
      _hubFollowTimer = null;
      return;
    }
    unawaited(_pushHubTranscript(current));
  }

  /// Lazily wires the hub's event subscriptions (once per session). The
  /// subagent-events subscription refreshes the open overlay whenever a
  /// child changes; the task-starts subscription renders the start block.
  void _hubEnsureEventSubs() {
    _hubSubagentEventsSub ??= _subagentManager.events.listen((_) {
      if (_tuiController == null) return;
      final transcriptId = _hubTranscriptId;
      if (transcriptId != null) {
        unawaited(_pushHubTranscript(transcriptId));
      } else {
        // Refresh-only (issue #382): a child event may refresh an open
        // hub, never force it open over the user's chat — the model
        // drops the push while the overlay is closed.
        _pushHubTree(refreshOnly: true);
      }
    });
    _hubTaskStartsSub ??= _taskConfig.jobManager.starts.listen(
      _onTaskJobStarted,
    );
  }

  /// Cancels the hub's timer and subscriptions (REPL teardown).
  void _hubTeardown() {
    _hubFollowTimer?.cancel();
    _hubFollowTimer = null;
    unawaited(_hubSubagentEventsSub?.cancel());
    _hubSubagentEventsSub = null;
    unawaited(_hubTaskStartsSub?.cancel());
    _hubTaskStartsSub = null;
  }

  // ----------------------------------------------------------------------
  // Background-task blocks (AC4)
  // ----------------------------------------------------------------------

  /// The transcript width for block rendering: the TUI's live width, or
  /// the classic 80 columns in line mode.
  int get _hubBlockWidth => _tuiController?.termWidth ?? 80;

  /// `/task` background agent start: a distinct block opens in the
  /// transcript the moment the job registers.
  void _onTaskJobStarted(TaskJob job) {
    _renderTaskBlock(
      TaskBlock(
        kind: 'agent',
        id: job.id,
        state: TaskBlockState.running,
        label: '${job.agent} — ${job.task}',
      ),
    );
  }

  /// A `/task` job settled: the block closes with its status + elapsed.
  void _onTaskJobSettledBlock(TaskJob job) {
    final result = job.result;
    _renderTaskBlock(
      TaskBlock(
        kind: 'agent',
        id: job.id,
        state: switch (job.status) {
          TaskJobStatus.completed => TaskBlockState.done,
          TaskJobStatus.failed => TaskBlockState.failed,
          TaskJobStatus.aborted => TaskBlockState.aborted,
          TaskJobStatus.queued ||
          TaskJobStatus.running => TaskBlockState.running,
        },
        label: '${job.agent} — ${job.task}',
        elapsed: result == null ? null : result.duration.inMilliseconds / 1000,
        detail: result?.id,
      ),
    );
  }

  /// A background shell job started (`bash` background): the board
  /// registers the live card (issue #429). Line mode prints nothing here —
  /// the terminal card carries the truth at settle; TUI mode shows the
  /// live region.
  void _onShellJobStarted(ShellJobEntry job) {
    _jobBoard.start(
      TaskBlock(
        kind: 'bash',
        id: job.id,
        state: TaskBlockState.running,
        label: job.command,
      ),
    );
    _jobBoardAfterMutation();
  }

  /// A background shell job settled: truthful terminal state in place —
  /// done/failed/timed out/stopped/lost, never "running" forever.
  void _onShellJobSettledBlock(ShellJobEntry job) {
    final state = shellJobPhaseOf(
      isRunning: job.isRunning,
      exitCode: job.exitCode,
      stopReason: job.stopReason,
    );
    if (!taskBlockStateIsTerminal(state)) return;
    _jobBoard.settle(
      job.id,
      state: state,
      elapsed: DateTime.now().difference(job.startedAt).inMilliseconds / 1000,
      exitCode: job.exitCode,
      detail: shellJobCardDetail(
        id: job.id,
        cwd: job.cwd,
        logPath: job.logPath,
        state: state,
        exitCode: job.exitCode,
      ),
    );
    _jobBoardAfterMutation();
  }

  /// After every board mutation: drain terminal material into the
  /// transcript, refresh the TUI's live region, persist the records.
  void _jobBoardAfterMutation() {
    _printBoardLines(_jobBoard.takeTranscriptLines(width: _hubBlockWidth));
    _tuiController?.setJobBoard(_jobBoard.liveLines());
    unawaited(_persistJobBoard());
  }

  /// Persists the board as `shell_job_registry` custom records (issue #429
  /// AC9): a resumed session rebuilds from these and never shows "running".
  Future<void> _persistJobBoard() async {
    final session = _session;
    if (session == null) return;
    await session.appendCustomEntry(
      customType: 'shell_job_registry',
      data: _jobBoard.toRecords(),
    );
  }

  /// Rebuilds the board from the resumed session's records. Jobs that were
  /// live at restart print their lost card after the transcript replay —
  /// prominent, not silent.
  Future<void> _rehydrateJobBoard() async {
    final session = _session;
    if (session == null) return;
    final latest = ShellJobBoard.latestRecords(await session.getEntries());
    if (latest.isEmpty) return;
    _jobBoard = ShellJobBoard.rehydrated(latest);
    _printBoardLines(_jobBoard.takeTranscriptLines(width: _hubBlockWidth));
  }

  /// Prints drained board lines dim - the one place board material reaches
  /// the transcript (settle drain and rehydration alike).
  void _printBoardLines(Iterable<String> lines) {
    for (final line in lines) {
      io.writeln(_style.dim(line));
    }
  }

  /// Renders one task block's lines dim into the transcript.
  void _renderTaskBlock(TaskBlock block) {
    for (final line in taskBlockLines(block, width: _hubBlockWidth)) {
      io.writeln(_style.dim(line));
    }
  }

  /// Registers a delivered mid-run message as a deferred panel and renders
  /// the bordered block into the transcript.
  void _hubAddPanel({
    required DeferredPanelKind kind,
    required String from,
    required String body,
    String? source,
    String? replyAddress,
  }) {
    final panel = _hubPanels.add(
      kind: kind,
      from: from,
      body: body,
      source: source,
      replyAddress: replyAddress,
    );
    for (final line in deferredPanelLines(panel, width: _hubBlockWidth)) {
      io.writeln(_style.dim(line));
    }
  }

  /// One panel per drained fabric message: the mail lands as a bordered
  /// block at delivery time, then rides the run as steering like before.
  void _hubPanelsForInbox(List<SubagentMessage> queued) {
    for (final message in queued) {
      _hubAddPanel(
        kind: DeferredPanelKind.mail,
        from: message.fromId,
        body: message.text,
        replyAddress: message.fromId,
      );
    }
  }

  /// Run settled: every panel that rode this run completes (the dim state
  /// flip keeps the transcript the source of truth without a re-render).
  void _hubCompletePanels() {
    for (final id in _hubPanels.transitionRunning(
      DeferredPanelState.complete,
    )) {
      final panel = _hubPanels[id];
      if (panel == null) continue;
      io.writeln(_style.dim(deferredPanelTransitionLine(panel)));
    }
  }

  // ----------------------------------------------------------------------
  // /mail and /reply (E2)
  // ----------------------------------------------------------------------

  /// `/mail` - the deferred-panel history; `/mail <id>` - one panel in
  /// full with its reply prefill.
  Future<void> handleMailCommand(String rest) async {
    final id = rest.trim();
    if (id.isEmpty) {
      if (_hubPanels.panels.isEmpty) {
        io.writeln(
          'no deferred messages (mail/scheduled/steering panels appear '
          'here when they land mid-run)',
        );
        return;
      }
      for (final panel in _hubPanels.panels) {
        final preview = panel.body.replaceAll('\n', ' ');
        io.writeln(
          '${panel.id.padRight(7)} ${deferredPanelKindLabel(panel.kind)} '
          'from ${panel.from} · ${panel.state.name} · '
          '${preview.length > 60 ? preview.substring(0, 60) : preview}',
        );
      }
      io.writeln(
        _style.dim(
          '/mail <id> - full panel · /reply <id|address> <text> - answer',
        ),
      );
      return;
    }
    final panel = _hubPanels[id];
    if (panel == null) {
      io.writeln('no panel "$id" (bare /mail lists ids)');
      return;
    }
    for (final line in deferredPanelLines(panel, width: _hubBlockWidth)) {
      io.writeln(line);
    }
    final prefill = replyPrefillFor(panel);
    if (prefill != null) io.writeln(_style.dim(prefill));
  }

  /// `/reply <id|address> <text>` - direct-send to a panel's reply mailbox
  /// (absolute addresses go cross-instance) or to a live sibling id.
  Future<void> handleReplyCommand(String rest) async {
    final trimmed = rest.trim();
    final parts = trimmed.split(_commandWhitespace);
    if (parts.length < 2 || parts.first.isEmpty) {
      io.writeln('usage: /reply <panel-id|agent-id|mailbox-address> <text>');
      return;
    }
    final target = parts.first;
    final text = trimmed.substring(target.length).trim();
    var address = target;
    if (!target.contains('/')) {
      // A panel id resolves to its reply address; a bare sibling id to its
      // mailbox; otherwise it is treated as an absolute address as-is.
      final resolved =
          _hubPanels[target]?.replyAddress ??
          (_subagentManager[target] != null
              ? _subagentManager.mailboxOf(target)
              : target);
      address = resolved;
    }
    final fabric = _subagentManager.messaging;
    if (fabric == null) {
      io.writeln('no messaging fabric - cannot deliver the reply');
      return;
    }
    await fabric.send(
      AgentMessage(
        id: newMessageId(),
        fromId: _subagentManager.selfId,
        toId: address,
        text: text,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    io.writeln('reply queued to $address');
  }
}
