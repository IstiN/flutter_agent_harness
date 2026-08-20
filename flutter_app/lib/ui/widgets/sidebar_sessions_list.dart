import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show SessionMetadata;

/// The sessions list for the wide-screen sidebar: shows every live session
/// (from [manager]) plus persisted on-disk sessions not currently live
/// ([persistedSessions]) with its derived or custom title, the active
/// session highlighted with a teal dot, and a "New session" button at the
/// top. Tapping a persisted-only session opens it from disk via
/// [onOpenPersisted].
///
/// When [collapsed] is true the list degrades to a centered column of dots
/// (active = teal, inactive = dim) with a tooltip per dot — the icon-rail
/// companion to the collapsed [WideLayoutShell] sidebar.
class SidebarSessionsList extends StatefulWidget {
  const SidebarSessionsList({
    super.key,
    required this.manager,
    this.sessionNamesStore,
    this.onNewSession,
    this.onSessionTap,
    this.persistedSessions = const [],
    this.onOpenPersisted,
    this.collapsed = false,
  });

  final FlutterSessionManager manager;
  final SessionNamesStore? sessionNamesStore;
  final VoidCallback? onNewSession;

  /// Called after a session is tapped and [manager.switchTo] has run.
  final VoidCallback? onSessionTap;

  /// On-disk sessions (newest first). Entries not live in [manager] render
  /// below the live ones and open from disk on tap.
  final List<SessionMetadata> persistedSessions;

  /// Opens a persisted-only session from disk (see [persistedSessions]).
  final ValueChanged<SessionMetadata>? onOpenPersisted;

  /// When true the list renders as a compact column of session dots.
  final bool collapsed;

  @override
  State<SidebarSessionsList> createState() => _SidebarSessionsListState();
}

class _SidebarSessionsListState extends State<SidebarSessionsList> {
  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onChanged);
    widget.sessionNamesStore?.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onChanged);
    widget.sessionNamesStore?.removeListener(_onChanged);
    super.dispose();
  }

  String _titleFor(_SessionEntry entry) {
    return widget.sessionNamesStore?.titleFor(entry.id) ??
        derivedSessionTitle(context, id: entry.id, createdAt: entry.createdAt);
  }

  /// Short timestamp for the session subtitle (e.g. "12:34 PM" or "May 7").
  String _subtitleFor(_SessionEntry entry) {
    final created = entry.createdAt;
    final now = DateTime.now();
    final diff = now.difference(created);
    if (diff.inDays == 0) {
      // Today: show time.
      final h = created.hour == 0
          ? 12
          : (created.hour > 12 ? created.hour - 12 : created.hour);
      final m = created.minute.toString().padLeft(2, '0');
      final ampm = created.hour >= 12 ? 'PM' : 'AM';
      return '$h:$m $ampm';
    }
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) {
      final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[created.weekday - 1];
    }
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[created.month - 1]} ${created.day}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    if (widget.collapsed) return _buildCollapsed(colors);
    return _buildExpanded(colors);
  }

  // ---------------------------------------------------------------------------
  // Expanded
  // ---------------------------------------------------------------------------

  Widget _buildExpanded(FahColors colors) {
    final live = widget.manager.sessions;
    final liveIds = live.map((s) => s.id).toSet();
    // Live sessions plus the persisted ones not currently open — the full
    // on-disk history stays reachable from the sidebar, like the mobile
    // chat sheet's persisted tail.
    final entries = <_SessionEntry>[
      for (final session in live)
        _SessionEntry(
          id: session.id,
          createdAt: session.createdAt,
          live: session,
        ),
      for (final metadata in widget.persistedSessions)
        if (!liveIds.contains(metadata.id))
          _SessionEntry(
            id: metadata.id,
            createdAt: metadata.createdAt,
            persisted: metadata,
          ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final grouped = _groupEntriesByDate(entries);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Text(
                context.l10n.sidebarSessionsHeader.toUpperCase(),
                style: TextStyle(
                  color: colors.dim,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: widget.onNewSession,
                tooltip: context.l10n.sidebarNewSessionTooltip,
                iconSize: 20,
                color: colors.dim,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
        Expanded(
          child: grouped.isEmpty
              ? const SizedBox.shrink()
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final group in grouped) ...[
                      _DateHeader(label: group.label, colors: colors),
                      for (final entry in group.entries)
                        _SessionTile(
                          title: _titleFor(entry),
                          subtitle: _subtitleFor(entry),
                          isActive: widget.manager.active?.id == entry.id,
                          onTap: () => _openEntry(entry),
                          onMenu: entry.live != null
                              ? () => _showSessionMenu(entry.live!)
                              : null,
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  void _openEntry(_SessionEntry entry) {
    final live = entry.live;
    if (live != null) {
      widget.manager.switchTo(live.id);
      widget.onSessionTap?.call();
      return;
    }
    final persisted = entry.persisted;
    if (persisted != null) widget.onOpenPersisted?.call(persisted);
  }

  /// Groups entries by date headers (Today, Yesterday, May 7, ...).
  List<_SessionGroup> _groupEntriesByDate(List<_SessionEntry> entries) {
    if (entries.isEmpty) return const [];
    final groups = <String, List<_SessionEntry>>{};
    final order = <String>[];
    for (final entry in entries) {
      final label = _groupLabel(entry);
      if (!groups.containsKey(label)) {
        groups[label] = [];
        order.add(label);
      }
      groups[label]!.add(entry);
    }
    return [
      for (final label in order)
        _SessionGroup(label: label, entries: groups[label]!),
    ];
  }

  /// Date group label for an entry: "Today", "Yesterday", or a date.
  String _groupLabel(_SessionEntry entry) {
    final created = entry.createdAt;
    final now = DateTime.now();
    final diff = now.difference(created);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) {
      final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[created.weekday - 1];
    }
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[created.month - 1]} ${created.day}';
  }

  void _showSessionMenu(FlutterManagedSession session) {
    // Placeholder: rename/delete menu.
    // Will be wired to the real session manager actions.
  }

  // ---------------------------------------------------------------------------
  // Collapsed (icon rail)
  // ---------------------------------------------------------------------------

  Widget _buildCollapsed(FahColors colors) {
    final sessions = widget.manager.sessions;
    return Column(
      children: [
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: widget.onNewSession,
          tooltip: context.l10n.sidebarNewSessionTooltip,
          iconSize: 18,
          color: colors.dim,
          padding: const EdgeInsets.only(top: 8),
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const SizedBox.shrink()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final isActive = widget.manager.active?.id == session.id;
                    return Tooltip(
                      message: _titleFor(
                        _SessionEntry(
                          id: session.id,
                          createdAt: session.createdAt,
                          live: session,
                        ),
                      ),
                      child: GestureDetector(
                        onTap: () {
                          widget.manager.switchTo(session.id);
                          widget.onSessionTap?.call();
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          height: 10,
                          alignment: Alignment.center,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: isActive
                                  ? colors.teal
                                  : colors.dim.withValues(alpha: 0.35),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// One row in the expanded list: a live [FlutterManagedSession] or a
/// persisted-only [SessionMetadata] still sitting on disk.
final class _SessionEntry {
  const _SessionEntry({
    required this.id,
    required this.createdAt,
    this.live,
    this.persisted,
  });

  final String id;
  final DateTime createdAt;
  final FlutterManagedSession? live;
  final SessionMetadata? persisted;
}

/// A group of sessions under one date header.
final class _SessionGroup {
  const _SessionGroup({required this.label, required this.entries});

  final String label;
  final List<_SessionEntry> entries;
}

/// A small date header label (Today, Yesterday, May 7, ...).
class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label, required this.colors});

  final String label;
  final FahColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      child: Text(
        label,
        style: TextStyle(
          color: colors.dim,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.title,
    required this.subtitle,
    required this.isActive,
    required this.onTap,
    this.onMenu,
  });

  final String title;
  final String subtitle;
  final bool isActive;
  final VoidCallback onTap;

  /// Called when the 3-dot menu button is tapped. When null, the menu is hidden.
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: isActive
            ? (isLight ? const Color(0xFFEEF2FF) : colors.panelAlt)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (isActive)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: isLight ? colors.indigo : colors.teal,
                      shape: BoxShape.circle,
                    ),
                  )
                else
                  const SizedBox(width: 8),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isActive ? colors.text : colors.dim,
                          fontSize: 13,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.dim.withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 3-dot menu button (visible on the active tile or on hover).
                if (onMenu != null)
                  InkWell(
                    onTap: onMenu,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.more_horiz,
                        size: 14,
                        color: colors.dim.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
