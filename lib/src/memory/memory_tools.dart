/// Agent tools for durable cross-session memory: `memory_add`, `memory_search`,
/// `memory_list`. Registered when a [MemoryController] is available.
library;

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'memory_controller.dart';

/// Returns the three memory tools backed by [controller].
/// `memory_add` is write-tier; `memory_search` and `memory_list` are read-tier.
List<AgentTool> memoryTools(MemoryController? controller) {
  if (controller == null) return const [];
  return [
    AgentTool(
      name: 'memory_add',
      description:
          'Store a durable fact, preference, or observation in '
          'long-term memory. Use for things that should persist across '
          'sessions — project conventions, user preferences, key decisions. '
          'Do NOT use for task progress or transient state.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description':
                'The memory content — a concise, self-contained fact.',
          },
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional tags for categorization and retrieval.',
          },
          'scope': {
            'type': 'string',
            'enum': ['project', 'user'],
            'description':
                'Where to store: project (default) or user (global).',
          },
        },
        'required': ['text'],
      },
      tier: ApprovalTier.write,
      execute: (args, cancelToken, onUpdate) async {
        final text = args['text'] as String? ?? '';
        if (text.trim().isEmpty) {
          return ToolExecutionResult.text('error: text is required');
        }
        final tags = (args['tags'] as List?)?.cast<String>() ?? const [];
        final scope = args['scope'] as String? ?? 'project';
        final entry = await controller.add(
          text: text.trim(),
          tags: tags,
          scope: scope,
        );
        return ToolExecutionResult.text(
          'saved memory (${entry.scope}): ${entry.displayLine}',
        );
      },
    ),
    AgentTool(
      name: 'memory_search',
      description:
          'Search long-term memory for relevant facts, preferences, '
          'or past decisions. Use proactively before tasks that might benefit '
          'from prior context.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'What to search for — a question, topic, or keyword.',
          },
        },
        'required': ['query'],
      },
      tier: ApprovalTier.read,
      execute: (args, cancelToken, onUpdate) async {
        final query = args['query'] as String? ?? '';
        if (query.trim().isEmpty) {
          return ToolExecutionResult.text('error: query is required');
        }
        final entries = await controller.search(query.trim());
        if (entries.isEmpty) {
          return ToolExecutionResult.text('no memories found for "$query"');
        }
        final lines = [for (final e in entries) '${e.scope}: ${e.displayLine}'];
        return ToolExecutionResult.text(
          '${entries.length} memor${entries.length == 1 ? 'y' : 'ies'} '
          'found:\n${lines.join('\n')}',
        );
      },
    ),
    AgentTool(
      name: 'memory_list',
      description:
          'List recent long-term memory entries. Useful to review '
          'what the agent already knows.',
      parameters: {
        'type': 'object',
        'properties': {
          'limit': {
            'type': 'integer',
            'description': 'Max entries to return (default 20).',
          },
        },
      },
      tier: ApprovalTier.read,
      execute: (args, cancelToken, onUpdate) async {
        final limit = args['limit'] as int? ?? 20;
        final entries = await controller.list(limit: limit);
        if (entries.isEmpty) {
          return ToolExecutionResult.text('no memories stored yet');
        }
        final lines = [for (final e in entries) '${e.scope}: ${e.displayLine}'];
        return ToolExecutionResult.text(
          '${entries.length} memor${entries.length == 1 ? 'y' : 'ies'}:\n'
          '${lines.join('\n')}',
        );
      },
    ),
  ];
}
