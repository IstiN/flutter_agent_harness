part of 'agent_cli.dart';

// Implementation members of [AgentCli] for the agent messaging fabric and
// the idle inbox-wake loop — split out of `agent_cli.dart` to keep it under
// the repo's 2800-line size gate. Same library (a `part of`), so the
// extension sees the class's private fields (`_subagentManager`,
// `_session`, the wake-guard fields in the main file) with no visibility
// change.
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
    return [
      for (final message in queued)
        if (message.isUserInput)
          UserMessage.text('[from ${message.fromId}] ${message.text.trim()}')
        else
          UserMessage.text('from ${message.fromId}: ${message.text.trim()}'),
    ];
  }

  /// Namespaces this instance's mailboxes with the active session id: two
  /// Fa instances sharing the messaging root never drain each other's
  /// inboxes. Called after every session init/switch.
  void _syncMailboxPrefix() {
    _subagentManager.mailboxPrefix = _session?.cachedId ?? '';
    // The prompt's messaging section carries the live mailbox address.
    _applyPromptComposition();
    // Presence: a zero-mail instance is discoverable in agent_directory.
    final fabric = _subagentManager.messaging;
    if (fabric != null && _subagentManager.mailboxPrefix.isNotEmpty) {
      unawaited(
        fabric.register(_subagentManager.mailboxOf(_subagentManager.selfId)),
      );
    }
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
    if (pending.isEmpty) return;
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
      _style.dim('[mail] $count new message(s) — waking up to answer'),
    );
    _startRun(
      '<system-notice>New inter-agent mail arrived ($count message(s)) — '
      'the messages follow below as user messages. Read them and act: reply '
      'with the agent_message tool to the sender address when a response is '
      'expected, or just incorporate the information.</system-notice>',
    );
    unawaited(_settled.whenComplete(() => _inboxWakeRunning = false));
  }
}
