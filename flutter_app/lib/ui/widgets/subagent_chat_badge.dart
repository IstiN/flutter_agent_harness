// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'dart:math' as math;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The subagent family of one chat: the parent it belongs to (when known)
/// plus every subagent session hanging off that parent.
///
/// The parent's chat and this chat share one family, so the badge above the
/// composer resolves to the same set no matter which member is open.
final class SubagentFamily {
  const SubagentFamily({
    required this.parentId,
    required this.parent,
    required this.children,
  });

  /// The parent session id the family hangs off.
  final String parentId;

  /// The parent's chat list row, or `null` when the parent chat is gone
  /// (orphaned subagent).
  final ChatListEntry? parent;

  /// The family's subagent rows, most-recent first.
  final List<ChatListEntry> children;

  /// The children that are currently running.
  List<ChatListEntry> get running =>
      children.where(_entryIsRunning).toList(growable: false);
}

bool _entryIsRunning(ChatListEntry entry) =>
    entry.isStreaming ||
    entry.presence == ChatPresence.busy ||
    entry.presence == ChatPresence.live;

/// Resolves the subagent family of [sessionId], or `null` when the chat has
/// no subagent context to show (no children; lone orphan without a parent).
SubagentFamily? subagentFamilyFor(
  ChatListController controller,
  String sessionId,
) {
  final current = controller.localEntryFor(sessionId);
  final parentId =
      (current != null && current.isSubagent ? current.parentId : null) ??
          sessionId;
  final children = controller.subagentEntriesFor(parentId);
  if (children.isEmpty) return null;
  // Only a subagent chat gets the parent row; a parent chat IS the parent.
  final parent =
      current != null && current.isSubagent ? controller.localEntryFor(parentId) : null;
  // A lone orphan has no family context to show.
  if (current != null && current.isSubagent && parent == null) {
    if (children.length < 2) return null;
  }
  return SubagentFamily(parentId: parentId, parent: parent, children: children);
}

/// The compact badge above the composer: one account-tree icon with a count
/// badge of the family's RUNNING subagents (neutral when none are running).
/// Hidden entirely when the open chat has no subagent family.
///
/// Tapping it opens the anchored subagent picker popover so the subagent
/// chats stay out of the way until summoned.
class SubagentChatBadge extends StatelessWidget {
  const SubagentChatBadge({
    super.key,
    required this.controller,
    required this.sessionId,
    required this.onOpen,
  });

  final ChatListController controller;
  final String? sessionId;
  final Future<void> Function(ChatListEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final sid = sessionId;
    if (sid == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final family = subagentFamilyFor(controller, sid);
        if (family == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: _SubagentBadgeButton(family: family, onOpen: onOpen),
          ),
        );
      },
    );
  }
}

class _SubagentBadgeButton extends StatelessWidget {
  const _SubagentBadgeButton({required this.family, required this.onOpen});

  final SubagentFamily family;
  final Future<void> Function(ChatListEntry entry) onOpen;

  Future<void> _openPopover(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    await showChatSubagentPopover(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      bounds: Offset.zero & overlay.size,
      family: family,
      onOpen: onOpen,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final running = family.running.length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.hairline),
      ),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: InkWell(
          key: const ValueKey('chatSubagentBadge'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => unawaited(_openPopover(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: SizedBox(
              width: 20,
              height: 18,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Center(
                    child: Icon(Icons.account_tree_outlined, size: 14),
                  ),
                  if (running > 0)
                    Positioned(
                      right: -6,
                      top: -4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.accent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            '$running',
                            style: TextStyle(
                              fontSize: 9,
                              height: 1,
                              fontWeight: FontWeight.w700,
                              color: tokens.accentInk,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The anchored subagent picker popover: the parent chip («← poc») on top
/// when the open chat is a subagent, an Active | Done activity filter
/// (default Active) and one row per subagent — name, running dot, unread
/// count and relative last-activity.
Future<void> showChatSubagentPopover(
  BuildContext context, {
  required Rect anchor,
  required Rect bounds,
  required SubagentFamily family,
  required Future<void> Function(ChatListEntry entry) onOpen,
}) {
  return Navigator.of(context).push(_SubagentPopoverRoute(
    anchor: anchor,
    bounds: bounds,
    family: family,
    onOpen: onOpen,
  ));
}

class _SubagentPopoverRoute extends PopupRoute<void> {
  _SubagentPopoverRoute({
    required this.anchor,
    required this.bounds,
    required this.family,
    required this.onOpen,
  });

  final Rect anchor;
  final Rect bounds;
  final SubagentFamily family;
  final Future<void> Function(ChatListEntry entry) onOpen;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // Below the anchor by default, flipped above when it would overflow.
    const width = 300.0;
    const maxHeight = 380.0;
    final left = anchor.left.clamp(8.0, math.max(8.0, bounds.width - width - 8)).toDouble();
    var top = anchor.bottom + 6;
    if (top + maxHeight > bounds.height - 8) {
      top = math.max(8.0, anchor.top - maxHeight - 6);
    }
    return Stack(
      children: [
        // Outside tap closes without changing the chat.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: width,
          child: _SubagentPopoverPanel(family: family, onOpen: onOpen),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> reverseAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

class _SubagentPopoverPanel extends StatefulWidget {
  const _SubagentPopoverPanel({required this.family, required this.onOpen});

  final SubagentFamily family;
  final Future<void> Function(ChatListEntry entry) onOpen;

  @override
  State<_SubagentPopoverPanel> createState() => _SubagentPopoverPanelState();
}

class _SubagentPopoverPanelState extends State<_SubagentPopoverPanel> {
  // Default filter = Active; with nothing running, fall through to Done so
  // the picker never opens on an empty list.
  late bool _showDone = widget.family.running.isEmpty;

  void _setDone(bool value) => setState(() => _showDone = value);

  Future<void> _open(ChatListEntry entry) async {
    Navigator.of(context).pop();
    await widget.onOpen(entry);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final running = widget.family.children
        .where(_entryIsRunning)
        .toList(growable: false);
    final done = widget.family.children
        .where((entry) => !_entryIsRunning(entry))
        .toList(growable: false);
    final visible = _showDone ? done : running;
    return Material(
      elevation: 12,
      color: tokens.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tokens.hairline),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.family.parent != null)
              _SubagentPopoverRow(
                entry: widget.family.parent!,
                leading: const Text('←'),
                onTap: () => unawaited(_open(widget.family.parent!)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Row(
                children: [
                  _SubagentFilterPill(
                    key: const ValueKey('chatSubagentToggleActive'),
                    label: context.l10n.chatSubagentFilterActive(running.length),
                    selected: !_showDone,
                    onTap: () => _setDone(false),
                  ),
                  const SizedBox(width: 6),
                  _SubagentFilterPill(
                    key: const ValueKey('chatSubagentToggleDone'),
                    label: context.l10n.chatSubagentFilterDone(done.length),
                    selected: _showDone,
                    onTap: () => _setDone(true),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 6),
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final entry = visible[index];
                  return _SubagentPopoverRow(
                    entry: entry,
                    onTap: () => unawaited(_open(entry)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubagentFilterPill extends StatelessWidget {
  const _SubagentFilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? tokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: selected ? tokens.accent : tokens.hairline),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? tokens.accentInk : tokens.ink2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One picker row: name, the shared running dot, unread count and the
/// relative last-activity time.
class _SubagentPopoverRow extends StatelessWidget {
  const _SubagentPopoverRow({
    required this.entry,
    required this.onTap,
    this.leading,
  });

  final ChatListEntry entry;
  final VoidCallback onTap;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final colors = FahColors.of(context);
    return InkWell(
      key: ValueKey('chatSubagentEntry-${entry.id.value}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (leading != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: leading!,
              )
            else if (_entryIsRunning(entry))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChatRunningDot(entry: entry, colors: colors),
              ),
            Expanded(
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: tokens.ink1,
                ),
              ),
            ),
            if ((entry.unreadCount ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.accentSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    child: Text(
                      '${entry.unreadCount ?? 0}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: tokens.accentInk,
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                chatListRelativeTime(context, entry.lastActivity),
                style: TextStyle(fontSize: 10, color: tokens.ink3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
