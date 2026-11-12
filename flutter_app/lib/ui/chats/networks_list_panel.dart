// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/key_wallet.dart' show NetworkEntry;
import 'package:fa/network/models.dart' show Channel;
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show chatListRelativeTime;
import 'package:fa/ui/chats/local_sessions_panel.dart' show LocalSessionsPanel;
import 'package:fa/ui/chats/messenger_list_row_style.dart';
import 'package:fa/ui/network/sign_in_dialog.dart' show showSignInDialog;
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The chats sidebar's NETWORKS surface (Telegram pattern, owner pass):
/// the identity globe swaps the SIDEBAR content to this surface — the
/// same slot the Local drill-down uses; the message column keeps the
/// chat. Level 1 is the compact avatar-only networks strip (letter-
/// gradient avatars, the folder-avatar algorithm seeded with the network
/// id — no name labels); selecting a network opens its channel list
/// BESIDE the strip (the same 70pt Telegram rows over the channels the
/// live session already loaded) and puts the network's display name in
/// the surface header. Networks itself is a root destination with the same
/// brand and title geometry as Local; only the drilled channel list gets a
/// back chevron. The manage action keeps network management reachable. This
/// is purely a presentation surface over the manager's existing state — no
/// networking happens here.
class ChatNetworksPanel extends StatefulWidget {
  const ChatNetworksPanel({
    super.key,
    required this.manager,
    this.mode,
    this.chatList,
    required this.onManageNetworks,
    required this.onOpenChannel,
    this.onCollapse,
    this.onSettings,
    this.compact = false,
  });

  /// The compact strip's geometry (the Local folder strip's contract):
  /// ~70pt avatar-only column (level 2), Ø~50 avatars on a ~70pt pitch,
  /// accent capsule ~6x51 flush to the strip's left edge. Level 1 (no
  /// network open) is the standard [logo][name] list.
  static const double stripWidth = 70;
  static const double stripItemPitch = 70;
  static const double stripAvatarSize = 50;
  static const double capsuleWidth = 6;
  static const double capsuleHeight = 51;

  /// The session manager (wallet memberships + live sessions). Null (no
  /// network wiring) renders the empty state, like the old menu's guest
  /// shape.
  final NetworkSessionManager? manager;

  /// The mode controller — the selected network/channel highlight.
  final NetworkModeController? mode;

  /// The chat-list projection (owner pass): channel rows come from the
  /// controller's [ChatListController.networkChannelEntries] (each entry
  /// carries its networkId — the same rows the Channels rail lists). The
  /// live session's `channels` snapshot stays the fallback ONLY when the
  /// projection yields none for the drilled network; null keeps the old
  /// snapshot-only behaviour (tests).
  final ChatListController? chatList;

  /// The header's manage action (the management dialog the old menu
  /// opened) — keeps network management reachable from the rail.
  final VoidCallback onManageNetworks;

  /// A channel row tap: the shell applies the network chat filter and
  /// returns to the chats.
  final void Function(String networkId, Channel channel) onOpenChannel;

  /// Reserves the same wide-shell sidebar-toggle slot as All and Local.
  final VoidCallback? onCollapse;

  /// Explicit phone Settings action, shared with the other compact sections.
  final VoidCallback? onSettings;

  /// Uses the narrow shell's traffic-light-aware compact chrome.
  final bool compact;

  @override
  State<ChatNetworksPanel> createState() => _ChatNetworksPanelState();
}

class _ChatNetworksPanelState extends State<ChatNetworksPanel> {
  /// The drilled-into network id; null = the root networks list.
  String? _openNetworkId;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'networks-search');
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
  void dispose() {
    _searchController.removeListener(_onSearchStateChanged);
    _searchFocus.removeListener(_onSearchStateChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openNetwork(String? networkId) {
    _searchController.clear();
    _searchFocus.unfocus();
    _query = '';
    _searchExpanded = false;
    setState(() => _openNetworkId = networkId);
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

  bool _searchCollapsed(String? openId) =>
      (widget.compact || openId != null) && !_searchShown;

  VoidCallback? _searchRevealCallback(String? openId) =>
      (widget.compact || openId != null) && !_searchShown
      ? _revealSearch
      : null;

  VoidCallback? _searchCloseCallback(String? openId) =>
      (widget.compact || openId != null) && _searchShown ? _closeSearch : null;

  Widget? _headerLeading(String? openId, FahColors colors) {
    if (openId == null) return null;
    return IconButton(
      key: const ValueKey('chatChannelsBack'),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => _openNetwork(null),
      icon: const Icon(Icons.chevron_left_rounded),
      iconSize: 26,
      color: colors.text,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget? _headerTrailing(String? openId, FaDesignTokens tokens) {
    if (openId != null) return null;
    return FaIconActionButton(
      buttonKey: const ValueKey('chatNetworksManage'),
      diameter: 32,
      glyphSize: 18,
      glass: tokens.direction == FaVisualDirection.glass,
      tooltip: context.l10n.chatManageNetworks,
      onPressed: widget.onManageNetworks,
      child: const Icon(Icons.settings_outlined),
    );
  }

  Widget _buildHeader(
    String? openId,
    String? openName,
    FahColors colors,
    FaDesignTokens tokens,
  ) {
    return MessengerSectionHeader(
      title: openName ?? context.l10n.networkNetworksTitle,
      searchController: _searchController,
      searchFocusNode: _searchFocus,
      searchHint: openId == null
          ? context.l10n.networkSearchHint
          : context.l10n.networkChannelsSearchHint,
      onSearch: (query) => setState(() => _query = query),
      searchCollapsed: _searchCollapsed(openId),
      onSearchReveal: _searchRevealCallback(openId),
      onSearchClose: _searchCloseCallback(openId),
      onProfile: null,
      onSettings: widget.onSettings,
      onNew: null,
      compact: widget.compact,
      onCollapse: widget.onCollapse,
      leading: _headerLeading(openId, colors),
      trailing: _headerTrailing(openId, tokens),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final manager = widget.manager;
    final allNetworks =
        manager?.wallet.networks ?? const <String, NetworkEntry>{};
    final openId = _openNetworkId;
    final openName = openId == null
        ? null
        : allNetworks[openId]?.name ?? openId;
    final rankedNetworks = rankSessionEntries(
      allNetworks.entries.toList(),
      _query,
      (entry) => (
        title: entry.value.name,
        id: entry.key,
        cwd: null,
        updatedAt:
            DateTime.tryParse(entry.value.joinedAt) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    final networks = openId == null
        ? Map<String, NetworkEntry>.fromEntries(rankedNetworks)
        : allNetworks;
    return ListenableBuilder(
      listenable: Listenable.merge([?manager, ?widget.mode, ?widget.chatList]),
      builder: (context, _) {
        final session = openId == null ? null : manager?.sessions[openId];
        // The drilled network's channel rows: the chat-list projection
        // wins; the live session snapshot is the fallback when the
        // projection yields none for this network.
        final entryChannels = <ChatListEntry>[
          for (final entry
              in widget.chatList?.networkChannelEntries ??
                  const <ChatListEntry>[])
            if (entry.networkId == openId) entry,
        ];
        return MessengerGlassPanel(
          compact: widget.compact,
          underlayKey: const ValueKey('networksChromeUnderlay'),
          header: _buildHeader(openId, openName, colors, tokens),
          body: Row(
            key: const ValueKey('chatNetworksList'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The strip is NOT animated (owner pass): switching
              // networks must not jitter the logos — only the
              // content pane slides/fades.
              if (openId != null)
                _NetworksStrip(
                  networks: networks,
                  selectedNetworkId: openId,
                  onOpen: _openNetwork,
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
                    key: ValueKey('networksContent-${openId ?? 'list'}'),
                    child: openId == null
                        ? (allNetworks.isEmpty
                              ? _NetworksEmptyState(
                                  onManage: widget.onManageNetworks,
                                  onSignIn: manager != null && !manager.hasJwt
                                      ? () => unawaited(
                                          showSignInDialog(
                                            context,
                                            manager: manager,
                                          ),
                                        )
                                      : null,
                                )
                              : networks.isEmpty
                              ? sessionSearchEmptyState(
                                  context,
                                  colors,
                                  _query,
                                  _clearSearch,
                                  noMatches: context.l10n.listSearchNoMatches(
                                    _query,
                                  ),
                                )
                              : _NetworksList(
                                  networks: networks,
                                  onOpen: _openNetwork,
                                  bottomReserve: widget.compact
                                      ? MessengerFloatingDockInsets.bottomOf(
                                          context,
                                        )
                                      : 0,
                                ))
                        : _ChannelsList(
                            networkId: openId,
                            entries: entryChannels,
                            sessionChannels:
                                session?.channels ?? const <Channel>[],
                            selectedChannelId: widget.mode?.networkId == openId
                                ? widget.mode?.channelId
                                : null,
                            query: _query,
                            bottomReserve: widget.compact
                                ? MessengerFloatingDockInsets.bottomOf(context)
                                : 0,
                            onClearSearch: _clearSearch,
                            onOpenChannel: (channel) =>
                                widget.onOpenChannel(openId, channel),
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

/// The wallet has no memberships: the empty state with the affordances
/// that get the user INTO networks (gh-2131 — the bare title was a dead
/// end; a signed-out visitor needs the sign-in entry, a signed-in one
/// the join/manage surface). Mirrors the management sidebar's empty
/// state ([joinFirstNetwork]/[emptyStateSignIn] keys).
class _NetworksEmptyState extends StatelessWidget {
  const _NetworksEmptyState({required this.onManage, required this.onSignIn});

  /// Opens the network management dialog (join lives there).
  final VoidCallback onManage;

  /// Opens the sign-in dialog; null when already signed in (the button
  /// hides — an empty list signed in means join, not re-auth).
  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.networkEmptyTitle,
              style: TextStyle(color: colors.dim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('joinFirstNetwork'),
              onPressed: onManage,
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.l10n.networkJoinFirst),
            ),
            if (onSignIn != null) ...[
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('emptyStateSignIn'),
                onPressed: onSignIn,
                child: Text(context.l10n.networkSignInTitle),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Level 1: the standard [logo][name] networks list — Telegram-style
/// rows (70pt pitch, Ø50 avatar, display name) that drill into the
/// avatar-strip + channels view when tapped.
class _NetworksList extends StatelessWidget {
  const _NetworksList({
    required this.networks,
    required this.onOpen,
    this.bottomReserve = 0,
  });

  final Map<String, NetworkEntry> networks;
  final ValueChanged<String> onOpen;

  /// Extra scroll padding under the floating phone dock (compact hosts
  /// only; desktop passes 0 and keeps the plain 4pt inset).
  final double bottomReserve;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ListView.builder(
      key: const ValueKey('networksList'),
      padding: EdgeInsets.only(
        top: MessengerGlassBodyInsets.topOf(context) + 4,
        bottom: 4 + bottomReserve,
      ),
      itemCount: networks.length,
      itemBuilder: (context, index) {
        final entry = networks.entries.elementAt(index);
        return SizedBox(
          key: ValueKey('networkRow-${entry.key}'),
          height: ChatNetworksPanel.stripItemPitch,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onOpen(entry.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    FolderAvatar(
                      seed: entry.key,
                      label: entry.value.name,
                      size: ChatNetworksPanel.stripAvatarSize,
                      circle: true,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        entry.value.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: tokens.ink1,
                        ),
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

/// Level 2: the compact avatar-only networks strip — one Ø50
/// letter-gradient avatar per [ChatNetworksPanel.stripItemPitch] cell,
/// no labels or status meta. The drilled network paints the accent capsule
/// flush to the strip's left edge and squares its avatar (radius ~25%);
/// a tap opens its channel list beside the strip.
class _NetworksStrip extends StatelessWidget {
  const _NetworksStrip({
    required this.networks,
    required this.selectedNetworkId,
    required this.onOpen,
  });

  final Map<String, NetworkEntry> networks;
  final String? selectedNetworkId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      key: const ValueKey('networksStrip'),
      width: ChatNetworksPanel.stripWidth,
      child: networks.isEmpty
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
                itemCount: networks.length,
                itemBuilder: (context, index) {
                  final entry = networks.entries.elementAt(index);
                  final selected = entry.key == selectedNetworkId;
                  return SizedBox(
                    key: ValueKey('chatNetworkRow-${entry.key}'),
                    width: ChatNetworksPanel.stripWidth,
                    height: ChatNetworksPanel.stripItemPitch,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => onOpen(entry.key),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            FolderAvatar(
                              seed: entry.key,
                              label: entry.value.name,
                              size: ChatNetworksPanel.stripAvatarSize,
                              circle: !selected,
                              radiusFactor: selected ? 0.25 : 0.28,
                            ),
                            if (selected)
                              Positioned(
                                left: 0,
                                top:
                                    (ChatNetworksPanel.stripItemPitch -
                                        ChatNetworksPanel.capsuleHeight) /
                                    2,
                                child: Container(
                                  key: const ValueKey('networkSelectedCapsule'),
                                  width: ChatNetworksPanel.capsuleWidth,
                                  height: ChatNetworksPanel.capsuleHeight,
                                  decoration: BoxDecoration(
                                    color: tokens.accent,
                                    borderRadius: BorderRadius.circular(
                                      ChatNetworksPanel.capsuleWidth / 2,
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

/// Level 2: the drilled-into network's channels — the SAME row anatomy
/// over the chat-list projection's rows for this network (owner pass: the
/// projection is what the Channels rail lists; the live session's
/// `channels` snapshot is empty at runtime), with the session snapshot as
/// the fallback when the projection yields none. Neither → the honest
/// empty state.
class _ChannelsList extends StatelessWidget {
  const _ChannelsList({
    required this.networkId,
    required this.entries,
    required this.sessionChannels,
    required this.selectedChannelId,
    required this.query,
    required this.onClearSearch,
    required this.onOpenChannel,
    this.bottomReserve = 0,
  });

  final String networkId;

  /// Extra scroll padding under the floating phone dock (compact hosts
  /// only; desktop passes 0 and keeps the plain 4pt inset).
  final double bottomReserve;

  /// The projection's channel entries for the drilled network.
  final List<ChatListEntry> entries;

  /// The live session's channel snapshot (the fallback source).
  final List<Channel> sessionChannels;
  final String? selectedChannelId;
  final String query;
  final VoidCallback onClearSearch;
  final ValueChanged<Channel> onOpenChannel;

  @override
  Widget build(BuildContext context) {
    // The projection wins (owner pass); the session snapshot is consulted
    // ONLY when it yields nothing — never a merge, so a live session with
    // a stale snapshot cannot shadow the inbox rows.
    final fromEntries = entries.isNotEmpty;
    if (!fromEntries && sessionChannels.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chatNetworkChannelsEmpty,
          style: TextStyle(color: FahColors.of(context).dim, fontSize: 13),
        ),
      );
    }
    final allRows = <_ChannelRowData>[
      if (fromEntries)
        for (final entry in entries)
          (
            key: ValueKey('chatNetworkChannel-${entry.id.value}'),
            title: entry.title,
            // The projection carries no public/private flag — show the
            // last-activity meta instead. Never fabricate a visibility.
            meta: chatListRelativeTime(context, entry.lastActivity).trim(),
            channel: Channel(
              id: entry.id.value,
              networkId: networkId,
              name: entry.title,
            ),
          )
      else
        for (final channel in sessionChannels)
          (
            key: ValueKey('chatNetworkChannel-${channel.id}'),
            title: channel.name ?? channel.id,
            meta: channel.isPublic
                ? context.l10n.chatNetworkChannelPublic
                : context.l10n.chatNetworkChannelPrivate,
            channel: channel,
          ),
    ];
    final normalizedQuery = query.trim().toLowerCase();
    final rows = normalizedQuery.isEmpty
        ? allRows
        : allRows
              .where(
                (row) =>
                    row.title.toLowerCase().contains(normalizedQuery) ||
                    row.channel.id.toLowerCase().contains(normalizedQuery),
              )
              .toList();
    if (rows.isEmpty) {
      return sessionSearchEmptyState(
        context,
        FahColors.of(context),
        query,
        onClearSearch,
        noMatches: context.l10n.listSearchNoMatches(query),
      );
    }
    return ListView.builder(
      key: const ValueKey('chatNetworkChannels'),
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: MessengerGlassBodyInsets.topOf(context) + 4,
        bottom: 4 + bottomReserve,
      ),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return _PanelRow(
          key: row.key,
          title: row.title,
          meta: row.meta,
          selected: selectedChannelId == row.channel.id,
          hairline: index < rows.length - 1,
          onTap: () => onOpenChannel(row.channel),
        );
      },
    );
  }
}

/// One row of [_ChannelsList]: stable key + identity, title, meta line and
/// the [Channel] handed to [ChatNetworksPanel.onOpenChannel] (built from
/// the projection entry when the row comes from the chat list).
typedef _ChannelRowData = ({
  Key key,
  String title,
  String meta,
  Channel channel,
});

/// One Telegram row of the networks panel: 70pt pitch, the NEUTRAL tag
/// glyph (owner pass — channels are not identities), 14pt semibold title,
/// 12.5pt meta line, hairlines, accent highlight on the selected row (the
/// Local sessions panel's row shape).
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    super.key,
    required this.title,
    required this.meta,
    required this.selected,
    required this.hairline,
    required this.onTap,
  });

  final String title;
  final String? meta;
  final bool selected;
  final bool hairline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final foreground = selected ? tokens.accentInk : colors.text;
    final subdued = selected
        ? tokens.accentInk.withValues(alpha: .82)
        : colors.dim;
    return Material(
      color: messengerListRowColor(selected: selected, accent: tokens.accent),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: LocalSessionsPanel.sessionRowPitch,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      const NeutralGlyphAvatar(
                        size: LocalSessionsPanel.avatarSize,
                        icon: Icons.tag_rounded,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                            if (meta case final metaText?
                                when metaText.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                metaText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: subdued,
                                  fontSize: 12.5,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: subdued,
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
