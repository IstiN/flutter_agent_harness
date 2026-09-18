/// Phase 3b+3c tools: `task_status`, `task_observe`, `task_send`,
/// `task_cancel`.
///
/// - `task_status` (read): query one or all retained subagents.
/// - `task_observe` (read): read the last N messages from a child's session.
/// - `task_send` (write): send a follow-up message to an idle/completed child.
/// - `task_cancel` (write): abort a running background subagent job.
///
/// All are backed by the [SubagentManager] injected through
/// [TaskToolConfig.subagentManager]. Without a manager they return guidance.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/messaging/agent_message.dart';
import 'delivery_slo.dart';
import 'package:flutter_agent_harness/src/messaging/messaging_repository.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'subagent.dart';
import 'subagent_manager.dart';
import 'task_executor.dart';
import 'task_tool.dart' show TaskJobManager, TaskJobStatus;

/// Callback to read the last N messages from a child's session.
typedef ChildMessageReader =
    Future<List<(String role, String text)>> Function(
      String sessionId, {
      int tail,
    });

/// Callback to resume a child IN ITS OWN SESSION with a follow-up message
/// (issue #222): the run appends to the same JSONL transcript, keeping the
/// same mailbox id and display name. Backs `task_resume` (failed children)
/// and `task_send` (idle/completed children). Null on hosts that cannot
/// reopen child sessions — the tool descriptors then advertise the missing
/// `child-resume` capability up front.
typedef ChildResumeRunner = Future<void> Function(String id, String message);

/// Callback resolving the CURRENT subagent id, or null outside a child run.
/// The executor sets this per-spawn so the child-only `reply`/`agent_message`
/// tools know whose handle to use.
typedef CurrentSubagentIdProvider = String? Function();

/// Returns the subagent monitoring tools backed by [manager].
/// Register alongside the `task` tool when a manager is available.
/// [jobs] enables `task_cancel` over the session's background job registry.
/// [executor] lets `task_cancel` reach children that run inline on the
/// session executor (blocking batches, resumes) — no TaskJob exists for
/// those, so without it the cancel fallback cannot tell a LIVE inline child
/// from an orphaned registry row (issue #332).
List<AgentTool> subagentMonitoringTools({
  required SubagentManager? manager,
  ChildMessageReader? readMessages,
  ChildResumeRunner? resumeChild,
  CurrentSubagentIdProvider? currentSubagentId,
  TaskJobManager? jobs,
  TaskExecutor? executor,

  /// How long `task_send` waits for a resumed child to acknowledge before
  /// reporting (issue #647). The default equals the delivery SLO: the
  /// warm wake consumes the message before the boot, so the wait never
  /// blocks on session load. A wedged child's wake keeps running in the
  /// background either way.
  Duration taskSendWaitCap = const Duration(milliseconds: 1500),
}) {
  if (manager == null) return const [];
  return [
    _taskStatusTool(manager),
    _taskObserveTool(manager, readMessages),
    _taskSendTool(manager, resumeChild, taskSendWaitCap),
    _taskResumeTool(manager, resumeChild),
    if (jobs != null) _taskCancelTool(jobs, manager, executor),
    _replyTool(manager, currentSubagentId),
    _agentMessageTool(manager, currentSubagentId),
    _agentDirectoryTool(manager),
  ];
}

/// `task_cancel` — abort a running background subagent job.
///
/// Issue #332: ids with no live [TaskJob] fall through to
/// [cancelSubagentWithoutJob] — a LIVE inline child (blocking batch /
/// resume) is aborted through the executor, an orphaned registry row is
/// tombstoned [SubagentStatus.aborted], everything else reports honestly.
AgentTool _taskCancelTool(
  TaskJobManager jobs,
  SubagentManager? manager,
  TaskExecutor? executor,
) {
  return AgentTool(
    name: 'task_cancel',
    description:
        'Abort a running background subagent job by id (see task_status for '
        'ids). The child agent is cancelled; already-settled jobs report '
        'their state instead.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'The background job id to abort.',
        },
      },
      'required': ['id'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) async {
      final id = args['id'] as String;
      final job = jobs.job(id);
      if (job == null) {
        return ToolExecutionResult.text(
          await cancelSubagentWithoutJob(
            id: id,
            manager: manager,
            executor: executor,
          ),
        );
      }
      if (job.status != TaskJobStatus.queued &&
          job.status != TaskJobStatus.running) {
        return ToolExecutionResult.text('job $id already ${job.status.name}');
      }
      job.cancel();
      // A yield-CONVERTED job (a blocking batch moved to background when
      // the user steered mid-run) still has its LIVE runner inline on the
      // executor — the job's token never reached that child, so cancel
      // the in-flight source too (a no-op for plain background jobs,
      // whose token is already linked to the child).
      executor?.cancelInFlight(id);
      return ToolExecutionResult.text('cancelled job $id');
    },
  );
}

/// Cancels the subagent named [id] when its id names no live background
/// [TaskJob] (issue #332) — the ONE helper both cancel surfaces (the
/// `task_cancel` tool and `/tasks cancel`) route through, so their wording
/// can never diverge. Three honest outcomes:
///
/// - a child running inline on [executor] (a blocking-batch spawn or an
///   in-flight resume — these have NO TaskJob by design) is aborted through
///   its in-flight cancel source; its registry row settles through the
///   normal run path. Tombstoning here would lie 'aborted' over a LIVE
///   child and lock steering/task_send out until self-heal.
/// - a registry row whose runner died with a previous host process (no
///   live runner ANYWHERE) is tombstoned [SubagentStatus.aborted] — cancel
///   must always be able to clear a 'running' row.
/// - anything else reports honestly (terminal state / unknown id).
Future<String> cancelSubagentWithoutJob({
  required String id,
  required SubagentManager? manager,
  TaskExecutor? executor,
  String source = 'task_cancel',
}) async {
  if (executor != null && executor.isInFlight(id)) {
    executor.cancelInFlight(id);
    return 'cancel requested for subagent $id — it is running inline '
        '(blocking batch or resume) with no background job; its registry '
        'row settles when the child stops';
  }
  final handle = manager?[id];
  if (handle == null) {
    return 'no background job with id "$id"';
  }
  if (handle.isTerminal) {
    return 'subagent $id already ${handle.status.name}';
  }
  await manager!.update(
    id,
    status: SubagentStatus.aborted,
    error:
        'cancelled by $source: no live runner '
        '(the host session restarted before this child settled)',
  );
  return 'tombstoned subagent $id as aborted — no live runner existed '
      '(interrupted before start), registry row cleared';
}

/// `agent_directory` — the messaging fabric's phone book: the mailboxes
/// worth talking to — LIVE boxes (recent activity), any box holding pending
/// mail, registered subagents, and this agent's own address (marked).
/// Long-dead mailboxes from finished sessions are hidden by default and
/// visible with `all: true`.
AgentTool _agentDirectoryTool(SubagentManager manager) {
  return AgentTool(
    name: 'agent_directory',
    description:
        'List the agent mailboxes in the messaging fabric that are worth '
        'talking to: LIVE mailboxes (registration-backed presence or '
        'recent activity), any mailbox holding pending mail, your '
        'subagents, and your own address (marked). Each entry shows its '
        'session display NAME when known, a short mailbox id, the pending '
        'message count, presence ("live" / "busy (run in progress, '
        'accepts mail)" / "offline"), the last-activity time for offline '
        'entries, and the working directory (home shortened to ~). '
        'Declared capabilities render as sub-lines. Stale mailboxes are '
        'hidden — pass all: true to list those too (that also shows FULL '
        'mailbox ids; the default view truncates them to save tokens). '
        'Address a mailbox by its session name via agent_message '
        '("goal_builder", "goal_builder/main", or "name@machine" — a peer '
        'on another machine is reachable through the A2A gateway when an '
        'a2a.servers entry exists for it); asleep targets are woken with '
        'a headless run automatically.',
    parameters: const {
      'type': 'object',
      'properties': {
        'all': {
          'type': 'boolean',
          'description':
              'Include stale mailboxes (no recent activity, nothing '
              'pending). Default: false.',
        },
      },
    },
    tier: ApprovalTier.read,
    execute: (args, cancelToken, onUpdate) async {
      final includeStale = args['all'] == true;
      return ToolExecutionResult.text(
        await _renderAgentDirectory(manager, includeStale),
      );
    },
  );
}

/// Renders the `agent_directory` body: live mailboxes first (recent
/// activity, pending mail, or this agent's own address — see
/// [_directoryLine]), then registered children, then the stale-count
/// footer. [includeStale] lifts the hiding of long-dead mailboxes.
Future<String> _renderAgentDirectory(
  SubagentManager manager,
  bool includeStale,
) async {
  final fabric = manager.messaging;
  final self = manager.mailboxOf(manager.selfId);
  final entries = await fabric?.directory() ?? const <MailboxEntry>[];
  final buffer = StringBuffer('agent mailboxes (you are "$self"):');
  var stale = 0;
  for (final entry in entries) {
    final line = await _directoryLine(
      fabric!,
      entry,
      self,
      includeStale,
      homeDir: manager.homeDir,
    );
    if (line == null) {
      stale++;
      continue;
    }
    buffer
      ..writeln()
      ..write(line);
  }
  // Registered children get mailboxes on first mail — list them
  // explicitly so they are addressable before that. Superseded generations
  // (issue #222) collapse into their chain head: one logical entry per
  // respawn chain.
  final knownIds = entries.map((e) => e.id).toSet();
  final supersededIds = {
    for (final h in manager.handles)
      if (h.supersedes != null) h.supersedes!,
  };
  for (final handle in manager.handles) {
    if (supersededIds.contains(handle.id)) continue;
    final mailbox = manager.mailboxOf(handle.id);
    if (knownIds.contains(mailbox)) continue;
    final status = switch (handle.status) {
      SubagentStatus.failed => 'failed — resume with task_resume',
      _ => handle.status.name,
    };
    buffer
      ..writeln()
      ..write('  ${handle.name} — subagent ($status)');
    if (handle.supersedes != null) {
      buffer.write(' · supersedes ${handle.supersedes}');
    }
  }
  if (stale > 0) {
    buffer
      ..writeln()
      ..write('  (+$stale stale mailbox(es) hidden — pass all: true)');
  }
  if (entries.isEmpty && manager.handles.isEmpty) {
    buffer.write(' none yet — subagent mailboxes appear on first mail');
  }
  return buffer.toString();
}

/// Renders one directory entry, or null when the mailbox is hidden from
/// the default view: stale (no recent activity), nothing pending, not this
/// agent's own address, and `all: true` not passed.
Future<String?> _directoryLine(
  MessagingRepository fabric,
  MailboxEntry entry,
  String self,
  bool includeStale, {
  String? homeDir,
}) async {
  final pending = await fabric.peek(entry.id);
  if (!_mailboxIsLive(entry, self, pending) && !includeStale) return null;
  final line = StringBuffer(_directoryHead(entry, pending, includeStale));
  line.write(_directoryTags(entry, self, homeDir));
  line.write(_capabilityLines(entry.capabilities));
  return line.toString();
}

/// Whether the default view shows this mailbox at all. A mailbox with
/// unread mail is never hidden, whatever its age, nor is this agent's
/// own address. Registration-backed presence (issue #27 phase 2)
/// counts busy as live too — an agent mid tool-call has no fresh
/// heartbeat but accepts mail. Null presence (file-fabric entries)
/// keeps the mtime heuristic.
bool _mailboxIsLive(
  MailboxEntry entry,
  String self,
  List<AgentMessage> pending,
) =>
    pending.isNotEmpty ||
    entry.id == self ||
    switch (entry.presence) {
      AgentPresence.busy || AgentPresence.live => true,
      AgentPresence.offline => false,
      null => MailboxEntry.isLive(entry.lastActivity),
    };

/// The head of a directory line: indented name (session display NAME
/// in parentheses when known), mailbox id, pending count, presence.
/// Compact ids by default — 36-char uuids burn tokens on every
/// listing; `all: true` shows full ids for copy-paste addressing.
String _directoryHead(
  MailboxEntry entry,
  List<AgentMessage> pending,
  bool includeStale,
) {
  final idForm = includeStale ? entry.id : _shortId(entry.id);
  final line = StringBuffer(
    '  ${entry.name != null ? '${entry.name} ($idForm)' : idForm}',
  );
  line.write(' — ${pending.length} pending');
  line.write(_presenceSuffix(entry));
  return line.toString();
}

/// The trailing tags of a directory line: source, working directory
/// (home shortened to ~), and the self marker. Hub-sourced marker
/// (issue #304 AC3) tells DAP peers apart from file-inbox mailboxes;
/// file/legacy entries (null source) render exactly the legacy bytes
/// (REG).
String _directoryTags(MailboxEntry entry, String self, String? homeDir) {
  final tags = StringBuffer();
  if (entry.source == mailboxSourceHub) tags.write('  [hub]');
  if (entry.cwd case final cwd?) tags.write('  [${_shortCwd(cwd, homeDir)}]');
  if (entry.id == self) tags.write('  ← you');
  return tags.toString();
}

/// Declared capabilities as sub-lines: name, optional description,
/// optional payload hint.
String _capabilityLines(List<AgentCapability> capabilities) {
  final lines = StringBuffer();
  for (final capability in capabilities) {
    lines
      ..writeln()
      ..write('    · ${capability.name}');
    if (capability.description != null) {
      lines.write(' — ${capability.description}');
    }
    if (capability.payload != null) {
      lines.write('  [hint: ${capability.payload}]');
    }
  }
  return lines.toString();
}

/// Truncates a mailbox id to `xxxxxxxx…` (keeping any `/main` suffix) —
/// enough to tell mailboxes apart at a glance without burning tokens on
/// full uuids.
String _shortId(String id) {
  final slash = id.indexOf('/');
  final head = slash < 0 ? id : id.substring(0, slash);
  final tail = slash < 0 ? '' : id.substring(slash);
  if (head.length <= 12) return id;
  return '${head.substring(0, 8)}…$tail';
}

/// Human-readable recency for a mailbox: `— active 2m ago` when the
/// watcher is live, `— last active 3h ago (asleep)` once it stopped
/// ticking. Null timestamps render nothing (the source cannot date it).
String _activitySuffix(DateTime? lastActivity, {DateTime? now}) {
  if (lastActivity == null) return '';
  final now0 = now ?? DateTime.now();
  var delta = now0.difference(lastActivity);
  if (delta.isNegative) delta = Duration.zero;
  final asleep = delta >= MailboxEntry.defaultLiveWindow;
  final rel = _relativeDelta(delta);
  return asleep
      ? ' — last active $rel ago (asleep)'
      : ' — active ${delta.inSeconds < 90 ? 'just now' : '$rel ago'}';
}

/// Presence mark for a directory entry. Registration-backed presence
/// (issue #27 phase 2 — hub roster) wins; null presence (file-fabric
/// entries) falls back to the mtime heuristic in [_activitySuffix].
String _presenceSuffix(MailboxEntry entry, {DateTime? now}) {
  switch (entry.presence) {
    case AgentPresence.busy:
      return ' — busy (run in progress, accepts mail)';
    case AgentPresence.live:
      return ' — live';
    case AgentPresence.offline:
      final last = entry.lastActivity;
      if (last == null) return ' — offline';
      var delta = (now ?? DateTime.now()).difference(last);
      if (delta.isNegative) delta = Duration.zero;
      return ' — offline (last active ${_relativeDelta(delta)} ago)';
    case null:
      return _activitySuffix(entry.lastActivity, now: now);
  }
}

/// Compacts a duration to `2m` / `3h` / `4d` form.
String _relativeDelta(Duration d) {
  if (d.inHours >= 24) return '${d.inDays}d';
  if (d.inMinutes >= 60) return '${d.inHours}h';
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// Shortens a cwd tag below the home directory (`/home/u/git/x` →
/// `~/git/x`); unchanged when [homeDir] is null or not a prefix.
String _shortCwd(String cwd, String? homeDir) {
  if (homeDir == null || homeDir.isEmpty) return cwd;
  if (cwd == homeDir) return '~';
  if (cwd.startsWith('$homeDir/')) return '~${cwd.substring(homeDir.length)}';
  return cwd;
}

/// `reply` — the CHILD-only tool: delivers the child's explicit answer to
/// the parent (prime-agent's `reply`). A reply replaces the default
/// completed_without_reply notice: the parent event/envelope carries the
/// reply text verbatim.
AgentTool _replyTool(
  SubagentManager manager,
  CurrentSubagentIdProvider? currentSubagentId,
) {
  return AgentTool(
    name: 'reply',
    description:
        'Deliver your explicit answer to the parent agent. Call this when '
        'your task output is ready — the text becomes the parent-visible '
        'reply. If you never call it, the parent still sees your final '
        'message as a completion notice, but an explicit reply is the '
        'reliable channel.',
    parameters: {
      'type': 'object',
      'properties': {
        'message': {
          'type': 'string',
          'description': 'The answer/deliverable for the parent.',
        },
      },
      'required': ['message'],
    },
    tier: ApprovalTier.read,
    execute: (args, cancelToken, onUpdate) async {
      final message = args['message'] as String? ?? '';
      if (message.trim().isEmpty) {
        return ToolExecutionResult.text('error: message is required');
      }
      final id = currentSubagentId?.call();
      if (id == null) {
        return ToolExecutionResult.text(
          'reply is only available inside a subagent run',
        );
      }
      await manager.recordReply(id, message);
      return ToolExecutionResult.text('reply delivered to the parent');
    },
  );
}

/// `agent_message` — sibling↔sibling messaging within the session family
/// (Phase 3b). Rate-limited by the pending-queue guard, hop-capped via the
/// message's hop counter, and restricted to known siblings (no arbitrary
/// sessions; the parent uses `task_send`).
AgentTool _agentMessageTool(
  SubagentManager manager,
  CurrentSubagentIdProvider? currentSubagentId,
) {
  return AgentTool(
    name: 'agent_message',
    description:
        'Send a message to another agent: a SIBLING subagent id, "main" '
        'for the parent orchestrator (for a final answer prefer reply), '
        'an absolute mailbox "<sessionId>/main" to reach another Fa '
        'instance sharing this session repo, or "name@machine" to reach a '
        'session on another machine (delivered through the A2A gateway; '
        'the remote machine must be configured under a2a.servers). A '
        'session display NAME from agent_directory works too: '
        '"goal_builder" or "goal_builder/main" resolve to that session\'s '
        'live mailbox. The recipient sees the message in its inbox on its '
        'next turn; completed siblings are resumed. Unknown ids and full '
        'queues are rejected.',
    parameters: {
      'type': 'object',
      'properties': {
        'to': {
          'type': 'string',
          'description':
              'The sibling subagent id, "main", an absolute mailbox '
              '"<sessionId>/main", a session name from agent_directory, '
              'or "name@machine" for a cross-machine peer (A2A gateway).',
        },
        'message': {
          'type': 'string',
          'description': 'The message body for the sibling.',
        },
        'wake': {
          'type': 'boolean',
          'description':
              'When the cross-session target is asleep (no live watcher — '
              'it would not read the message until started), launch a '
              'detached headless run of its session to process the inbox '
              'now. Default: true. The run appends to the same session '
              'JSONL, so a later interactive start resumes it.',
        },
      },
      'required': ['to', 'message'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) async {
      final to = args['to'] as String;
      final message = args['message'] as String? ?? '';
      final fromId = currentSubagentId?.call() ?? manager.selfId;
      if (message.trim().isEmpty) {
        return ToolExecutionResult.text('error: message is required');
      }
      if (to == fromId) {
        return ToolExecutionResult.text('error: cannot message yourself');
      }
      final (target, resolveError) = await _resolveFabricAddress(manager, to);
      if (resolveError != null) {
        return ToolExecutionResult.text('error: $resolveError');
      }
      if (target == fromId || target == manager.mailboxOf(fromId)) {
        return ToolExecutionResult.text('error: cannot message yourself');
      }
      try {
        await manager.enqueueMessage(
          target,
          SubagentMessage(
            fromId: fromId,
            text: message,
            sentAt: DateTime.now().toUtc().toIso8601String(),
            hops: 2,
          ),
        );
      } on StateError catch (error) {
        return ToolExecutionResult.text('error: $error');
      }
      var note = '';
      if (target.contains('@')) {
        note = ' Cross-machine delivery rode the A2A gateway.';
      } else if (target.contains('/')) {
        note = await _asleepTargetNote(manager, target, args['wake'] != false);
        // Cross-root honesty (issue #516): when the id owns mailboxes
        // under several project roots, name where delivery landed — the
        // live registration wins, a stale corpse is never silent.
        final entries =
            await manager.messaging?.directory() ?? const <MailboxEntry>[];
        note += mailboxMisrouteNote(entries, target);
      }
      return ToolExecutionResult.text('message queued for "$to".$note');
    },
  );
}

/// After a cross-session delivery, checks whether the target's watcher is
/// asleep and — when [wake] — launches a detached headless run of its
/// session so the mail is processed now instead of never. Returns the
/// sentence appended to the tool result.
Future<String> _asleepTargetNote(
  SubagentManager manager,
  String target,
  bool wake,
) async {
  final fabric = manager.messaging;
  if (fabric == null) return '';
  final MailboxEntry entry;
  try {
    entry = (await fabric.directory()).firstWhere((e) => e.id == target);
  } on StateError {
    return '';
  }
  if (MailboxEntry.isLive(entry.lastActivity)) return '';
  final sessionId = target.endsWith('/main')
      ? target.substring(0, target.length - '/main'.length)
      : target;
  final address = entry.name ?? sessionId;
  final activity = entry.lastActivity == null
      ? ''
      : ' (last active ${_relativeDelta(DateTime.now().difference(entry.lastActivity!))} ago)';
  if (!wake) {
    return ' Target is asleep$activity — it will not read this until '
        'started: fa --session $address';
  }
  final launcher = manager.wakeProcess;
  if (launcher == null) {
    return ' Target is asleep$activity and this host cannot launch runs — '
        'start it manually: fa --session $address';
  }
  final error = await launcher(
    cwd: entry.cwd ?? '.',
    sessionId: sessionId,
    sessionName: entry.name,
  );
  if (error != null) return ' Target is asleep$activity — wake failed: $error';
  return ' Target is asleep$activity — launched a headless run of session '
      '"$address" to process the inbox now (a later interactive '
      'fa --session $address resumes the same session).';
}

/// The entries matching [to] as a session display NAME: a bare name
/// matches `entry.name` exactly; a `name/suffix` form matches the name
/// AND the id suffix (so `goal_builder/main` cannot hit a subagent).
List<MailboxEntry> _nameMatches(List<MailboxEntry> entries, String to) {
  final slash = to.indexOf('/');
  return (slash < 0
          ? entries.where((entry) => entry.name != null && entry.name == to)
          : entries.where(
              (entry) =>
                  entry.id.endsWith('/${to.substring(slash + 1)}') &&
                  entry.name == to.substring(0, slash),
            ))
      .toList();
}

/// Resolves [to] against [entries] as a truncated mailbox id (the short
/// form agent_directory displays, `…` decoration included): a unique
/// prefix returns the one real mailbox id, an ambiguous prefix returns an
/// error listing the candidates, no match returns `(null, null)`.
(String?, String?) _resolveTruncatedId(List<MailboxEntry> entries, String to) {
  final head = to.split('/').first.replaceAll('…', '');
  if (head.isEmpty) return (null, null);
  final matches = [
    for (final entry in entries)
      if (entry.id != to && entry.id.startsWith(head)) entry,
  ];
  if (matches.length == 1) return (matches.single.id, null);
  if (matches.length <= 1) return (null, null);
  final listing = _listMailboxes(matches);
  return (
    null,
    '"$to" is an ambiguous id prefix — pick an exact mailbox:\n$listing',
  );
}

/// Resolves [to] against the fabric directory by session display NAME when
/// the raw form does not already hit a deliverable address: a local
/// sibling handle, `main`, or an exact absolute mailbox id. Returns the
/// (possibly rewritten) target plus an error text when the name is
/// ambiguous — an unknown name returns [to] unchanged so the manager's own
/// unknown-recipient error applies.
Future<(String, String?)> _resolveFabricAddress(
  SubagentManager manager,
  String to,
) async {
  final fabric = manager.messaging;
  if (fabric == null) return (to, null);
  final (stripped, suffixError) = _stripLocalMachineSuffix(manager, to);
  if (suffixError != null) return (stripped, suffixError);
  to = stripped;
  if (to == manager.selfId || manager[to] != null) return (to, null);
  final local = _resolveLocalChildName(manager, to);
  if (local != null) return local;
  return _resolveDirectoryAddress(fabric, to);
}

/// Session-local child-name resolution for [_resolveFabricAddress]
/// (issue #222): subagent mailboxes are addressable cross-session as
/// `<parentSessionId>/<agentName>`; bare child names resolve
/// session-locally. Both go through the LOCAL registry first — a
/// name-based address must land in the child's real mailbox
/// (`<prefix>/<childId>`), never in a freshly minted lookalike. Returns
/// null when [to] names no local child concern — the caller falls
/// through to the fabric directory.
(String, String?)? _resolveLocalChildName(SubagentManager manager, String to) {
  final prefix = manager.mailboxPrefix.isNotEmpty
      ? manager.mailboxPrefix
      : manager.parentSessionId;
  final slash = to.indexOf('/');
  if (slash > 0 && to.substring(0, slash) == prefix) {
    return _resolvePrefixedTail(manager, to, to.substring(slash + 1));
  }
  if (slash < 0) return _resolveBareChildName(manager, to);
  return null;
}

/// Resolves the `<prefix>/<tail>` form against the local registry: the
/// tail is this agent itself, a child id, or a unique child display name
/// — a name match must land in the child's REAL mailbox, not a lookalike.
(String, String?)? _resolvePrefixedTail(
  SubagentManager manager,
  String to,
  String tail,
) {
  if (tail == manager.selfId) return (to, null);
  final byId = manager[tail];
  if (byId != null) return (manager.mailboxOf(byId.id), null);
  final named = manager.handles.where((h) => h.name == tail).toList();
  if (named.length == 1) return (manager.mailboxOf(named.single.id), null);
  if (named.length > 1) return (to, _ambiguousChildName(tail, named));
  return null;
}

/// Resolves a bare child display name: unique → the child's own id,
/// ambiguous → error; null when nothing local matches.
(String, String?)? _resolveBareChildName(SubagentManager manager, String to) {
  final named = manager.handles.where((h) => h.name == to).toList();
  if (named.length == 1) return (named.single.id, null);
  if (named.length > 1) return (to, _ambiguousChildName(to, named));
  return null;
}

/// Fabric-directory resolution for [_resolveFabricAddress]: an exact
/// mailbox id passes through; a session display NAME resolves to the one
/// live mailbox, or errors when ambiguous. An unknown name returns [to]
/// unchanged so the manager's own unknown-recipient error applies.
Future<(String, String?)> _resolveDirectoryAddress(
  MessagingRepository fabric,
  String to,
) async {
  final entries = await fabric.directory();
  if (entries.any((entry) => entry.id == to)) return (to, null);
  final matches = _nameMatches(entries, to);
  // A sender may address this agent with a TRUNCATED id — the short form
  // agent_directory displays by default (`01a060f2/main` for
  // `01a060f2-7d4b-…/main`). Delivering verbatim would create a fresh
  // mailbox directory no watcher ever polls: silent mail loss. Resolve a
  // unique id-prefix to the one real mailbox; an ambiguous prefix is an
  // error listing the candidates (never a new mailbox).
  if (matches.isEmpty) {
    final (prefixTarget, prefixError) = _resolveTruncatedId(entries, to);
    if (prefixError != null) return (to, prefixError);
    if (prefixTarget != null) return (prefixTarget, null);
    return (to, null);
  }
  if (matches.length > 1) {
    return (
      to,
      'session name "$to" is ambiguous — '
          'pick an exact mailbox:\n${_listMailboxes(matches)}',
    );
  }
  return (matches.single.id, null);
}

/// Formats ambiguous-match candidates for error text.
String _listMailboxes(List<MailboxEntry> matches) => matches
    .map(
      (entry) =>
          '  ${entry.id}${entry.cwd == null ? '' : '  [${entry.cwd}]'}'
          '${entry.isConfirmedLive ? ' — live' : ''}',
    )
    .join('\n');

/// Formats an ambiguous child-NAME error (issue #222): a respawn chain
/// shares one display name across generations, so a bare name can hit
/// several handles — the error lists the candidate ids to pick from.
String _ambiguousChildName(String name, List<SubagentHandle> matches) =>
    'subagent name "$name" is ambiguous — pick an id:\n'
    '${matches.map((h) => '  ${h.id} (${h.status.name})').join('\n')}';

/// Strips a `name@machine` suffix that names this host. Returns the bare
/// name for local delivery, the address unchanged (routed through the A2A
/// gateway at delivery time) for a foreign machine when the gateway is
/// wired, and an error text for invalid forms and for foreign machines on
/// hosts without a gateway.
(String, String?) _stripLocalMachineSuffix(SubagentManager manager, String to) {
  if (!to.contains('@')) return (to, null);
  final at = to.indexOf('@');
  final machine = to.substring(at + 1).trim().toLowerCase();
  final local = manager.machineName?.trim().toLowerCase();
  if (machine.isEmpty || to.substring(0, at).trim().isEmpty) {
    return (to, 'invalid address "$to" — expected name@machine');
  }
  if (local == null || machine != local) {
    if (manager.a2aGateway == null) {
      return (
        to,
        '"$to" names another machine and this host has no A2A gateway — '
            'cross-machine delivery needs an a2a.servers entry for it',
      );
    }
    return (to, null);
  }
  return (to.substring(0, at).trim(), null);
}

/// `task_status` — query one or all retained subagents.
AgentTool _taskStatusTool(SubagentManager manager) {
  return AgentTool(
    name: 'task_status',
    description:
        'Check the status of spawned subagents. Without an id, '
        'lists ALL subagents with their current state, token usage, and '
        'last activity. With an id, shows that subagent in detail.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Optional: a specific subagent id. Omit to list all.',
        },
      },
    },
    tier: ApprovalTier.read,
    execute: (args, cancelToken, onUpdate) async {
      final id = args['id'] as String?;
      if (id != null) {
        final handle = manager[id];
        if (handle == null) {
          return ToolExecutionResult.text('no subagent with id "$id"');
        }
        return ToolExecutionResult.text(_formatHandleDetail(handle));
      }
      final handles = manager.handles;
      if (handles.isEmpty) {
        return ToolExecutionResult.text('no subagents spawned');
      }
      final lines = [for (final h in handles) h.statusLine];
      return ToolExecutionResult.text(
        '${handles.length} subagent${handles.length == 1 ? '' : 's'}:\n'
        '${lines.join('\n')}',
      );
    },
  );
}

/// `task_observe` — read the recent message history of a subagent.
AgentTool _taskObserveTool(
  SubagentManager manager,
  ChildMessageReader? readMessages,
) {
  return AgentTool(
    name: 'task_observe',
    description:
        'Read the recent message history of a subagent. Useful to '
        'inspect what a child discovered or decided before following up.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'The subagent id to observe.'},
        'tail': {
          'type': 'integer',
          'description': 'Number of recent messages to read (default 10).',
        },
      },
      'required': ['id'],
    },
    tier: ApprovalTier.read,
    execute: (args, cancelToken, onUpdate) async {
      final id = args['id'] as String;
      final tail = args['tail'] as int? ?? 10;
      final handle = manager[id];
      if (handle == null) {
        return ToolExecutionResult.text('no subagent with id "$id"');
      }
      if (readMessages == null) {
        return ToolExecutionResult.text(
          'session reading not available on this host — '
          'status: ${handle.status.name}',
        );
      }
      final messages = await readMessages(handle.sessionId, tail: tail);
      if (messages.isEmpty) {
        return ToolExecutionResult.text('no messages in session for "$id"');
      }
      final lines = [for (final m in messages) '${m.$1}: ${m.$2}'];
      return ToolExecutionResult.text(lines.join('\n'));
    },
  );
}

/// `task_send` — send a follow-up message to a subagent. Steering a
/// RUNNING child works on every host (the message lands in the child's
/// inbox and is delivered at the next turn boundary); resuming an
/// idle/completed child needs the host's [ChildResumeRunner] — when it is
/// missing, the descriptor says so up front (`steering: unavailable`) and
/// the error names the capability. Remote `a2a:` children are rejected
/// outright: they have no local inbox loop, so queued mail would never be
/// delivered (the error names the actual delivery channel instead).
AgentTool _taskSendTool(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  Duration taskSendWaitCap,
) {
  final unavailableNote = resumeChild == null
      ? ' NOTE: this host can steer RUNNING children only — follow-ups to '
            'idle/completed children are unavailable here '
            '(steering: unavailable, capability: child-resume).'
      : '';
  return AgentTool(
    name: 'task_send',
    description:
        'Send a follow-up message to a subagent. A running child receives '
        'it in its inbox at the next turn boundary; an idle (waiting for '
        'input) or completed child is resumed in its SAME session with the '
        'message. The resume wait is capped (${taskSendWaitCap.inSeconds}s): '
        'a child that does not respond in time reports the message queued '
        'and keeps waking in the background (check task_status). Failed '
        'children are continued with task_resume instead. Remote '
        'a2a:<name> children cannot be steered or resumed — they have no '
        'local session or inbox; follow up with a new task item.'
        '$unavailableNote',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'The subagent id to message.'},
        'message': {
          'type': 'string',
          'description': 'The follow-up instruction or question.',
        },
      },
      'required': ['id', 'message'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) =>
        _runTaskSend(manager, resumeChild, args, taskSendWaitCap),
  );
}

/// Body of the `task_send` executor: validates input, refuses remote
/// `a2a:` children (whatever their status — they have no local loop
/// draining an inbox, so "queued … delivered at the next turn boundary"
/// would be a lie and the mail would sit undelivered forever), then
/// dispatches by child status.
Future<ToolExecutionResult> _runTaskSend(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  Map<String, dynamic> args,
  Duration taskSendWaitCap,
) async {
  final id = args['id'] as String;
  final message = args['message'] as String? ?? '';
  if (message.trim().isEmpty) {
    return ToolExecutionResult.text('error: message is required');
  }
  final handle = manager[id];
  if (handle == null) {
    return ToolExecutionResult.text('no subagent with id "$id"');
  }
  // Remote `a2a:` children first, whatever their status: they have no
  // local loop draining an inbox (the remote prompt is assembled once,
  // at send time) — name the actual delivery channel instead.
  if (handle.agentType.startsWith('a2a:')) {
    return ToolExecutionResult.text(
      'cannot send to "$id": it runs remotely as ${handle.agentType} — '
      'a remote a2a child has no local session or inbox to steer. '
      'Follow up with a new task item (agent ${handle.agentType}) '
      'carrying your message in its task text.',
    );
  }
  return _sendByChildStatus(
    manager,
    resumeChild,
    id,
    handle,
    message,
    taskSendWaitCap,
  );
}

/// `task_send` dispatch on child status: failed/aborted refuse, active
/// children are steered through their inbox, idle/completed children are
/// resumed in the same session.
Future<ToolExecutionResult> _sendByChildStatus(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  String id,
  SubagentHandle handle,
  String message,
  Duration taskSendWaitCap,
) async {
  switch (handle.status) {
    case SubagentStatus.failed:
      return ToolExecutionResult.text(
        'subagent "$id" failed — resume it with task_resume (task_send '
        'only steers running/idle/completed children)',
      );
    case SubagentStatus.aborted:
      return ToolExecutionResult.text('cannot send to aborted subagent "$id"');
    case SubagentStatus.queued:
    case SubagentStatus.running:
      return _enqueueFollowUp(manager, id, message);
    case SubagentStatus.idle:
    case SubagentStatus.completed:
      return _resumeIdleChild(
        manager,
        resumeChild,
        id,
        handle,
        message,
        taskSendWaitCap,
      );
  }
}

/// Steering a queued/running child: the message lands in its inbox and is
/// delivered at the next turn boundary — soft-yielded into a long tool
/// call within the SLO (issue #647: the child loop probes the inbox and
/// the executor pokes the child on arrival).
Future<ToolExecutionResult> _enqueueFollowUp(
  SubagentManager manager,
  String id,
  String message,
) async {
  try {
    await manager.enqueueMessage(
      id,
      SubagentMessage(
        fromId: manager.selfId,
        text: message,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  } on StateError catch (error) {
    return ToolExecutionResult.text('error: $error');
  }
  deliveryStage(id, 'enqueued');
  return ToolExecutionResult.text(
    'queued message for running subagent "$id" — delivered at the '
    'next turn boundary',
  );
}

/// Follow-up to an idle/completed child: resume it in its SAME session
/// with the message — needs the host's child-resume capability.
Future<ToolExecutionResult> _resumeIdleChild(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  String id,
  SubagentHandle handle,
  String message,
  Duration taskSendWaitCap,
) async {
  if (resumeChild == null) {
    return ToolExecutionResult.text(
      'cannot resume ${handle.status.name} subagent "$id": child '
      'resume not available on this host '
      '(capability: child-resume)',
    );
  }
  // Issue #488 AC3 + #647: the parent must never hang on a wedged child,
  // and the wait must respect the delivery SLO. The warm wake consumes
  // the message before the boot, so the default cap (1.5s) reports the
  // receipt; past the cap the send reports the message queued and the
  // resume KEEPS RUNNING in the background — when the wedge breaks, the
  // child completes in its own session (the registry row and transcript
  // tell the truth, task_cancel reaches it). A late resume failure is
  // already recorded by resumeChild itself; only its rethrow is swallowed
  // here.
  final resumed = resumeChild(id, message);
  try {
    // Issue #439 compact-then-deliver: the resume path compacts BEFORE the
    // first request when prior + incoming would cross the threshold — the
    // receipt lands on the handle, so surface it to the parent.
    final compactionsBefore = handle.compactions;
    await resumed.timeout(taskSendWaitCap);
    final after = manager[id];
    final compactNote = after != null && after.compactions > compactionsBefore
        ? '; subagent compacted before delivery '
              '(freed ${after.lastCompactionFreed}t)'
        : '';
    return ToolExecutionResult.text(
      'sent message to "$id" — child resumed '
      '(status: ${after?.status.name ?? 'unknown'})$compactNote',
    );
  } on TimeoutException {
    unawaited(resumed.catchError((Object _) {}));
    return ToolExecutionResult.text(
      'child "$id" not responding within the wait cap — message queued '
      'in its inbox (consumed into the resumed run, which keeps going in '
      'the background and will process it as its first action; see '
      'task_status)',
    );
  } on Object catch (error) {
    return ToolExecutionResult.text('resume of "$id" failed: $error');
  }
}

/// `task_resume` — continue a FAILED child in its SAME session (issue
/// #222): one verb, one job. The run appends to the existing JSONL
/// transcript with the same mailbox id and display name — never a cloned
/// `name-2` session. Needs the host's [ChildResumeRunner]; without it the
/// descriptor and the error name the missing capability.
AgentTool _taskResumeTool(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
) {
  final unavailableNote = resumeChild == null
      ? ' UNAVAILABLE on this host (capability: child-resume).'
      : '';
  return AgentTool(
    name: 'task_resume',
    description:
        'Resume a FAILED subagent, continuing the SAME session: the run '
        'appends to the existing JSONL transcript, keeps the same mailbox '
        'id and display name, and never mints a cloned "name-2" session. '
        'Use this after transient failures (provider quota, network). '
        'Steering running/idle/completed children is task_send; respawning '
        'a fresh agent is task (the new child links supersedes).'
        '$unavailableNote',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'The failed subagent id.'},
        'message': {
          'type': 'string',
          'description':
              'Optional resume instruction. Default: continue the original '
              'task from where the child stopped.',
        },
      },
      'required': ['id'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) =>
        _runTaskResume(manager, resumeChild, args),
  );
}

/// Body of the `task_resume` executor: validates the target, refuses
/// remote `a2a:` children (no local session to resume), then dispatches
/// by child status.
Future<ToolExecutionResult> _runTaskResume(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  Map<String, dynamic> args,
) async {
  final id = args['id'] as String;
  final message = _resumeInstruction(args);
  final handle = manager[id];
  if (handle == null) {
    return ToolExecutionResult.text('no subagent with id "$id"');
  }
  // Remote a2a children have no local session to resume — point at the
  // actual channel up front instead of a doomed capability dance.
  if (handle.agentType.startsWith('a2a:')) {
    return ToolExecutionResult.text(
      'cannot resume "$id": it runs remotely as ${handle.agentType} — '
      'there is no local session to continue. Follow up with a new task '
      'item (agent ${handle.agentType}) carrying your message in its '
      'task text.',
    );
  }
  return _resumeByChildStatus(manager, resumeChild, id, handle, message);
}

/// The `task_resume` instruction: an explicit non-blank message, else the
/// default "continue the original task" wording.
String _resumeInstruction(Map<String, dynamic> args) {
  final message = (args['message'] as String?)?.trim() ?? '';
  return message.isNotEmpty
      ? message
      : 'Continue your task from where you stopped.';
}

/// `task_resume` dispatch on child status: only failed children resume;
/// everything else explains why not (and where to go instead).
Future<ToolExecutionResult> _resumeByChildStatus(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  String id,
  SubagentHandle handle,
  String message,
) async {
  switch (handle.status) {
    case SubagentStatus.queued:
    case SubagentStatus.running:
      return ToolExecutionResult.text(
        'subagent "$id" is already running — duplicate resume rejected',
      );
    case SubagentStatus.idle:
    case SubagentStatus.completed:
      return ToolExecutionResult.text(
        'subagent "$id" is ${handle.status.name}, not failed — steer '
        'it with task_send',
      );
    case SubagentStatus.aborted:
      return ToolExecutionResult.text(
        'aborted subagent "$id" cannot be resumed',
      );
    case SubagentStatus.failed:
      return _resumeFailedChild(manager, resumeChild, id, message);
  }
}

/// Resumes a failed child in its SAME session; a failed resume leaves the
/// child failed and resumable.
Future<ToolExecutionResult> _resumeFailedChild(
  SubagentManager manager,
  ChildResumeRunner? resumeChild,
  String id,
  String message,
) async {
  if (resumeChild == null) {
    return ToolExecutionResult.text(
      'resume not available on this host '
      '(capability: child-resume) — the child stays failed',
    );
  }
  try {
    await resumeChild(id, message);
  } on Object catch (error) {
    final detail = error is StateError ? error.message : '$error';
    return ToolExecutionResult.text(
      'resume of "$id" failed: $detail — the child stays failed '
      'and resumable',
    );
  }
  final sessionPath = manager[id]?.sessionId;
  final cwdNote = sessionPath == null ? '' : ' [session: $sessionPath]';
  return ToolExecutionResult.text(
    'resumed "$id" — child ${manager[id]?.status.name ?? 'unknown'}'
    '$cwdNote',
  );
}

/// Formats a detailed view of one handle for `task_status`.
String _formatHandleDetail(SubagentHandle h) {
  final parts = <String>[
    'id: ${h.id}',
    'type: ${h.agentType}',
    'status: ${h.status.name}',
    'task: ${h.task}',
    'session: ${h.sessionId}',
    'created: ${h.createdAt}',
    'last activity: ${h.lastActivity}',
    'tokens: ${h.tokens}',
    'requests: ${h.requests}',
    if (h.estTokens != null && h.windowTokens != null && h.windowTokens! > 0)
      'context: ~${h.estTokens}/${h.windowTokens} tokens '
          '(${(h.estTokens! * 100 / h.windowTokens!).round()}%)'
    else
      'context: n/a',
    'last compaction: ${h.lastCompactionText ?? 'n/a'}',
    if (h.modelId != null) 'model: ${h.modelId}',
    if (h.error != null) 'error: ${h.error}',
  ];
  return parts.join('\n');
}
