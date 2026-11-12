// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show chatListRelativeTime;
import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:fa/ui/chats/messenger_list_row_style.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The Local section's folder-first navigation (Telegram pattern): level 1
/// is the standard [logo][name] folder list (persisted sessions grouped by
/// cwd, most-recent first); level 2 opens the avatar-only strip (capsule on
/// the drilled folder) with the Telegram-style session list beside it. Session state rides [ChatListController.localEntries]
/// (FlutterSessionManager's single-flight listing) — this panel only
/// projects it. Opening a session stays the shell's existing open flow.
class LocalSessionsPanel extends StatefulWidget {
  const LocalSessionsPanel({
    super.key,
    required this.controller,
    required this.selectedFolderId,
    required this.onSelectFolder,
    required this.selectedSessionId,
    required this.onOpenSession,
    this.onNew,
    this.onCollapse,
    this.onSettings,
    this.compact = false,
    this.iconResolver,
  });

  static const double sessionRowPitch = 70;
  static const double avatarSize = 46;

  // The level-2 avatar strip (Telegram pattern, owner pass): a
  // ~70pt avatar-only column on the left of the sidebar content; avatars
  // Ø~50 circles on the 70pt pitch; the selected
  // folder wears an accent capsule bar (~6x51, fully rounded) flush
  // against the strip's LEFT edge and re-renders its avatar as a rounded
  // square (radius ~25% of the size). No name labels at this level.
  static const double stripWidth = 70;
  static const double stripItemPitch = 70;
  static const double stripAvatarSize = 50;
  static const double stripCapsuleWidth = 6;
  static const double stripCapsuleHeight = 51;

  final ChatListController controller;
  final bool compact;

  /// The open folder's cwd ('' = Personal), null = the folder list.
  final String? selectedFolderId;
  final ValueChanged<String?> onSelectFolder;

  /// The shell's ONE selected session id (pending wins, then live, then
  /// manager slot) — the same value the sidebar rows highlight with.
  final String? selectedSessionId;
  final ValueChanged<ChatListEntry> onOpenSession;
  final VoidCallback? onNew;
  final VoidCallback? onCollapse;
  final VoidCallback? onSettings;
  final FolderIconResolver? iconResolver;

  @override
  State<LocalSessionsPanel> createState() => _LocalSessionsPanelState();
}

class _LocalSessionsPanelState extends State<LocalSessionsPanel> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'local-sessions-search');
  var _query = '';
  var _searchExpanded = false;

  bool get _searchShown =>
      _searchExpanded ||
      _searchController.text.trim().isNotEmpty ||
      _searchFocus.hasFocus;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchStateChanged);
    _searchFocus.addListener(_onSearchStateChanged);
  }

  void _onSearchStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant LocalSessionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedFolderId != widget.selectedFolderId) {
      _searchController.clear();
      _searchFocus.unfocus();
      _query = '';
      _searchExpanded = false;
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchStateChanged);
    _searchFocus.removeListener(_onSearchStateChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _revealSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() {
      _query = '';
      _searchExpanded = false;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  bool _searchCollapsed(LocalSessionFolder? openFolder) =>
      (widget.compact || openFolder != null) && !_searchShown;

  VoidCallback? _searchRevealCallback(LocalSessionFolder? openFolder) =>
      (widget.compact || openFolder != null) && !_searchShown
      ? _revealSearch
      : null;

  VoidCallback? _searchCloseCallback(LocalSessionFolder? openFolder) =>
      (widget.compact || openFolder != null) && _searchShown
      ? _closeSearch
      : null;

  Widget? _headerLeading(LocalSessionFolder? openFolder, FahColors colors) {
    if (openFolder == null) return null;
    return IconButton(
      key: const ValueKey('localFolderBack'),
      tooltip: context.l10n.localFolderBack,
      onPressed: () => widget.onSelectFolder(null),
      icon: const Icon(Icons.chevron_left_rounded),
      iconSize: 26,
      color: colors.text,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildHeader(LocalSessionFolder? openFolder, FahColors colors) {
    return MessengerSectionHeader(
      title: openFolder?.name ?? context.l10n.wideNavLocal,
      searchController: _searchController,
      searchFocusNode: _searchFocus,
      searchHint: openFolder == null
          ? context.l10n.localFoldersSearchHint
          : context.l10n.sidebarSearchHint,
      onSearch: (query) => setState(() => _query = query),
      searchCollapsed: _searchCollapsed(openFolder),
      onSearchReveal: _searchRevealCallback(openFolder),
      onSearchClose: _searchCloseCallback(openFolder),
      onProfile: null,
      onSettings: widget.onSettings,
      onNew: widget.onNew,
      newButtonKey: const ValueKey('localNewButton'),
      compact: widget.compact,
      onCollapse: widget.onCollapse,
      leading: _headerLeading(openFolder, colors),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final allFolders = groupLocalSessionFolders(
          widget.controller.localEntries,
          personalName: context.l10n.sessionFolderPersonal,
        );
        final folders = widget.selectedFolderId == null
            ? rankSessionEntries(
                allFolders,
                _query,
                (folder) => (
                  title: folder.name,
                  id: folder.id,
                  cwd: folder.id,
                  updatedAt:
                      folder.latestActivity ??
                      DateTime.fromMillisecondsSinceEpoch(0),
                ),
              )
            : allFolders;
        final openFolder = widget.selectedFolderId == null
            ? null
            : allFolders
                  .where((folder) => folder.id == widget.selectedFolderId)
                  .firstOrNull;
        final visibleSessions = openFolder == null
            ? const <ChatListEntry>[]
            : rankSessionEntries(
                openFolder.sessions,
                _query,
                (entry) => (
                  title: entry.title,
                  id: entry.id.value,
                  cwd: entry.folderPath,
                  updatedAt: entry.lastActivity ?? entry.createdAt,
                ),
              );
        return MessengerGlassPanel(
          compact: widget.compact,
          underlayKey: const ValueKey('localChromeUnderlay'),
          header: _buildHeader(openFolder, colors),
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The strip is NOT animated (owner pass): switching
              // must not jitter the logos — only the content pane
              // slides/fades.
              if (openFolder != null)
                _FolderStrip(
                  folders: folders,
                  selectedFolderId: widget.selectedFolderId,
                  iconResolver: widget.iconResolver,
                  onOpen: widget.onSelectFolder,
                ),
              Expanded(
                // Only the content pane animates (200ms
                // easeInOutCubic slide+fade; instant under
                // reduce-motion). Keys stay stable after settle.
                child: AnimatedSwitcher(
                  duration: FaMotion.duration(
                    context,
                    const Duration(milliseconds: 200),
                  ),
                  switchInCurve: Curves.easeInOutCubic,
                  switchOutCurve: Curves.easeInOutCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0.08, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey('localContent-${openFolder?.id ?? 'list'}'),
                    child: openFolder == null
                        ? (allFolders.isEmpty
                              ? Center(
                                  child: Text(
                                    context.l10n.localFoldersEmpty,
                                    style: TextStyle(
                                      color: colors.dim,
                                      fontSize: 13,
                                    ),
                                  ),
                                )
                              : folders.isEmpty
                              ? sessionSearchEmptyState(
                                  context,
                                  colors,
                                  _query,
                                  _clearSearch,
                                  noMatches: context.l10n.listSearchNoMatches(
                                    _query,
                                  ),
                                )
                              : _FolderList(
                                  folders: folders,
                                  iconResolver: widget.iconResolver,
                                  onOpen: widget.onSelectFolder,
                                  bottomReserve: widget.compact
                                      ? MessengerFloatingDockInsets.bottomOf(
                                          context,
                                        )
                                      : 0,
                                ))
                        : visibleSessions.isEmpty && _query.trim().isNotEmpty
                        ? sessionSearchEmptyState(
                            context,
                            colors,
                            _query,
                            _clearSearch,
                            noMatches: context.l10n.listSearchNoMatches(_query),
                          )
                        : LocalFolderSessionList(
                            bottomReserve: widget.compact
                                ? MessengerFloatingDockInsets.bottomOf(context)
                                : 0,
                            sessions: visibleSessions,
                            selectedSessionId: widget.selectedSessionId,
                            onOpenSession: widget.onOpenSession,
                            onVisibleSession:
                                widget.controller.warmVisibleLocalEntry,
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Level 1: the standard [logo][name] folder list — Telegram-style rows
/// (70pt pitch, Ø50 avatar, name + session-count meta) that drill into
/// the avatar-strip + session-list view when tapped.
class _FolderList extends StatelessWidget {
  const _FolderList({
    required this.folders,
    required this.iconResolver,
    required this.onOpen,
    this.bottomReserve = 0,
  });

  final List<LocalSessionFolder> folders;
  final FolderIconResolver? iconResolver;
  final ValueChanged<String> onOpen;

  /// Extra scroll padding under the floating phone dock (compact hosts
  /// only; desktop passes 0 and keeps the plain 4pt inset).
  final double bottomReserve;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ListView.builder(
      key: const ValueKey('localFoldersList'),
      padding: EdgeInsets.only(
        top: MessengerGlassBodyInsets.topOf(context) + 4,
        bottom: 4 + bottomReserve,
      ),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return SizedBox(
          key: ValueKey('localFolderRow-${folder.id}'),
          height: LocalSessionsPanel.stripItemPitch,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onOpen(folder.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    FutureBuilder<MemoryImage?>(
                      future: iconResolver?.resolve(folder.id),
                      builder: (context, snapshot) => FolderAvatar(
                        seed: folder.avatarSeed,
                        label: folder.name,
                        size: LocalSessionsPanel.stripAvatarSize,
                        image: snapshot.data,
                        circle: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            folder.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: tokens.ink1,
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (folder.id.isNotEmpty)
                            Text(
                              folderPathMeta(folder.id),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: tokens.ink3,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Level 2 (a folder is open): the Telegram avatar-only strip — one Ø50
/// folder avatar per [LocalSessionsPanel.stripItemPitch] cell, no labels.
/// Level 1 (nothing open) is the standard [logo][name] list.
/// The selected folder paints the accent capsule flush to the strip's
/// left edge and squares its avatar (radius ~25%); a tap opens the
/// folder's session list beside the strip.
class _FolderStrip extends StatelessWidget {
  const _FolderStrip({
    required this.folders,
    required this.selectedFolderId,
    required this.onOpen,
    this.iconResolver,
  });

  final List<LocalSessionFolder> folders;
  final String? selectedFolderId;
  final FolderIconResolver? iconResolver;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      key: const ValueKey('localFoldersStrip'),
      width: LocalSessionsPanel.stripWidth,
      child: folders.isEmpty
          ? const SizedBox.shrink()
          // The owner clip: the strip never paints a scrollbar thumb —
          // scrolling stays on wheel/drag (scrollbars disabled, everything
          // else from the ambient behavior).
          : ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: ListView.builder(
                padding: EdgeInsets.only(
                  top: MessengerGlassBodyInsets.topOf(context) + 4,
                  bottom: 4,
                ),
                itemCount: folders.length,
                itemBuilder: (context, index) {
                  final folder = folders[index];
                  final selected = folder.id == selectedFolderId;
                  return SizedBox(
                    key: ValueKey('localFolder-${folder.id}'),
                    width: LocalSessionsPanel.stripWidth,
                    height: LocalSessionsPanel.stripItemPitch,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => onOpen(folder.id),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            FutureBuilder<MemoryImage?>(
                              future: iconResolver?.resolve(folder.id),
                              builder: (context, snapshot) => FolderAvatar(
                                seed: folder.avatarSeed,
                                label: folder.name,
                                size: LocalSessionsPanel.stripAvatarSize,
                                image: snapshot.data,
                                circle: !selected,
                                radiusFactor: selected ? 0.25 : 0.28,
                              ),
                            ),
                            if (selected)
                              Positioned(
                                left: 0,
                                top:
                                    (LocalSessionsPanel.stripItemPitch -
                                        LocalSessionsPanel.stripCapsuleHeight) /
                                    2,
                                child: Container(
                                  key: const ValueKey(
                                    'localFolderSelectedCapsule',
                                  ),
                                  width: LocalSessionsPanel.stripCapsuleWidth,
                                  height: LocalSessionsPanel.stripCapsuleHeight,
                                  decoration: BoxDecoration(
                                    color: tokens.accent,
                                    borderRadius: BorderRadius.circular(
                                      LocalSessionsPanel.stripCapsuleWidth / 2,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Level 2 — the Telegram-style session list for ONE folder: ~70pt rows,
/// Ø46 letter avatar, 14pt semibold name, top-right last-activity time,
/// 12–13pt preview line, running/unread badges, 1px hairlines, and an
/// accent rounded highlight on the selected row. Shared verbatim by the
/// Local panel's drill-down and the chats sidebar's in-place folder
/// drill-down (same keys: `localSessionList`, `localSession-<id>`,
/// `localSessionRunning`, `localSessionUnread`).
class LocalFolderSessionList extends StatelessWidget {
  const LocalFolderSessionList({
    super.key,
    required this.sessions,
    this.selectedSessionId,
    required this.onOpenSession,
    this.emptyText,
    this.onLocalMenu,
    this.onVisibleSession,
    this.bottomReserve = 0,
  });

  /// The folder's sessions, most recent first (the folder grouping's
  /// order — see [groupLocalSessionFolders]).
  final List<ChatListEntry> sessions;

  /// The shell's ONE selected session id — the highlighted row.
  final String? selectedSessionId;
  final ValueChanged<ChatListEntry> onOpenSession;

  /// The empty-state copy; defaults to the Local panel's "no sessions".
  final String? emptyText;

  /// Optional session-actions affordance (the chats sidebar's drill-down
  /// keeps delete/rename reachable; the Local panel passes null).
  final Future<void> Function(ChatListEntry entry, Rect anchor)? onLocalMenu;

  /// Lazy decoration request for a session row that reached the viewport.
  final ValueChanged<String>? onVisibleSession;

  /// Extra scroll padding under the floating phone dock (compact hosts
  /// only; desktop passes 0 and keeps the plain 4pt inset).
  final double bottomReserve;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return Center(
        child: Text(
          emptyText ?? context.l10n.localSessionsEmpty,
          style: TextStyle(color: FahColors.of(context).dim, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('localSessionList'),
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: MessengerGlassBodyInsets.topOf(context) + 4,
        bottom: 4 + bottomReserve,
      ),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final entry = sessions[index];
        onVisibleSession?.call(entry.id.value);
        return LocalSessionRow(
          key: ValueKey('localSession-${entry.id.value}'),
          entry: entry,
          selected: entry.id.value == selectedSessionId,
          hairline:
              index < sessions.length - 1 &&
              entry.id.value != selectedSessionId,
          onOpen: () => onOpenSession(entry),
          onLocalMenu: onLocalMenu,
        );
      },
    );
  }
}

/// One Telegram-style session row of [LocalFolderSessionList]: accent
/// highlight on selection, running/unread badges, hairline. The chats
/// sidebar's drill-down passes [onLocalMenu] to keep the session actions
/// (delete/rename) one hover away — the same `chatMenu-<id>` affordance
/// key the conversation rows use; the Local panel passes null (pure rows).
class LocalSessionRow extends StatefulWidget {
  const LocalSessionRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.hairline,
    required this.onOpen,
    this.onLocalMenu,
  });

  final ChatListEntry entry;
  final bool selected;
  final bool hairline;
  final VoidCallback onOpen;

  /// When set, hover/focus reveals the session-actions affordance.
  final Future<void> Function(ChatListEntry entry, Rect anchor)? onLocalMenu;

  @override
  State<LocalSessionRow> createState() => _LocalSessionRowState();
}

class _LocalSessionRowState extends State<LocalSessionRow> {
  bool _hovering = false;
  bool _focused = false;

  bool get _showActions => _hovering || _focused;

  String _preview(BuildContext context) {
    final entry = widget.entry;
    if (entry.isStreaming) {
      return '${context.l10n.chatWorking} ${entry.preview ?? ''}'.trim();
    }
    final preview = entry.preview?.trim();
    if (preview != null && preview.isNotEmpty) return preview;
    return context.l10n.chatNoPreview;
  }

  Color _actionColor(FahColors colors, FaDesignTokens tokens) =>
      widget.selected ? tokens.accentInk : colors.dim;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final selected = widget.selected;
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final actionColor = _actionColor(colors, tokens);
    final foreground = selected ? tokens.accentInk : colors.text;
    final subdued = selected
        ? tokens.accentInk.withValues(alpha: .82)
        : colors.dim;
    final preview = _preview(context);
    final unread = entry.unreadCount ?? 0;
    final menu = widget.onLocalMenu;
    return Focus(
      skipTraversal: true,
      onFocusChange: (value) {
        if (mounted) setState(() => _focused = value);
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Material(
          color: messengerListRowColor(
            selected: selected,
            accent: tokens.accent,
          ),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            child: SizedBox(
              height: LocalSessionsPanel.sessionRowPitch,
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: foreground,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          height: 1.2,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      chatListRelativeTime(
                                        context,
                                        entry.lastActivity ?? entry.createdAt,
                                      ),
                                      style: TextStyle(
                                        color: subdued,
                                        fontSize: 10.5,
                                        height: 1.2,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        preview,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: subdued,
                                          fontSize: 12.5,
                                          height: 1.25,
                                        ),
                                      ),
                                    ),
                                    if (entry.isStreaming)
                                      Container(
                                        key: const ValueKey(
                                          'localSessionRunning',
                                        ),
                                        margin: const EdgeInsets.only(left: 6),
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: selected
                                              ? tokens.accentInk
                                              : colors.teal,
                                        ),
                                      )
                                    else if (unread > 0)
                                      Container(
                                        key: const ValueKey(
                                          'localSessionUnread',
                                        ),
                                        margin: const EdgeInsets.only(left: 6),
                                        constraints: const BoxConstraints(
                                          minWidth: 19,
                                        ),
                                        height: 19,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                        ),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          shape: unread > 9
                                              ? BoxShape.rectangle
                                              : BoxShape.circle,
                                          borderRadius: unread > 9
                                              ? BorderRadius.circular(9.5)
                                              : null,
                                          color: selected
                                              ? tokens.accentInk
                                              : tokens.accent,
                                        ),
                                        child: Text(
                                          '$unread',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: selected
                                                ? tokens.accent
                                                : tokens.accentInk,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            height: 1,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (menu != null && _showActions)
                            Builder(
                              builder: (buttonContext) => IconButton(
                                key: ValueKey('chatMenu-${entry.id}'),
                                onPressed: () {
                                  final box =
                                      buttonContext.findRenderObject()
                                          as RenderBox;
                                  final origin = box.localToGlobal(Offset.zero);
                                  unawaited(menu(entry, origin & box.size));
                                },
                                tooltip: context.l10n.chatMoreActions,
                                icon: const Icon(Icons.more_horiz, size: 17),
                                color: actionColor,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 25,
                                  minHeight: 32,
                                ),
                                padding: EdgeInsets.zero,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.hairline)
                    Container(
                      height: 1,
                      margin: const EdgeInsets.only(left: 66, right: 8),
                      color: colors.border.withValues(alpha: .45),
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
