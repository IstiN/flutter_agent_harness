import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/widgets/rename_session_dialog.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show SessionMetadata;
import 'package:path/path.dart' as p;

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
  void didUpdateWidget(covariant SidebarSessionsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The wide shell loads the names store lazily — re-subscribe when it
    // arrives (and when the manager instance is swapped).
    if (oldWidget.manager != widget.manager) {
      oldWidget.manager.removeListener(_onChanged);
      widget.manager.addListener(_onChanged);
    }
    if (oldWidget.sessionNamesStore != widget.sessionNamesStore) {
      oldWidget.sessionNamesStore?.removeListener(_onChanged);
      widget.sessionNamesStore?.addListener(_onChanged);
    }
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
          lastUpdatedAt: session.lastUpdatedAt,
          cwd: session.service.env.sessionCwd,
          live: session,
        ),
      for (final metadata in widget.persistedSessions)
        if (!liveIds.contains(metadata.id))
          _SessionEntry(
            id: metadata.id,
            createdAt: metadata.createdAt,
            lastUpdatedAt: metadata.lastUpdatedAt ?? metadata.createdAt,
            cwd: metadata.cwd,
            persisted: metadata,
          ),
    ]..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
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
                        SessionTile(
                          title: _titleFor(entry),
                          subtitle: sessionTileSubtitle(entry.lastUpdatedAt),
                          cwd: sessionTileCwdLabel(entry.cwd),
                          isActive: widget.manager.active?.id == entry.id,
                          onTap: () => _openEntry(entry),
                          onMenu: (anchor) => _showSessionMenu(entry, anchor),
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
  /// Groups by last activity so recently updated sessions bubble up.
  String _groupLabel(_SessionEntry entry) {
    final updated = entry.lastUpdatedAt;
    final now = DateTime.now();
    final diff = now.difference(updated);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) {
      final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[updated.weekday - 1];
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
    return '${months[updated.month - 1]} ${updated.day}';
  }

  /// The 3-dot tile menu: rename (via the shared rename dialog, like the
  /// CLI `/rename`) and delete (with confirmation). Works for live and
  /// persisted-only sessions alike — the implementation is shared with the
  /// mobile chat sheet's sessions drawer (see [showSessionActionsMenu]).
  Future<void> _showSessionMenu(_SessionEntry entry, Rect anchor) =>
      showSessionActionsMenu(
        context,
        anchor: anchor,
        manager: widget.manager,
        namesStore: widget.sessionNamesStore,
        sessionId: entry.id,
        createdAt: entry.createdAt,
        live: entry.live,
        persisted: entry.persisted,
      );

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
                          lastUpdatedAt: session.lastUpdatedAt,
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
    required this.lastUpdatedAt,
    this.cwd,
    this.live,
    this.persisted,
  });

  final String id;
  final DateTime createdAt;

  /// When the session was last modified. Drives sorting and the "Today /
  /// Yesterday / May 7" group headers so active sessions stay on top.
  final DateTime lastUpdatedAt;

  /// The session's working directory at creation time (CLI sessions store
  /// the host cwd; macOS app sessions store the Fa sandbox root). Drives
  /// the folder label rendered next to the title so the user can tell at
  /// a glance which project/sandbox each session belongs to.
  final String? cwd;
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

/// Short timestamp for a session tile's subtitle (e.g. "12:34 PM" or
/// "May 7"). Shared by the wide sidebar and the mobile sessions drawer so
/// both render an identical row. Pass the session's last activity time to
/// reflect recent updates.
String sessionTileSubtitle(DateTime updated) {
  final now = DateTime.now();
  final diff = now.difference(updated);
  if (diff.inDays == 0) {
    // Today: show time.
    final h = updated.hour == 0
        ? 12
        : (updated.hour > 12 ? updated.hour - 12 : updated.hour);
    final m = updated.minute.toString().padLeft(2, '0');
    final ampm = updated.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[updated.weekday - 1];
  }
  const months = [
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
  return '${months[updated.month - 1]} ${updated.day}';
}

/// The folder label rendered next to the title — the last path segment of
/// the session's working directory so the user can scan which project each
/// session belongs to at a glance. Null when the cwd is missing or looks
/// like an unscoped sandbox root (no useful basename).
String? sessionTileCwdLabel(String? cwd) {
  if (cwd == null || cwd.isEmpty) return null;
  final name = p.basename(cwd);
  if (name.isEmpty || name == '/' || name == '.') return null;
  return name;
}

/// The session tile's 3-dot menu, shared by the wide sidebar and the
/// mobile chat sheet's sessions drawer: rename (via the shared rename
/// dialog, like the CLI `/rename`) and delete (with confirmation). Works
/// for live and persisted-only sessions alike. [onDeleted] fires after a
/// successful delete so hosts listing on-disk sessions can resync.
Future<void> showSessionActionsMenu(
  BuildContext context, {
  required Rect anchor,
  required FlutterSessionManager manager,
  required SessionNamesStore? namesStore,
  required String sessionId,
  required DateTime createdAt,
  FlutterManagedSession? live,
  SessionMetadata? persisted,
  VoidCallback? onDeleted,
}) async {
  final l10n = context.l10n;
  final overlayBox =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(anchor, Offset.zero & overlayBox.size),
    items: [
      PopupMenuItem(
        value: 'rename',
        child: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 16),
            const SizedBox(width: 8),
            Text(l10n.sidebarRenameDialogTitle),
          ],
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Row(
          children: [
            const Icon(Icons.delete_outline, size: 16),
            const SizedBox(width: 8),
            Text(l10n.sidebarDelete),
          ],
        ),
      ),
    ],
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case 'rename':
      final store = namesStore;
      if (store == null) return;
      await showRenameSessionDialog(
        context,
        store: store,
        sessionId: sessionId,
        createdAt: createdAt,
      );
    case 'delete':
      await _deleteSession(
        context,
        manager: manager,
        namesStore: namesStore,
        sessionId: sessionId,
        live: live,
        persisted: persisted,
        onDeleted: onDeleted,
      );
  }
}

Future<void> _deleteSession(
  BuildContext context, {
  required FlutterSessionManager manager,
  required SessionNamesStore? namesStore,
  required String sessionId,
  required FlutterManagedSession? live,
  required SessionMetadata? persisted,
  VoidCallback? onDeleted,
}) async {
  final l10n = context.l10n;
  final title = namesStore?.titleFor(sessionId);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sidebarDeleteSessionTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title ??
                l10n.sidebarDeletePersistedContent(sessionId.substring(0, 8)),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(l10n.sidebarDeleteSessionContent),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.sidebarDelete),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await manager.deleteSession(sessionId, metadata: persisted);
    onDeleted?.call();
    // Deleting the active (and only) session must not strand the shell on
    // the "No active session" placeholder — mint a fresh one on the same
    // connection, like the chat screen's ensureActiveSession path.
    if (manager.active == null) {
      final service = live?.service;
      final config = service?.configForClone;
      if (service != null && config != null) {
        await manager.ensureActiveSession(
          config: config,
          serviceFactory: () async => service.clone(),
        );
      }
    }
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.sidebarDeleteSessionFailed(error.toString())),
        ),
      );
    }
  }
}

/// One row in a session list — the wide sidebar and the mobile sessions
/// drawer render the SAME tile: an active dot, the title, a relative-time
/// subtitle, the working-folder label, and a 3-dot actions menu.
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.isActive,
    this.cwd,
    required this.onTap,
    this.onMenu,
  });

  final String title;
  final String subtitle;
  final String? cwd;

  /// Distinct, monospace basename of the session's working directory.
  /// Null when the cwd is unknown or the personal (unscoped) sandbox.
  final bool isActive;
  final VoidCallback onTap;

  /// Called with the menu button's global rect when the 3-dot menu button
  /// is tapped (the popup anchors to it). When null, the menu is hidden.
  final ValueChanged<Rect>? onMenu;

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
                      if (cwd != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 11,
                              color: colors.dim.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                cwd!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.dim.withValues(alpha: 0.6),
                                  fontSize: 11,
                                  fontFamily: 'JetBrainsMono',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // 3-dot menu button (visible on the active tile or on hover).
                if (onMenu != null)
                  InkWell(
                    onTap: () {
                      final box = context.findRenderObject()! as RenderBox;
                      onMenu!(box.localToGlobal(Offset.zero) & box.size);
                    },
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
