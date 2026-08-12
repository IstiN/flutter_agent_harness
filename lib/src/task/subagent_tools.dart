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

/// Returns the subagent monitoring tools backed by [manager].
/// Register alongside the `task` tool when a manager is available.
List<AgentTool> subagentMonitoringTools({
  required SubagentManager? manager,
  ChildMessageReader? readMessages,
  ChildMessageSender? sendToChild,
}) {
  if (manager == null) return const [];
  return [
    AgentTool(
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
            'description':
                'Optional: a specific subagent id. Omit to list all.',
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
    ),
    AgentTool(
      name: 'task_observe',
      description:
          'Read the recent message history of a subagent. Useful to '
          'inspect what a child discovered or decided before following up.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'The subagent id to observe.',
          },
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
    ),
    AgentTool(
      name: 'task_send',
      description:
          'Send a follow-up message to a subagent. Works with idle '
          '(waiting for input) and completed children — a completed child is '
          'resumed with the new message. Failed/aborted children cannot '
          'receive messages.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'The subagent id to message.',
          },
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
        return ToolExecutionResult.text(
          'sent message to "$id" — child resumed',
        );
      },
    ),
  ];
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
