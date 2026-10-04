// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the background inbox machinery of
// [AgentService] — mailbox re-addressing, the fabric inbox watcher, the
// wake-on-mail re-entry and the background-shell settle notice — lives
// here so the main file stays under the 2800-line guard. Same library,
// so private members resolve; notifications go through `_notify()`.

part of 'agent_service.dart';

extension AgentServiceInbox on AgentService {
  /// Re-addresses the instance's mailboxes and re-arms scheduled-message
  /// delivery: records that came due under a previous session's mailbox
  /// surface in the now-active one (start() is an idempotent re-arm +
  /// drain) instead of stranding in a mailbox nobody drains.
  void _setMailboxPrefix(String id) {
    _subagentManager?.mailboxPrefix = id;
    // Issue #426: child session headers carry `metadata.parent` from the
    // manager's parentSessionId — pinned empty at construction because
    // the session id does not exist yet. Assign it here (the moment the
    // id materializes) so children of THIS session link back to it
    // instead of being written with `parent: ""`.
    _subagentManager?.parentSessionId = id;
    // Lightweight test services (pre-constructed agent) have no fabric.
    if (_subagentManager == null) return;
    unawaited(_scheduledMessages.start());
  }

  void _startInboxWatcher() {
    // Statics need the class qualifier from an extension (bare names
    // don't resolve to the extended type's statics).
    if (!AgentService.enableInboxWatcher) return;
    _inboxWatchTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      // Every other tick (≈6s): refresh the messaging-fabric heartbeat so
      // agent_directory reports this instance as live between mails.
      if (_fabricHeartbeatTick++ % 2 == 0) _touchFabricHeartbeat();
      // Catch-up sweep: a record whose owning service died before its
      // timer fired (app restart, sheet dispose) is delivered here into
      // the live mailboxes so the reminder still surfaces (issue #59).
      unawaited(_scheduledMessages.deliverDue());
      unawaited(_wakeOnInboxMail());
    });
  }

  /// Best-effort fabric heartbeat; a broken fabric never breaks the watch
  /// loop.
  void _touchFabricHeartbeat() {
    final manager = _subagentManager;
    final fabric = manager?.messaging;
    if (fabric == null) return;
    unawaited(fabric.touch(manager!.mailboxOf(manager.selfId)));
  }

  /// Called when a background shell job settles: the completion re-enters
  /// the conversation as a system notice (sendText steers mid-run and
  /// starts a fresh turn while idle — the same flow as inbox mail). A
  /// foreground consumer that took the result inline skips the notice —
  /// the registry settle bookkeeping itself always runs (issue #562).
  void _onShellJobSettled(ShellJobEntry job) {
    if (_disposed || !job.notifyOnSettle) return;
    unawaited(
      sendText(
        '<system-notice>\n'
        'Background shell job ${job.id} finished with exit code '
        '${job.exitCode}.\n'
        'Command: ${job.command}\n'
        'Log: ${job.logPath}\n'
        'Check the result with bash_job (action: output) or by reading the '
        'log file, and act on it when the result was awaited.\n'
        '</system-notice>',
      ),
    );
  }

  /// Called when a background `task` job settles (issue #958, the same
  /// async-result flow the CLI wires): the settled child's result re-enters
  /// the conversation — sendText steers mid-run and starts a fresh turn
  /// while idle, so an idle orchestrator wakes on its subagents' completion
  /// instead of sitting silent until the user pings.
  void _onTaskJobCompleted(TaskJob job) {
    if (_disposed) return;
    unawaited(sendText(taskAsyncResultNotice(job)));
  }

  Future<void> _wakeOnInboxMail() async {
    final manager = _subagentManager;
    if (manager == null || _inboxWakeRunning || _disposed) return;
    if (isStreaming || _agent.state.isStreaming) return;
    // The lane decision (gh-1180): user-kind mail always wakes; delivered
    // scheduled self-mail is EXEMPT from the cap (deliberate agent-chosen
    // cadence — the night-watch lane); foreign agent-to-agent chatter
    // stays capped (anti-storm).
    final pending = await manager.pendingInbox(manager.selfId);
    if (pending.isEmpty) return;
    final decision = _inboxWakePolicy.wakeDecisionFor(pending);
    // gh-1180 AC4 on this host too: the wake path receipts into the same
    // trail the queue writes, so a post-mortem can tell "timer never
    // fired" from "wake refused" here as well (gh-1180 review: the app
    // used to drop a refused wake fully silently).
    final ids = [for (final message in pending) message.id];
    if (!decision.wake) {
      // One receipt pair per refusal EPISODE (or per NEW pending batch) —
      // the latch lives in the policy next to the streak, so the held
      // batch re-firing every 3s tick stays silent and a user-input
      // reset re-opens the episode.
      if (_inboxWakePolicy.claimRefusalAnnouncement(pending)) {
        final receipts = _scheduledReceipts;
        await receipts?.append('wake_attempted', {
          'lane': decision.lane.name,
          'ids': ids,
        });
        await receipts?.append('wake_refused', {
          'lane': decision.lane.name,
          'reason': decision.refusalReason,
        });
        // The app's never-silent surface (same rule as the image-drop and
        // SLO notices): the user can see WHY mail is not waking.
        AppLog.i('mail', '[mail] wake refused — ${decision.refusalReason}');
      }
      return;
    }
    final receipts = _scheduledReceipts;
    await receipts?.append('wake_attempted', {
      'lane': decision.lane.name,
      'ids': ids,
    });
    final count = pending.length;
    _inboxWakeRunning = true;
    try {
      await receipts?.append('turn_started', {
        'lane': decision.lane.name,
        'ids': ids,
      });
      await sendText(
        '<system-notice>New inter-agent mail arrived ($count message(s)) — '
        'the messages follow below as user messages. Read them and act: '
        'reply with the agent_message tool to the sender address when a '
        'response is expected, or just incorporate the information.'
        '</system-notice>',
      );
    } finally {
      _inboxWakeRunning = false;
    }
  }

  /// The main agent's inbox as steering messages: each pending fabric
  /// message becomes a user message attributed to its sender, so the
  /// transcript reads like a chat between agents.
  Future<List<Message>> _mainInboxMessages() async {
    final manager = _subagentManager;
    if (manager == null) return const [];
    final queued = await manager.drainMessages(manager.selfId);
    return [
      for (final message in queued)
        UserMessage.text('from ${message.fromId}: ${message.text.trim()}'),
    ];
  }
}
