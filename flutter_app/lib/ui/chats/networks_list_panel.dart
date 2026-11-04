// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

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
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The chats sidebar's NETWORKS surface (Telegram pattern, owner pass):
/// the identity globe swaps the SIDEBAR content to this surface — the
/// same slot the Local drill-down uses; the message column keeps the
/// chat. Level 1 is the compact avatar-only networks strip (letter-
/// gradient avatars, the folder-avatar algorithm seeded with the network
/// id — no name labels); selecting a network opens its channel list
/// BESIDE the strip (the same 70pt Telegram rows over the channels the
/// live session already loaded) and puts the network's display name in
/// the surface header. The '<' chevrons walk channels → strip ([onBack]
/// returns to the normal chats) and the manage gear keeps the management
/// dialog reachable. Purely a presentation surface over the manager's
/// existing state — no networking happens here.
class ChatNetworksPanel extends StatefulWidget {
  const ChatNetworksPanel({
    super.key,
    required this.manager,
    this.mode,
    this.chatList,
    required this.onBack,
    required this.onManageNetworks,
    required this.onOpenChannel,
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

  /// The networks level's '<' chevron: back to the normal chats.
  final VoidCallback onBack;

  /// The header's manage action (the management dialog the old menu
  /// opened) — keeps network management reachable from the rail.
  final VoidCallback onManageNetworks;

  /// A channel row tap: the shell applies the network chat filter and
  /// returns to the chats.
  final void Function(String networkId, Channel channel) onOpenChannel;

  @override
  State<ChatNetworksPanel> createState() => _ChatNetworksPanelState();
}

class _ChatNetworksPanelState extends State<ChatNetworksPanel> {
  /// The drilled-into network id; null = the strip level.
  String? _openNetworkId;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final manager = widget.manager;
    final networks = manager?.wallet.networks ?? const {};
    final openId = _openNetworkId;
    final openName = openId == null ? null : networks[openId]?.name ?? openId;
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    // The sidebar panel is flush with the window edge and must clear the
    // native titlebar region (macOS fullSizeContentView inset; the same
    // clearance the Local panel's header applies).
    final titlebarHeight = isMac ? 46.0 : 0.0;
    return ColoredBox(
      color: colors.panel,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          ?manager,
          ?widget.mode,
          ?widget.chatList,
        ]),
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NetworksHeader(
                titlebarHeight: titlebarHeight,
                title: openName ?? context.l10n.networkNetworksTitle,
                backKey: openId == null
                    ? const ValueKey('chatNetworksBack')
                    : const ValueKey('chatChannelsBack'),
                onBack: openId == null
                    ? widget.onBack
                    : () => setState(() => _openNetworkId = null),
                showManage: openId == null,
                onManage: widget.onManageNetworks,
              ),
              Expanded(
                key: const ValueKey('chatNetworksList'),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The strip is NOT animated (owner pass): switching
                    // networks must not jitter the logos — only the
                    // content pane slides/fades.
                    if (openId != null)
                      _NetworksStrip(
                        networks: networks,
                        selectedNetworkId: openId,
                        onOpen: (networkId) =>
                            setState(() => _openNetworkId = networkId),
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
                              ? (networks.isEmpty
                                    ? Center(
                                        child: Text(
                                          context.l10n.networkEmptyTitle,
                                          style: TextStyle(
                                            color: FahColors.of(context).dim,
                                            fontSize: 13,
                                          ),
                                        ),
                                      )
                                    : _NetworksList(
                                        networks: networks,
                                        onOpen: (networkId) => setState(
                                          () => _openNetworkId = networkId,
                                        ),
                                      ))
                              : _ChannelsList(
                                  networkId: openId,
                                  entries: entryChannels,
                                  sessionChannels:
                                      session?.channels ?? const <Channel>[],
                                  selectedChannelId:
                                      widget.mode?.networkId == openId
                                      ? widget.mode?.channelId
                                      : null,
                                  onOpenChannel: (channel) =>
                                      widget.onOpenChannel(openId, channel),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The Telegram '<' chevron header row (the Local panel's header anatomy):
/// back key swaps between chatNetworksBack (strip → normal chats) and
/// chatChannelsBack (channels → strip); the title carries the surface's
/// name (Networks at strip level, the open network's display name beside
/// the channels) and the manage gear rides the strip level. The header
/// reserves the floating sidebar toggle's top-right slot — the same 36pt
/// contract as the shared section header.
class _NetworksHeader extends StatelessWidget {
  const _NetworksHeader({
    required this.titlebarHeight,
    required this.title,
    required this.backKey,
    required this.onBack,
    required this.showManage,
    required this.onManage,
  });

  final double titlebarHeight;
  final String title;
  final Key backKey;
  final VoidCallback onBack;
  final bool showManage;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
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
                  IconButton(
                    key: backKey,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: onBack,
                    icon: const Icon(Icons.chevron_left_rounded),
                    iconSize: 26,
                    color: colors.text,
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (showManage)
                    SizedBox.square(
                      dimension: 32,
                      child: IconButton(
                        key: const ValueKey('chatNetworksManage'),
                        tooltip: context.l10n.chatManageNetworks,
                        onPressed: onManage,
                        icon: const Icon(Icons.settings_outlined),
                        iconSize: 18,
                        color: colors.dim,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  // The wide shell's floating sidebar toggle owns the
                  // panel's top-right corner (the shared section header
                  // reserves this exact 36pt slot) — the header never
                  // places actions under it.
                  const SizedBox(width: 4),
                  const SizedBox.square(dimension: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Level 1: the standard [logo][name] networks list — Telegram-style
/// rows (70pt pitch, Ø50 avatar, display name) that drill into the
/// avatar-strip + channels view when tapped.
class _NetworksList extends StatelessWidget {
  const _NetworksList({required this.networks, required this.onOpen});

  final Map<String, NetworkEntry> networks;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ListView.builder(
      key: const ValueKey('networksList'),
      padding: const EdgeInsets.symmetric(vertical: 4),
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
                padding: const EdgeInsets.symmetric(vertical: 4),
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
    required this.onOpenChannel,
  });

  final String networkId;

  /// The projection's channel entries for the drilled network.
  final List<ChatListEntry> entries;

  /// The live session's channel snapshot (the fallback source).
  final List<Channel> sessionChannels;
  final String? selectedChannelId;
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
    final rows = <_ChannelRowData>[
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
    return ListView.builder(
      key: const ValueKey('chatNetworkChannels'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
