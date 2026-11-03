// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show chatListRelativeTime;
import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The Local section's folder-first navigation (Telegram pattern): level 1
/// lists LOCAL SESSION FOLDERS (persisted sessions grouped by cwd, sorted
/// by the most recent session); level 2 is the Telegram-style session list
/// for one folder. Session state rides [ChatListController.localEntries]
/// (FlutterSessionManager's single-flight listing) — this panel only
/// projects it. Opening a session stays the shell's existing open flow.
class LocalSessionsPanel extends StatelessWidget {
  const LocalSessionsPanel({
    super.key,
    required this.controller,
    required this.selectedFolderId,
    required this.onSelectFolder,
    required this.selectedSessionId,
    required this.onOpenSession,
    required this.onNew,
    this.compact = false,
    this.iconResolver,
  });

  static const double sessionRowPitch = 70;
  static const double avatarSize = 46;

  final ChatListController controller;
  final bool compact;

  /// The open folder's cwd ('' = Personal), null = the folder list.
  final String? selectedFolderId;
  final ValueChanged<String?> onSelectFolder;

  /// The shell's ONE selected session id (pending wins, then live, then
  /// manager slot) — the same value the sidebar rows highlight with.
  final String? selectedSessionId;
  final ValueChanged<ChatListEntry> onOpenSession;
  final VoidCallback onNew;
  final FolderIconResolver? iconResolver;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final titlebarHeight = isMac ? (compact ? 28.0 : 46.0) : 0.0;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final folders = groupLocalSessionFolders(
          controller.localEntries,
          personalName: context.l10n.sessionFolderPersonal,
        );
        final openFolder = selectedFolderId == null
            ? null
            : folders.where((folder) => folder.id == selectedFolderId).firstOrNull;
        return ColoredBox(
          color: colors.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _LocalHeader(
                title: openFolder?.name ?? context.l10n.wideNavLocal,
                showBack: openFolder != null,
                compact: compact,
                titlebarHeight: titlebarHeight,
                onBack: () => onSelectFolder(null),
                onNew: onNew,
              ),
              Expanded(
                child: openFolder == null
                    ? _FolderListView(
                        folders: folders,
                        iconResolver: iconResolver,
                        onOpen: onSelectFolder,
                      )
                    : _FolderSessionListView(
                        folder: openFolder,
                        selectedSessionId: selectedSessionId,
                        onOpenSession: onOpenSession,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The panel header: Telegram's '<' chevron header inside a folder, the
/// Local title plus the shared New action at the root.
class _LocalHeader extends StatelessWidget {
  const _LocalHeader({
    required this.title,
    required this.showBack,
    required this.compact,
    required this.titlebarHeight,
    required this.onBack,
    required this.onNew,
  });

  final String title;
  final bool showBack;
  final bool compact;
  final double titlebarHeight;
  final VoidCallback onBack;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    return Container(
      height: titlebarHeight + 54,
      color: colors.panel,
      child: Column(
        children: [
          if (titlebarHeight > 0) SizedBox(height: titlebarHeight),
          SizedBox(
            height: 54,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 10, 7),
              child: Row(
                children: [
                  if (showBack)
                    IconButton(
                      key: const ValueKey('localFolderBack'),
                      tooltip: context.l10n.localFolderBack,
                      onPressed: onBack,
                      icon: const Icon(Icons.chevron_left_rounded),
                      iconSize: 26,
                      color: colors.text,
                      visualDensity: VisualDensity.compact,
                    )
                  else
                    const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: compact ? 16 : 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox.square(
                    dimension: 32,
                    child: IconButton.filled(
                      key: const ValueKey('localNewButton'),
                      onPressed: onNew,
                      tooltip: context.l10n.chatNew,
                      iconSize: 18,
                      color: Colors.white,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        backgroundColor: tokens.accent,
                        foregroundColor: tokens.accentInk,
                        minimumSize: const Size.square(32),
                        maximumSize: const Size.square(32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Level 1: one row per local session folder.
class _FolderListView extends StatelessWidget {
  const _FolderListView({
    required this.folders,
    required this.iconResolver,
    required this.onOpen,
  });

  final List<LocalSessionFolder> folders;
  final FolderIconResolver? iconResolver;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return Center(
        child: Text(
          context.l10n.localFoldersEmpty,
          style: TextStyle(
            color: FahColors.of(context).dim,
            fontSize: 13,
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('localFolderList'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return _FolderRow(
          key: ValueKey('localFolder-${folder.id}'),
          folder: folder,
          iconResolver: iconResolver,
          onOpen: () => onOpen(folder.id),
          hairline: index < folders.length - 1,
        );
      },
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    super.key,
    required this.folder,
    required this.iconResolver,
    required this.onOpen,
    required this.hairline,
  });

  final LocalSessionFolder folder;
  final FolderIconResolver? iconResolver;
  final VoidCallback onOpen;
  final bool hairline;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: SizedBox(
          height: 64,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      FutureBuilder<MemoryImage?>(
                        future: iconResolver?.resolve(folder.id),
                        builder: (context, snapshot) => FolderAvatar(
                          seed: folder.avatarSeed,
                          label: folder.name,
                          image: snapshot.data,
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
                                color: colors.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              context.l10n.localFolderSessionCount(
                                folder.sessions.length,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.dim,
                                fontSize: 12.5,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (folder.runningCount > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          key: const ValueKey('localFolderRunning'),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.teal,
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        chatListRelativeTime(context, folder.latestActivity),
                        style: TextStyle(
                          color: colors.dim,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w400,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (hairline)
                Container(
                  height: 1,
                  margin: const EdgeInsets.only(left: 66, right: 8),
                  color: colors.border.withValues(alpha: .45),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Level 2: the Telegram-style session list for one folder — ~70pt rows,
/// Ø46 letter avatar, 14pt semibold name, top-right last-activity time,
/// 12–13pt preview line, running/unread badge, 1px hairlines, and an
/// accent rounded highlight on the selected row.
class _FolderSessionListView extends StatelessWidget {
  const _FolderSessionListView({
    required this.folder,
    required this.selectedSessionId,
    required this.onOpenSession,
  });

  final LocalSessionFolder folder;
  final String? selectedSessionId;
  final ValueChanged<ChatListEntry> onOpenSession;

  @override
  Widget build(BuildContext context) {
    if (folder.sessions.isEmpty) {
      return Center(
        child: Text(
          context.l10n.localSessionsEmpty,
          style: TextStyle(
            color: FahColors.of(context).dim,
            fontSize: 13,
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('localSessionList'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: folder.sessions.length,
      itemBuilder: (context, index) {
        final entry = folder.sessions[index];
        return _SessionRow(
          key: ValueKey('localSession-${entry.id.value}'),
          entry: entry,
          selected: entry.id.value == selectedSessionId,
          hairline:
              index < folder.sessions.length - 1 &&
              entry.id.value != selectedSessionId,
          onOpen: () => onOpenSession(entry),
        );
      },
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.hairline,
    required this.onOpen,
  });

  final ChatListEntry entry;
  final bool selected;
  final bool hairline;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final foreground = selected ? tokens.accentInk : colors.text;
    final subdued = selected
        ? tokens.accentInk.withValues(alpha: .82)
        : colors.dim;
    final preview = entry.isStreaming
        ? '${context.l10n.chatWorking} ${entry.preview ?? ''}'.trim()
        : entry.preview?.trim().isNotEmpty == true
        ? entry.preview!.trim()
        : context.l10n.chatNoPreview;
    final unread = entry.unreadCount ?? 0;
    return Material(
      color: selected ? tokens.accent : Colors.transparent,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: SizedBox(
          height: LocalSessionsPanel.sessionRowPitch,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      FolderAvatar(
                        seed: entry.id.value,
                        label: entry.title,
                        size: LocalSessionsPanel.avatarSize,
                      ),
                      const SizedBox(width: 10),
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
                                    key: const ValueKey('localSessionRunning'),
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
                                    key: const ValueKey('localSessionUnread'),
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
                    ],
                  ),
                ),
              ),
              if (hairline)
                Container(
                  height: 1,
                  margin: const EdgeInsets.only(left: 66, right: 8),
                  color: colors.border.withValues(alpha: .45),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
