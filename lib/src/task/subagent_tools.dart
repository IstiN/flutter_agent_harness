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

import 'package:flutter_agent_harness/src/messaging/messaging_repository.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'subagent.dart';
import 'subagent_manager.dart';
import 'task_tool.dart' show TaskJobManager, TaskJobStatus;

/// Callback to read the last N messages from a child's session.
typedef ChildMessageReader =
    Future<List<(String role, String text)>> Function(
      String sessionId, {
      int tail,
    });

/// Callback to send a message to a child (resume/steer).
typedef ChildMessageSender =
    Future<void> Function(String sessionId, String message);

/// Callback resolving the CURRENT subagent id, or null outside a child run.
/// The executor sets this per-spawn so the child-only `reply`/`agent_message`
/// tools know whose handle to use.
typedef CurrentSubagentIdProvider = String? Function();

/// Returns the subagent monitoring tools backed by [manager].
/// Register alongside the `task` tool when a manager is available.
/// [jobs] enables `task_cancel` over the session's background job registry.
List<AgentTool> subagentMonitoringTools({
  required SubagentManager? manager,
  ChildMessageReader? readMessages,
  ChildMessageSender? sendToChild,
  CurrentSubagentIdProvider? currentSubagentId,
  TaskJobManager? jobs,
}) {
  if (manager == null) return const [];
  return [
    _taskStatusTool(manager),
    _taskObserveTool(manager, readMessages),
    _taskSendTool(manager, sendToChild),
    if (jobs != null) _taskCancelTool(jobs),
    _replyTool(manager, currentSubagentId),
    _agentMessageTool(manager, currentSubagentId),
    _agentDirectoryTool(manager),
  ];
}

/// `task_cancel` — abort a running background subagent job.
AgentTool _taskCancelTool(TaskJobManager jobs) {
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
        return ToolExecutionResult.text('no background job with id "$id"');
      }
      if (job.status != TaskJobStatus.queued &&
          job.status != TaskJobStatus.running) {
        return ToolExecutionResult.text('job $id already ${job.status.name}');
      }
      job.cancel();
      return ToolExecutionResult.text('cancelled job $id');
    },
  );
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
        'talking to: LIVE mailboxes (recent activity), any mailbox holding '
        'pending mail, your subagents, and your own address (marked). '
        'Each entry shows its session display NAME when known, a short '
        'mailbox id, the pending message count, the last-activity time '
        '("active 2m ago" / "last active 3h ago (asleep)") and the working '
        'directory (home shortened to ~). Stale mailboxes are hidden — '
        'pass all: true to list those too (that also shows FULL mailbox '
        'ids; the default view truncates them to save tokens). Address a '
        'mailbox by its session name via agent_message ("goal_builder" or '
        '"goal_builder/main"); asleep targets are woken with a headless '
        'run automatically.',
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
  // explicitly so they are addressable before that.
  final knownIds = entries.map((e) => e.id).toSet();
  for (final handle in manager.handles) {
    final mailbox = manager.mailboxOf(handle.id);
    if (knownIds.contains(mailbox)) continue;
    final status = switch (handle.status) {
      SubagentStatus.failed => 'failed — resume with task_send',
      _ => handle.status.name,
    };
    buffer
      ..writeln()
      ..write('  ${handle.name} — subagent ($status)');
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
  // A mailbox with unread mail is never hidden, whatever its age.
  final live =
      pending.isNotEmpty ||
      entry.id == self ||
      MailboxEntry.isLive(entry.lastActivity);
  if (!live && !includeStale) return null;
  // Compact ids by default: 36-char uuids burn tokens on every listing.
  // `all: true` shows full ids for copy-paste addressing.
  final idForm = includeStale ? entry.id : _shortId(entry.id);
  final line = StringBuffer(
    '  ${entry.name != null ? '${entry.name} ($idForm)' : idForm}',
  );
  line.write(' — ${pending.length} pending');
  line.write(_activitySuffix(entry.lastActivity));
  if (entry.cwd case final cwd?) line.write('  [${_shortCwd(cwd, homeDir)}]');
  if (entry.id == self) line.write('  ← you');
  return line.toString();
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
        'for the parent orchestrator (for a final answer prefer reply), or '
        'an absolute mailbox "<sessionId>/main" to reach another Fa '
        'instance sharing this session repo. A session display NAME from '
        'agent_directory works too: "goal_builder" or "goal_builder/main" '
        'resolve to that session\'s live mailbox. The recipient sees the '
        'message in its inbox on its next turn; completed siblings are '
        'resumed. Unknown ids and full queues are rejected.',
    parameters: {
      'type': 'object',
      'properties': {
        'to': {
          'type': 'string',
          'description':
              'The sibling subagent id, "main", an absolute mailbox '
              '"<sessionId>/main", or a session name from agent_directory.',
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
      if (target.contains('/')) {
        note = await _asleepTargetNote(manager, target, args['wake'] != false);
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
  final listing = matches
      .map(
        (entry) =>
            '  ${entry.id}${entry.cwd == null ? '' : '  [${entry.cwd}]'}',
      )
      .join('\n');
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
  if (to == manager.selfId || manager[to] != null) return (to, null);
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
  }
  if (matches.isEmpty) return (to, null);
  if (matches.length > 1) {
    final listing = matches
        .map(
          (entry) =>
              '  ${entry.id}${entry.cwd == null ? '' : '  [${entry.cwd}]'}',
        )
        .join('\n');
    return (
      to,
      'session name "$to" is ambiguous — pick an exact mailbox:\n$listing',
    );
  }
  return (matches.single.id, null);
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

/// `task_send` — send a follow-up message to a subagent.
AgentTool _taskSendTool(
  SubagentManager manager,
  ChildMessageSender? sendToChild,
) {
  return AgentTool(
    name: 'task_send',
    description:
        'Send a follow-up message to a subagent. Works with idle '
        '(waiting for input) and completed children — a completed child is '
        'resumed with the new message. Failed/aborted children cannot '
        'receive messages.',
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
    execute: (args, cancelToken, onUpdate) async {
      final id = args['id'] as String;
      final message = args['message'] as String? ?? '';
      if (message.trim().isEmpty) {
        return ToolExecutionResult.text('error: message is required');
      }
      final handle = manager[id];
      if (handle == null) {
        return ToolExecutionResult.text('no subagent with id "$id"');
      }
      if (handle.status == SubagentStatus.failed ||
          handle.status == SubagentStatus.aborted) {
        return ToolExecutionResult.text(
          'cannot send to ${handle.status.name} subagent "$id"',
        );
      }
      if (sendToChild == null) {
        return ToolExecutionResult.text(
          'child messaging not available on this host',
        );
      }
      await sendToChild(handle.sessionId, message);
      await manager.update(id, status: SubagentStatus.running);
      return ToolExecutionResult.text('sent message to "$id" — child resumed');
    },
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
    if (h.modelId != null) 'model: ${h.modelId}',
    if (h.error != null) 'error: ${h.error}',
  ];
  return parts.join('\n');
}
