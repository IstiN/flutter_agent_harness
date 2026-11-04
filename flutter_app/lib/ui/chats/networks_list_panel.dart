// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/key_wallet.dart' show NetworkEntry;
import 'package:fa/network/models.dart' show Channel;
import 'package:fa/network/network_session.dart' show NetworkSession;
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart' show LocalSessionsPanel;
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The chat column's NETWORKS surface (Telegram pattern, owner pass): the
/// identity globe swaps the center column to a networks list — one 70pt
/// row per wallet membership: letter-gradient avatar (the folder-avatar
/// algorithm seeded with the network id), 14pt semibold display name, and
/// a status/meta second line from the live [NetworkSessionManager]
/// (Connected / Relay offline / Not connected). Selecting a network drills
/// in place to its channel list — the SAME row anatomy over the channels
/// the live session already loaded; '<' walks back networks → chats
/// ([onBack]) and channels → networks. Purely a presentation surface over
/// the manager's existing state — no networking happens here.
class ChatNetworksPanel extends StatefulWidget {
  const ChatNetworksPanel({
    super.key,
    required this.manager,
    this.mode,
    required this.onBack,
    required this.onManageNetworks,
    required this.onOpenChannel,
  });

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
  /// The drilled-into network id; null = the networks list.
  String? _openNetworkId;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final manager = widget.manager;
    final openId = _openNetworkId;
    final networks = manager?.wallet.networks ?? const {};
    final openName = openId == null ? null : networks[openId]?.name ?? openId;
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
                child: openId == null
                    ? _NetworksList(
                        networks: networks,
                        sessions: manager?.sessions ?? const {},
                        selectedNetworkId: widget.mode?.networkId,
                        onOpen: (networkId) =>
                            setState(() => _openNetworkId = networkId),
                      )
                    : _ChannelsList(
                        networkId: openId,
                        channels: session?.channels ?? const [],
                        selectedChannelId: widget.mode?.networkId == openId
                            ? widget.mode?.channelId
                            : null,
                        onOpenChannel: (channel) =>
                            widget.onOpenChannel(openId, channel),
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
/// back key swaps between chatNetworksBack (networks → chats) and
/// chatChannelsBack (channels → networks); the manage gear rides the
/// networks level.
class _NetworksHeader extends StatelessWidget {
  const _NetworksHeader({
    required this.title,
    required this.backKey,
    required this.onBack,
    required this.showManage,
    required this.onManage,
  });

  final String title;
  final Key backKey;
  final VoidCallback onBack;
  final bool showManage;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Container(
      height: 54,
      color: colors.panel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 10, 7),
        child: Row(
          children: [
            IconButton(
              key: backKey,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
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
          ],
        ),
      ),
    );
  }
}

/// Level 1: one row per wallet membership (insertion order — the same set
/// the old filter menu listed).
class _NetworksList extends StatelessWidget {
  const _NetworksList({
    required this.networks,
    required this.sessions,
    required this.selectedNetworkId,
    required this.onOpen,
  });

  final Map<String, NetworkEntry> networks;
  final Map<String, NetworkSession> sessions;
  final String? selectedNetworkId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (networks.isEmpty) {
      // The empty wallet keeps the list container (and its key) so the
      // level's shape stays testable in the guest mode.
      return SizedBox.expand(
        key: const ValueKey('chatNetworksList'),
        child: Center(
          child: Text(
            context.l10n.networkEmptyTitle,
            style: TextStyle(color: FahColors.of(context).dim, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('chatNetworksList'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: networks.length,
      itemBuilder: (context, index) {
        final entry = networks.entries.elementAt(index);
        final session = sessions[entry.key];
        final meta = session == null
            ? context.l10n.chatNetworkStatusIdle
            : session.networkOffline
            ? context.l10n.chatNetworkStatusOffline
            : context.l10n.chatNetworkStatusConnected;
        return _PanelRow(
          key: ValueKey('chatNetworkRow-${entry.key}'),
          avatarSeed: entry.key,
          label: entry.value.name,
          title: entry.value.name,
          meta: meta,
          selected: selectedNetworkId == entry.key,
          hairline: index < networks.length - 1,
          onTap: () => onOpen(entry.key),
        );
      },
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
