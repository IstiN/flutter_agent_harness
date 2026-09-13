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
    final usage = _usage.total;
    _hubProjection.upsert(
      HubAgent(
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
      ),
    );
    for (final handle in _subagentManager.handles) {
      _hubProjection.upsert(_hubSubagentAgent(handle, now: now));
    }
    // Stale-agent eviction: a terminal agent idle >1h leaves the tree.
    _hubProjection.evictStale();
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
  /// fallback) or the hub is closed.
  void _pushHubTree() {
    final controller = _tuiController;
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
    );
  }

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

  /// Overlay key actions routed back from the TUI (`FaTuiCallbacks
  /// .onHubAction`): drill into a transcript, come back, or close.
  Future<void> _onHubAction(String action, String? key) async {
    switch (action) {
      case 'enter':
        if (key == null || key.isEmpty) return;
        await _pushHubTranscript(key);
      case 'back':
        _armHubFollow(null, running: false);
        _hubTranscriptId = null;
        _pushHubTree();
      case 'close':
        _armHubFollow(null, running: false);
        _hubTranscriptId = null;
    }
  }

  /// Pushes [id]'s transcript (main = the session ledger, a child = its
  /// JSONL) into the overlay, and arms the live-follow re-push timer while
  /// the subject is running.
  Future<void> _pushHubTranscript(String id) async {
    final width = _tuiController?.termWidth ?? 80;
    List<String> lines;
    var running = false;
    if (id == 'main') {
      final records = await _session?.getEntries() ?? const [];
      running = isBusy;
      lines = records.isEmpty
          ? ['(no transcript yet)']
          : trajectoryLines(trajectorySnapshotOf(records), width: width);
    } else {
      final handle = _subagentManager[id];
      final sessionId = handle?.sessionId;
      if (handle == null || sessionId == null || sessionId.isEmpty) {
        lines = ['(no transcript for "$id")'];
      } else {
        final session = await _openChildSession(sessionId);
        final records = await session?.getEntries() ?? const [];
        running =
            handle.status == SubagentStatus.running ||
            handle.status == SubagentStatus.queued;
        lines = records.isEmpty
            ? ['(no records yet — the child appends as it runs)']
            : trajectoryLines(trajectorySnapshotOf(records), width: width);
      }
    }
    final controller = _tuiController;
    if (controller == null) return;
    _hubTranscriptId = id;
    controller.pushHub(
      FaHubState.transcript(agentId: id, lines: lines, running: running),
    );
    _armHubFollow(id, running: running);
  }

  /// The live-follow ticker: re-reads the open transcript every
  /// [_hubFollowInterval] while its subject runs; a null [id] cancels it.
  void _armHubFollow(String? id, {required bool running}) {
    _hubFollowTimer?.cancel();
    _hubFollowTimer = null;
    if (id == null || !running) return;
    _hubFollowTimer = Timer.periodic(_hubFollowInterval, (_) {
      final current = _hubTranscriptId;
      if (current == null) {
        _hubFollowTimer?.cancel();
        _hubFollowTimer = null;
        return;
      }
      unawaited(_pushHubTranscript(current));
    });
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
        _pushHubTree();
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

  /// A background shell job started (`bash` background): its block opens
  /// with the command line.
  void _onShellJobStarted(ShellJobEntry job) {
    _renderTaskBlock(
      TaskBlock(
        kind: 'bash',
        id: job.id,
        state: TaskBlockState.running,
        label: job.command,
      ),
    );
  }

  /// A background shell job settled: the block closes (log path + exit).
  void _onShellJobSettledBlock(ShellJobEntry job) {
    final exit = job.exitCode;
    _renderTaskBlock(
      TaskBlock(
        kind: 'bash',
        id: job.id,
        state: job.isRunning
            ? TaskBlockState.running
            : (exit == 0 ? TaskBlockState.done : TaskBlockState.failed),
        label: job.command,
        detail: exit == null ? job.logPath : '${job.logPath} · exit $exit',
      ),
    );
  }

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
