/// Pure helpers for the `/agents` tree panel (Variant B): status icons, row
/// descriptions, and TUI picker item building — extracted from
/// `agent_commands.dart` (a `part of`) so tests can import them directly.
library;

import '../task/subagent.dart';
import 'tui_repl.dart' show MenuItem;

/// The refusal line for a child that cannot receive a message, or null
/// when [handle] can receive (pure, testable).
String? subagentReceiveGuard(SubagentHandle? handle, String id) {
  if (handle == null) return 'no subagent "$id"';
  if (handle.status == SubagentStatus.failed ||
      handle.status == SubagentStatus.aborted) {
    return 'cannot send to ${handle.status.name} subagent "$id"';
  }
  return null;
}

/// One emoji per subagent status (the tree rows + the observe view header).
String agentStatusIcon(SubagentStatus status) => switch (status) {
  SubagentStatus.queued => '⏳',
  SubagentStatus.running => '🔄',
  SubagentStatus.idle => '⏸',
  SubagentStatus.completed => '✅',
  SubagentStatus.failed => '❌',
  SubagentStatus.aborted => '🛑',
};

/// One compact tree-row description: status · task preview · tokens · model.
String agentRowDescription(SubagentHandle handle) {
  final parts = <String>[handle.status.name];
  if (handle.task.isNotEmpty) {
    final task = handle.task.replaceAll('\n', ' ');
    parts.add(task.length > 40 ? '${task.substring(0, 40)}…' : task);
  }
  if (handle.tokens > 0) parts.add('${handle.tokens}t');
  if (handle.modelId != null) parts.add(handle.modelId!);
  return parts.join(' · ');
}

/// Builds the `/agents` TUI picker items: main orchestrator first, then one
/// row per child, plus the empty-state row when there are no children. A
/// positive `inboxCounts[id]` appends a `mail:N` pending-messages marker.
List<MenuItem> buildAgentTreeItems(
  List<SubagentHandle> children, {
  required String modelId,
  required int messageCount,
  Map<String, int> inboxCounts = const {},
}) {
  final mainInbox = inboxCounts['main'] ?? 0;
  final items = <MenuItem>[
    MenuItem(
      key: 'main',
      label: 'main (orchestrator)',
      description:
          '$modelId · $messageCount messages'
          '${mainInbox > 0 ? ' · mail:$mainInbox' : ''}',
    ),
    for (final h in children)
      MenuItem(
        key: 'child:${h.id}',
        label: '${agentStatusIcon(h.status)} ${h.agentType}:${h.id}',
        description:
            '${agentRowDescription(h)}'
            '${(inboxCounts[h.id] ?? 0) > 0 ? ' · mail:${inboxCounts[h.id]}' : ''}',
      ),
  ];
  if (children.isEmpty) {
    items.add(
      const MenuItem(
        key: 'noop',
        label: '(no subagents yet)',
        description: 'spawn one with the task tool',
      ),
    );
  }
  return items;
}

/// The live agents badge for the status line: up to [max] active children
/// with type, id, and elapsed seconds, then a `+N` overflow counter —
/// `bg:explore:A1(12s),+2`. Empty string when nothing is active.
String formatActiveAgentsBadge(
  List<SubagentHandle> handles, {
  int max = 3,
  DateTime? now,
}) {
  final active = handles
      .where(
        (h) =>
            h.status == SubagentStatus.queued ||
            h.status == SubagentStatus.running ||
            h.status == SubagentStatus.idle,
      )
      .toList();
  if (active.isEmpty) return '';
  final at = now ?? DateTime.now();
  final shown = active
      .take(max)
      .map((h) {
        final created = DateTime.tryParse(h.createdAt);
        final elapsed = created == null ? 0 : at.difference(created).inSeconds;
        return '${h.agentType}:${h.id}(${elapsed}s)';
      })
      .join(',');
  final overflow = active.length > max ? ',+${active.length - max}' : '';
  return 'bg:$shown$overflow';
}
