// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/key_wallet.dart' show NetworkEntry;
import 'package:fa/network/models.dart' show Channel;
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart' show LocalSessionsPanel;
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
        listenable: Listenable.merge([?manager, ?widget.mode]),
        builder: (context, _) {
          final session = openId == null ? null : manager?.sessions[openId];
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
                    if (openId == null)
                      Expanded(
                        child: networks.isEmpty
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
                                onOpen: (networkId) =>
                                    setState(() => _openNetworkId = networkId),
                              ),
                      )
                    else ...[
                      _NetworksStrip(
                        networks: networks,
                        selectedNetworkId: openId,
                        onOpen: (networkId) =>
                            setState(() => _openNetworkId = networkId),
                      ),
                      Expanded(
                        child: _ChannelsList(
                              networkId: openId,
                              channels: session?.channels ?? const [],
                              selectedChannelId:
                                  widget.mode?.networkId == openId
                                  ? widget.mode?.channelId
                                  : null,
                              onOpenChannel: (channel) =>
                                  widget.onOpenChannel(openId, channel),
                            ),
                      ),
                    ],
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
          : ListView.builder(
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
    );
  }
}

/// Level 2: the drilled-into network's channels — the SAME row anatomy
/// over the [Channel]s the live session already loaded (name, public/
/// private meta). No session → the honest empty state.
class _ChannelsList extends StatelessWidget {
  const _ChannelsList({
    required this.networkId,
    required this.channels,
    required this.selectedChannelId,
    required this.onOpenChannel,
  });

  final String networkId;
  final List<Channel> channels;
  final String? selectedChannelId;
  final ValueChanged<Channel> onOpenChannel;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return Center(
        child: Text(
          context.l10n.chatNetworkChannelsEmpty,
          style: TextStyle(color: FahColors.of(context).dim, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('chatNetworkChannels'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final name = channel.name ?? channel.id;
        return _PanelRow(
          key: ValueKey('chatNetworkChannel-${channel.id}'),
          avatarSeed: channel.id,
          label: name,
          title: name,
          meta: channel.isPublic
              ? context.l10n.chatNetworkChannelPublic
              : context.l10n.chatNetworkChannelPrivate,
          selected: selectedChannelId == channel.id,
          hairline: index < channels.length - 1,
          onTap: () => onOpenChannel(channel),
        );
      },
    );
  }
}

/// One Telegram row of the networks panel: 70pt pitch, Ø46 letter-gradient
/// avatar, 14pt semibold title, 12.5pt meta line, hairlines, accent
/// highlight on the selected row (the Local sessions panel's row shape).
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    super.key,
    required this.avatarSeed,
    required this.label,
    required this.title,
    required this.meta,
    required this.selected,
    required this.hairline,
    required this.onTap,
  });

  final String avatarSeed;
  final String label;
  final String title;
  final String meta;
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
      color: selected ? tokens.accent : Colors.transparent,
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
                      FolderAvatar(seed: avatarSeed, label: label),
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
                            const SizedBox(height: 3),
                            Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: subdued,
                                fontSize: 12.5,
                                height: 1.2,
                              ),
                            ),
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
