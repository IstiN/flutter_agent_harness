/// Phase 3b+3c tools: `task_status`, `task_observe`, `task_send`.
///
/// - `task_status` (read): query one or all retained subagents.
/// - `task_observe` (read): read the last N messages from a child's session.
/// - `task_send` (write): send a follow-up message to an idle/completed child.
///
/// All three are backed by the [SubagentManager] injected through
/// [TaskToolConfig.subagentManager]. Without a manager they return guidance.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'subagent.dart';
import 'subagent_manager.dart';

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
List<AgentTool> subagentMonitoringTools({
  required SubagentManager? manager,
  ChildMessageReader? readMessages,
  ChildMessageSender? sendToChild,
  CurrentSubagentIdProvider? currentSubagentId,
}) {
  if (manager == null) return const [];
  return [
    _taskStatusTool(manager),
    _taskObserveTool(manager, readMessages),
    _taskSendTool(manager, sendToChild),
    _replyTool(manager, currentSubagentId),
    _agentMessageTool(manager, currentSubagentId),
  ];
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
        'Send a message to a SIBLING subagent in the same session family '
        '(not the parent — use reply for that). The sibling sees the message '
        'as a queued instruction; running siblings get it on their next '
        'turn, completed siblings are resumed. Unknown ids and full queues '
        'are rejected.',
    parameters: {
      'type': 'object',
      'properties': {
        'to': {
          'type': 'string',
          'description': 'The sibling subagent id.',
        },
        'message': {
          'type': 'string',
          'description': 'The message body for the sibling.',
        },
      },
      'required': ['to', 'message'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) async {
      final to = args['to'] as String;
      final message = args['message'] as String? ?? '';
      final fromId = currentSubagentId?.call() ?? 'parent';
      if (message.trim().isEmpty) {
        return ToolExecutionResult.text('error: message is required');
      }
      if (to == fromId) {
        return ToolExecutionResult.text('error: cannot message yourself');
      }
      try {
        await manager.enqueueMessage(
          to,
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
      return ToolExecutionResult.text('message queued for "$to"');
    },
  );
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
