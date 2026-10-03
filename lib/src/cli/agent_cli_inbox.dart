part of 'agent_cli.dart';

// Implementation members of [AgentCli] for the agent messaging fabric and
// the idle inbox-wake loop — split out of `agent_cli.dart` to keep it under
// the repo's 2800-line size gate. Same library (a `part of`), so the
// extension sees the class's private fields (`_subagentManager`,
// `_session`, the wake-guard fields in the main file) with no visibility
// change.
/// Ceiling for one plugin-inbox drain: a wedged hub RPC must never hold
/// the run's settle hostage.
const Duration _hubDrainTimeout = Duration(seconds: 5);

extension AgentCliMessagingFlow on AgentCli {
  /// The main agent's inbox as steering messages: each pending fabric
  /// message becomes a user message attributed to its sender, so the
  /// transcript reads like a chat between agents. A `user`-kind message
  /// (an attached client — the Fa app's attach view — handing over user
  /// input) lands as the user's own words with a dim attribution prefix,
  /// not an agent chat line.
  Future<List<Message>> _mainInboxMessages() async {
    final queued = await _subagentManager.drainMessages(
      _subagentManager.selfId,
    );
    // A delivered `user`-kind message IS real user input: it resets the
    // inbox-wake streak exactly like a typed line would. Without this, an
    // attach-driven workflow (terminal open, every message sent from the
    // app) burns the 10-run agent-chat cap and the CLI goes permanently
    // silent on further app mail until restart.
    if (queued.any((message) => message.isUserInput)) {
      _inboxWakePolicy.resetStreak();
    }
    // The btw panels: each drained fabric message lands as a bordered
    // panel block at delivery time (issue #277).
    _hubPanelsForInbox(queued);
    final messages = [
      for (final message in queued)
        _steeringLine(
          message.fromId,
          message.text,
          userInput: message.isUserInput,
        ),
    ];
    // Plugin inboxes (e.g. the hub) join the same steering flow, after
    // the fabric mail. A source that throws is skipped — the steering
    // contract is that this closure never throws.
    for (final inbox in _pluginInboxes) {
      final List<AgentMessage> drained;
      try {
        // ponytail: a timed-out drain loses any batch still in flight;
        // retain-future retry only if mail loss on a wedged hub ever
        // matters more than run liveness.
        drained = await inbox.drain().timeout(
          _hubDrainTimeout,
          onTimeout: () {
            io.writeln(
              _style.dim('[mail] hub drain timeout — skipping this poll'),
            );
            return <AgentMessage>[];
          },
        );
      } on Object {
        continue;
      }
      if (drained.any((message) => message.kind == AgentMessageKind.user)) {
        _inboxWakePolicy.resetStreak();
      }
      messages.addAll([
        for (final message in drained)
          _steeringLine(
            message.fromId,
            message.text,
            userInput: message.kind == AgentMessageKind.user,
          ),
      ]);
    }
    return messages;
  }

  /// Sender-attributed steering line for one inbox message: user input
  /// (an attached client handing over the user's words) lands with an
  /// attribution prefix; agent chat reads as a chat line.
  Message _steeringLine(
    String fromId,
    String text, {
    required bool userInput,
  }) => userInput
      ? UserMessage.text('[from $fromId] ${text.trim()}')
      : UserMessage.text('from $fromId: ${text.trim()}');

  /// The steering probe: fabric mail pending, or any plugin inbox
  /// reports unread mail. Never throws — a broken plugin probe counts
  /// as empty.
  Future<bool> _mainInboxProbe() async {
    final count = await _subagentManager.pendingInboxCount(
      _subagentManager.selfId,
    );
    if (count > 0) return true;
    return _anyPluginInboxPending();
  }

  /// Non-draining check across every registered plugin inbox; a probe
  /// that throws counts as empty.
  Future<bool> _anyPluginInboxPending() async {
    for (final inbox in _pluginInboxes) {
      final hasPending = inbox.hasPending;
      if (hasPending == null) continue;
      try {
        if (await hasPending()) return true;
      } on Object {
        // Broken probe — the drain still guards itself.
      }
    }
    return false;
  }

  /// The scheduled-records root resolved LIVE from the current env cwd:
  /// `_messagesRoot` pins the launch cwd (the fabric mailboxes stay there),
  /// but session-folder adoption (`_loadSession` repoints `_env.cwd`) must
  /// move the pending queue with it — a pinned root lands records where the
  /// post-adoption sweeps never look (issue #59).
  String get _scheduledMessagesRoot =>
      '${config.sessionRoot}/${encodeSessionCwd(_env.cwd)}/messages';

  /// The mailbox of the subagent whose run encloses the caller, or null on
  /// the main agent (gh-970). `schedule_message` resolves "your own
  /// mailbox" through this — the queue's `selfMailbox` always names MAIN,
  /// so without it every child self-reminder landed in main's inbox.
  String? _childSenderMailbox() {
    final id = activeSubagentId();
    return id == null ? null : _subagentManager.mailboxOf(id);
  }

  /// Namespaces this instance's mailboxes with the active session id: two
  /// Fa instances sharing the messaging root never drain each other's
  /// inboxes. Called after every session init/switch.
  ScheduledMessageQueue _newScheduledMessages() {
    final receiptsLog = ScheduledReceiptLog(
      env: _env,
      path: () => '$_scheduledMessagesRoot/receipts.jsonl',
      onError: (text) => io.writeln('[sched] $text'),
    );
    scheduledReceiptsForTest = receiptsLog;
    return ScheduledMessageQueue(
      env: _env,
      repo: () => _fabricRepository,
      root: () => _scheduledMessagesRoot,
      selfMailbox: () => _subagentManager.mailboxOf('main'),
      // Ownership tag for schedule records: a sweeper re-addresses a
      // self-addressed record only when the stored prefix matches this
      // session — another instance's record stays with its owner (#59).
      ownerPrefix: () => _subagentManager.mailboxPrefix,
      // gh-1180 AC4: the persisted receipt trail — scheduled / delivered /
      // delivery_failed / scan_failed events keyed by record id, so a
      // post-mortem can tell "timer never fired" from "wake refused".
      receipts: receiptsLog,
      // Terminal visibility: a dim line when a scheduled message is created
      // and when it fires, so self-reminders are observable without /tasks.
      // Each transition also re-pushes the TUI indicator row (issue #115).
      onScheduled: (text) {
        io.writeln(_style.dim('[sched] $text'));
        unawaited(_pushScheduledStatus());
      },
      onFired: (text) {
        io.writeln(_style.dim('[sched] $text'));
        _hubAddPanel(
          kind: DeferredPanelKind.scheduled,
          from: 'scheduler',
          body: text,
          source: '/schedule',
        );
        unawaited(_pushScheduledStatus());
      },
      // Failure isolation (issue #270): a failed delivery is a visible
      // [sched] line, never a dead heartbeat — the record stays for the
      // next sweep.
      onError: (text) {
        io.writeln('[sched] $text');
      },
    );
  }

  /// The prompt-affecting half of [_syncMailboxPrefix]: assigns the
  /// mailbox prefix and recomposes (the messaging section rides the
  /// prompt). Split out so the resume budget can project the section
  /// BEFORE the gh-968 parity walk (`_loadSession`, issue #1151 review)
  /// without the prefix assignment drifting between the two sites.
  void _assignMailboxPrefix(String id) {
    _subagentManager.mailboxPrefix = id;
    _applyPromptComposition();
  }

  void _syncMailboxPrefix() {
    _assignMailboxPrefix(_session?.cachedId ?? '');
    // Issue #426: child session headers carry `metadata.parent` from the
    // manager's parentSessionId — pinned empty at construction because
    // the session id does not exist yet. Assign it here (the moment the
    // id materializes) so children of THIS session link back to it
    // instead of being written with `parent: ""`.
    _subagentManager.parentSessionId = _subagentManager.mailboxPrefix;
    // Re-arm scheduled-message delivery: pending records that came due
    // while another session was active surface in the now-active mailbox
    // (start() is an idempotent re-arm + drain).
    unawaited(_scheduledMessages.start());
    unawaited(_pushScheduledStatus());
    // Presence: a zero-mail instance is discoverable in agent_directory.
    // The session display name rides along so peers can address this
    // mailbox by name (`--session goal_builder` → `goal_builder/main`).
    final fabric = _subagentManager.messaging;
    final prefix = _subagentManager.mailboxPrefix;
    if (fabric != null && prefix.isNotEmpty) {
      unawaited(_registerFabricMailbox(fabric, prefix));
    }
  }

  /// Re-reads the pending scheduled records and pushes the count + nearest
  /// due into the TUI indicator row (issue #115). Best-effort: a failing
  /// scan only means a stale indicator, never a broken flow.
  Future<void> _pushScheduledStatus() async {
    try {
      final pending = await _scheduledMessages.pendingSummary();
      _tuiController?.setScheduled(pending.count, pending.nextDueMs);
    } on Object {
      // Indicator only — never let visibility break messaging.
    }
  }

  /// Registers the main mailbox with its session display name (best-effort:
  /// a failure never blocks the session switch).
  Future<void> _registerFabricMailbox(
    MessagingRepository fabric,
    String prefix,
  ) async {
    final name = await _session?.getSessionName();
    final trimmed = name?.trim();
    await fabric.register(
      _subagentManager.mailboxOf(_subagentManager.selfId),
      sessionName: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      capabilities: config.agentCapabilities,
    );
  }

  /// Best-effort fabric heartbeat: refreshes this instance's mailbox
  /// liveness marker so agent_directory reports it as live between mails.
  void _touchFabricHeartbeat() {
    final fabric = _subagentManager.messaging;
    if (fabric == null) return;
    unawaited(
      fabric.touch(
        _subagentManager.mailboxOf(_subagentManager.selfId),
        // Mid-run the agent is busy: a directory mark distinct from the
        // idle live heartbeat (issue #27 phase 2).
        busy: isBusy,
      ),
    );
  }

  /// The inbox watcher tick: while IDLE, new inter-agent mail starts a turn
  /// (the loop's first steering poll drains the inbox into the run). Mid-run
  /// mail needs no wake — the per-turn steering poll already delivers it.
  Future<void> _wakeOnInboxMail() async {
    if (_exited || isBusy || _inboxWakeRunning) return;
    // The lane decision (gh-1180): user-kind mail always wakes (gating it
    // on the streak would deadlock: no run → no reset → no run);
    // delivered scheduled self-mail is EXEMPT from the cap (a deliberate
    // agent-chosen cadence — the night-watch lane); foreign agent-to-agent
    // chatter stays capped (anti-storm).
    final pending = await _subagentManager.pendingInbox(
      _subagentManager.selfId,
    );
    final pluginPending = await _anyPluginInboxPending();
    if (pending.isEmpty && !pluginPending) return;
    final decision = _inboxWakePolicy.wakeDecisionFor(
      pending,
      pluginPending: pluginPending,
    );
    await scheduledReceiptsForTest?.append('wake_attempted', {
      'lane': decision.lane.name,
      'ids': [for (final message in pending) message.id],
    });
    if (!decision.wake) {
      // gh-1180 AC4: the refusal is receipted AND visible — a silent
      // drop here was exactly the 2h04m blind window. Print once per
      // episode (the gate holds until user input arrives, so every
      // 2s tick would otherwise spam).
      if (!_inboxWakeRefusalAnnounced) {
        _inboxWakeRefusalAnnounced = true;
        io.writeln(
          _style.dim('[mail] wake refused — ${decision.refusalReason}'),
        );
        await scheduledReceiptsForTest?.append('wake_refused', {
          'lane': decision.lane.name,
          'reason': decision.refusalReason,
        });
      }
      return;
    }
    if (decision.lane != InboxWakeLane.scheduledSelf) {
      _inboxWakeRefusalAnnounced = false;
    }
    // The policy books cap-consuming wakes itself (its streak is the one
    // source of truth; the legacy seam proxies it).
    _inboxWakeRunning = true;
    final count = pending.length;
    io.writeln(
      _style.dim(
        count > 0
            ? '[mail] $count new message(s) — waking up to answer'
            : '[mail] new hub message(s) — waking up to answer',
      ),
    );
    await scheduledReceiptsForTest?.append('turn_started', {
      'lane': decision.lane.name,
      'ids': [for (final message in pending) message.id],
    });
    _startRun(
      '<system-notice>New inter-agent mail arrived '
      '${count > 0 ? '($count message(s))' : '(hub mail)'} — the messages '
      'follow below as user messages. Read them and act: reply via the '
      "sender's messaging tool (agent_message for fabric addresses, dap_dm "
      'for hub peers) when a response is expected, or just incorporate the '
      'information.</system-notice>',
    );
    unawaited(_settled.whenComplete(() => _inboxWakeRunning = false));
  }

  /// Receive-side healing: a sender running an older binary (or any tool
  /// scripting the fabric directly) can address this agent with a truncated
  /// id — the send lands in a fresh mailbox directory no watcher polls and
  /// the message is silently lost. Sweep orphan mailboxes into the real
  /// inbox before the drain so the mail is never lost. Best-effort; runs on
  /// the file-backed local root only (this host's messages root).
  Future<void> _reclaimOrphanFabricMail() async {
    try {
      await reclaimOrphanMailboxMail(
        env: _env,
        root: _messagesRoot,
        agentId: _subagentManager.mailboxOf(_subagentManager.selfId),
      );
      // Catch-up sweep: records scheduled by a previous process (or a
      // sibling pane that exited) come due with nobody armed for them —
      // deliver here so the reminder still surfaces (issue #59).
      await _scheduledMessages.deliverDue();
    } on Object {
      // Never let fabric hygiene break the watcher tick.
    }
  }
}

/// Builds the detached wake command for an asleep mailbox:
/// `nohup <exe> --session <name> "<prompt>" >/dev/null 2>&1 &`. Single
/// quotes every shell word; falls back to `fa` on PATH when [wakeExecutable]
/// is null/empty and to [sessionId] when [sessionName] is.
String mailboxWakeCommand({
  String? wakeExecutable,
  required String sessionId,
  String? sessionName,
}) {
  final exe = (wakeExecutable == null || wakeExecutable.isEmpty)
      ? 'fa'
      : wakeExecutable;
  final address = (sessionName == null || sessionName.isEmpty)
      ? sessionId
      : sessionName;
  String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
  return 'nohup ${q(exe)} --session ${q(address)} '
      '${q(wakePromptText)} >/dev/null 2>&1 & echo woken';
}

/// The prompt the headless wake run starts with — the inbox drain delivers
/// the pending mail into the turn; the session file is shared.
const wakePromptText =
    'You have pending inbox messages; read your inbox and handle them now.';
