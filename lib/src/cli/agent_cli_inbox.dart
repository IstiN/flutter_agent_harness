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
    if (queued.any((message) => message.isUserInput)) _inboxWakeStreak = 0;
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
        _inboxWakeStreak = 0;
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

  /// Namespaces this instance's mailboxes with the active session id: two
  /// Fa instances sharing the messaging root never drain each other's
  /// inboxes. Called after every session init/switch.
  void _syncMailboxPrefix() {
    _subagentManager.mailboxPrefix = _session?.cachedId ?? '';
    // The prompt's messaging section carries the live mailbox address.
    _applyPromptComposition();
    // Presence: a zero-mail instance is discoverable in agent_directory.
    // The session display name rides along so peers can address this
    // mailbox by name (`--session goal_builder` → `goal_builder/main`).
    final fabric = _subagentManager.messaging;
    final prefix = _subagentManager.mailboxPrefix;
    if (fabric != null && prefix.isNotEmpty) {
      unawaited(_registerFabricMailbox(fabric, prefix));
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
    );
  }

  /// Best-effort fabric heartbeat: refreshes this instance's mailbox
  /// liveness marker so agent_directory reports it as live between mails.
  void _touchFabricHeartbeat() {
    final fabric = _subagentManager.messaging;
    if (fabric == null) return;
    unawaited(
      fabric.touch(_subagentManager.mailboxOf(_subagentManager.selfId)),
    );
  }

  /// The inbox watcher tick: while IDLE, new inter-agent mail starts a turn
  /// (the loop's first steering poll drains the inbox into the run). Mid-run
  /// mail needs no wake — the per-turn steering poll already delivers it.
  Future<void> _wakeOnInboxMail() async {
    if (_exited || isBusy || _inboxWakeRunning) return;
    // The cap throttles AGENT-to-agent chatter only. Mail from the USER
    // (an attached app) must always wake — gating on a counter that the
    // delivery itself resets would deadlock: no run → no reset → no run.
    final pending = await _subagentManager.pendingInbox(
      _subagentManager.selfId,
    );
    final pluginPending = await _anyPluginInboxPending();
    if (pending.isEmpty && !pluginPending) return;
    final hasUserInput = pending.any(
      (message) => message.kind == AgentMessageKind.user,
    );
    if (!hasUserInput && _inboxWakeStreak >= AgentCli._maxInboxWakeStreak) {
      return;
    }
    _inboxWakeStreak++;
    _inboxWakeRunning = true;
    final count = pending.length;
    io.writeln(
      _style.dim(
        count > 0
            ? '[mail] $count new message(s) — waking up to answer'
            : '[mail] new hub message(s) — waking up to answer',
      ),
    );
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
}
