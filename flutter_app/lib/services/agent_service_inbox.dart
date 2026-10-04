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
    // gh-1180 AC4 on the app host (review T3): a refused wake is
    // receipted, not a silent drop. Both events ride the policy's
    // once-per-EPISODE gate — the 3 s tick would otherwise duplicate the
    // same rows for as long as the gate holds. The refusal surfaces
    // through the trail (+ the platform log); the [error] banner would
    // misreport a healthy-but-held gate as a failed run.
    if (!decision.wake) {
      if (_inboxWakePolicy.announceRefusal()) {
        AppLog.i('inbox', 'wake refused — ${decision.refusalReason}');
        final ids = [for (final message in pending) message.id];
        await _scheduledReceipts.append('wake_attempted', {
          'lane': decision.lane.name,
          'ids': ids,
        });
        await _scheduledReceipts.append('wake_refused', {
          'lane': decision.lane.name,
          'reason': decision.refusalReason,
        });
      }
      return;
    }
    final count = pending.length;
    _inboxWakeRunning = true;
    try {
      await _scheduledReceipts.append('wake_attempted', {
        'lane': decision.lane.name,
        'ids': [for (final message in pending) message.id],
      });
      // gh-1180 review T10 (CLI parity): turn_started is receipted
      // BEFORE the turn starts, so a throwing turn (provider error,
      // harness failure) never leaves the trail ending at
      // wake_attempted with neither turn_started nor wake_refused — the
      // "was the wake refused?" ambiguity AC4 exists to resolve.
      await _scheduledReceipts.append('turn_started', {
        'lane': decision.lane.name,
        'ids': [for (final message in pending) message.id],
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
    // gh-1180 review T8 (CLI parity): a drained `user`-kind message IS
    // the user talking — it resets the streak AND ends the refusal
    // episode. sendText's own reset is a no-op while the wake flag is
    // held, so without this the streak stayed at the cap and the episode
    // latch stayed set: a repeat refusal after user mail was swallowed
    // (silent AND unreceipted — the exact T2 shape on the second host).
    if (queued.any((message) => message.isUserInput)) {
      _inboxWakePolicy.resetStreak();
    }
    return [
      for (final message in queued)
        UserMessage.text('from ${message.fromId}: ${message.text.trim()}'),
    ];
  }

  /// Test seam: observe/reset the inbox-wake streak without driving ten
  /// real runs — the same seam name the CLI keeps; the streak lives in
  /// [_inboxWakePolicy] (one source of truth).
  @visibleForTesting
  int get inboxWakeStreakForTest => _inboxWakePolicy.streak;

  @visibleForTesting
  set inboxWakeStreakForTest(int value) => _inboxWakePolicy.streak = value;

  /// Test seam: the persisted receipt trail (queue-side AND wake-path
  /// events, gh-1180 AC4).
  @visibleForTesting
  ScheduledReceiptLog get scheduledReceiptsForTest => _scheduledReceipts;
}
