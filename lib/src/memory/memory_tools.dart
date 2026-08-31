/// Agent tools for durable cross-session memory: `memory_add`, `memory_search`,
/// `memory_list`. Registered when a [MemoryController] is available.
library;

import 'package:flutter_agent_memory/flutter_agent_memory.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'memory_controller.dart';

/// Returns the three memory tools backed by [controller].
/// `memory_add` is write-tier; `memory_search` and `memory_list` are read-tier.
/// [onChanged] fires after every successful `memory_add` — hosts use it to
/// refresh the prompt's cached `<memory>` section.
List<AgentTool> memoryTools(
  MemoryController? controller, {
  void Function()? onChanged,
}) {
  if (controller == null) return const [];
  return [
    _memoryAddTool(controller, onChanged),
    _memorySearchTool(controller),
    _memoryListTool(controller),
    _memoryDeleteTool(controller, onChanged),
  ];
}

/// `memory_delete` — remove a stale or wrong entry from long-term memory.
AgentTool _memoryDeleteTool(
  MemoryController controller,
  void Function()? onChanged,
) {
  return AgentTool(
    name: 'memory_delete',
    description:
        'Delete a stale, wrong, or obsolete entry from long-term memory '
        'by id. Prefer deleting over rewriting when the fact no longer '
        'holds at all.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'The memory entry id (from memory_list/search).',
        },
        'scope': {
          'type': 'string',
          'enum': ['project', 'user'],
          'description': 'Restrict deletion to one scope; default scans both.',
        },
      },
      'required': ['id'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) async {
      final id = args['id'] as String? ?? '';
      if (id.trim().isEmpty) {
        return ToolExecutionResult.text('error: id is required');
      }
      final scope = args['scope'] as String?;
      final deletedScope = await controller.delete(id.trim(), scope: scope);
      if (deletedScope == null) {
        return ToolExecutionResult.text('error: no memory entry with id $id');
      }
      onChanged?.call();
      return ToolExecutionResult.text('deleted memory ($deletedScope): $id');
    },
  );
}

/// `memory_add` — store a durable fact in long-term memory.
AgentTool _memoryAddTool(
  MemoryController controller,
  void Function()? onChanged,
) {
  return AgentTool(
    name: 'memory_add',
    // The policy text lives in the flutter_agent_memory repo
    // (docs/memory/memory_add_policy.md — durable facts only, the
    // supersede rule for solved problems, project scope = PUBLIC via
    // git). One source of truth; a sync test in the package keeps the
    // constant identical to the document.
    description: MemoryPolicy.memoryAddPolicy,
    parameters: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': 'The memory content — a concise, self-contained fact.',
        },
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Optional tags for categorization and retrieval.',
        },
        'scope': {
          'type': 'string',
          'enum': ['project', 'user'],
          'description': 'Where to store: project (default) or user (global).',
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
      onChanged?.call();
      return ToolExecutionResult.text(
        'saved memory (${entry.scope}): ${entry.displayLine}',
      );
    },
  );
}

/// `memory_search` — search long-term memory for relevant facts.
AgentTool _memorySearchTool(MemoryController controller) {
  return AgentTool(
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
          'description': 'What to search for — a question, topic, or keyword.',
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
  );
}

/// `memory_list` — list recent long-term memory entries.
AgentTool _memoryListTool(MemoryController controller) {
  return AgentTool(
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
  );
}
