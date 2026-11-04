// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show ChatRunningDot;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// One chip of the subagent switcher above the composer.
final class SubagentChipData {
  const SubagentChipData({
    required this.entry,
    required this.label,
    required this.current,
  });

  /// The session the chip opens.
  final ChatListEntry entry;

  /// The chip text: the session's display name, or `'← parentName'` for
  /// the parent chip.
  final String label;

  /// Whether this chip IS the currently open chat (accent-tinted).
  final bool current;
}

/// The subagent family chips for the open chat [sessionId], against the
/// chat projection (subagent sessions owner pass).
///
/// - A PARENT chat open → one chip per subagent session, no parent chip.
/// - A SUBAGENT chat open → its sibling chips plus the parent chip first
///   ('← poc'), and the CURRENT session's chip flagged for the accent
///   highlight.
/// - No subagent family (no children) → no chips, no row. An orphaned
///   subagent (parent absent from the projection) keeps its sibling chips
///   but has no way-back chip — the parent chat no longer exists.
List<SubagentChipData> subagentChipsFor(
  ChatListController controller,
  String sessionId,
) {
  final current = controller.localEntryFor(sessionId);
  final parentId =
      (current != null && current.isSubagent ? current.parentId : null) ??
      sessionId;
  final children = controller.subagentEntriesFor(parentId);
  if (children.isEmpty) return const [];
  final parent = controller.localEntryFor(parentId);
  // A lone orphan — no parent chat to return to, no siblings to hop to —
  // has no family context to show.
  if (current != null &&
      current.isSubagent &&
      parent == null &&
      children.length < 2) {
    return const [];
  }
  return [
    if (current != null && current.isSubagent && parent != null)
      SubagentChipData(
        entry: parent,
        label: '← ${parent.title}',
        current: false,
      ),
    for (final child in children)
      SubagentChipData(
        entry: child,
        label: child.title,
        current: child.id.value == sessionId,
      ),
  ];
}

/// The subagent switcher docked ABOVE the composer input (subagent
/// sessions owner pass): one compact chip per subagent session of the
/// open chat's family — name, running dot, unread count — every chip a
/// tap target that opens that session's chat through the host's open
/// flow. The row replaces the old header badge and picker popover: the
/// context stays visible while the user types.
class SubagentChatSwitcher extends StatelessWidget {
  const SubagentChatSwitcher({
    super.key,
    required this.controller,
    required this.sessionId,
    required this.onOpen,
  });

  /// The chat projection behind the chips (live + persisted rows with
  /// pin/unread state applied).
  final ChatListController controller;

  /// The currently open local session id (null renders no row).
  final String? sessionId;

  /// The host's open flow — the SAME one a chat list row uses.
  final Future<void> Function(ChatListEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final id = sessionId;
    if (id == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final chips = subagentChipsFor(controller, id);
        if (chips.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final chip in chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _SubagentSwitcherChip(
                      data: chip,
                      onTap: () => onOpen(chip.entry),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SubagentSwitcherChip extends StatelessWidget {
  const _SubagentSwitcherChip({required this.data, required this.onTap});

  final SubagentChipData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final entry = data.entry;
    final unread = entry.unreadCount ?? 0;
    return Material(
      key: ValueKey('chatSubagentChip-${entry.id.value}'),
      color: data.current ? tokens.accentSoft : tokens.surface2,
      shape: StadiumBorder(
        side: BorderSide(
          color: data.current
              ? tokens.accent.withValues(alpha: .45)
              : tokens.hairline,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.presence != null || entry.isStreaming) ...[
                ChatRunningDot(entry: entry, colors: FahColors.of(context), size: 7),
                const SizedBox(width: 6),
              ],
              Text(
                data.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: data.current ? tokens.accent : tokens.ink1,
                  fontSize: 12,
                  fontWeight: data.current ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              if (unread > 0) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$unread',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: tokens.accentInk,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
