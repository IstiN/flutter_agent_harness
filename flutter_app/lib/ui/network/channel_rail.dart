// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';

/// The channel rail of a selected network (issue #955): a presence header
/// (live member count), an All | Showcases pill filter, and the channel
/// list — lock icon for private, globe for public. Private channels carry
/// an overflow menu with the AC-B17 "Add agent" invite.
class ChannelRail extends StatefulWidget {
  const ChannelRail({
    super.key,
    required this.controller,
    required this.manager,
  });

  /// The mode controller — a channel tap selects the channel.
  final NetworkModeController controller;

  /// The session manager — the live session for the selected network.
  final NetworkSessionManager manager;

  @override
  State<ChannelRail> createState() => _ChannelRailState();
}

class _ChannelRailState extends State<ChannelRail> {
  /// Pill filter: false = all channels, true = showcases (public) only.
  bool _showcasesOnly = false;

  NetworkSession? get _session =>
      widget.manager.sessions[widget.controller.networkId];

  /// Channel creation is owner/admin only (the wallet entry carries the
  /// member class recorded at join).
  bool get _canCreateChannel {
    final networkId = widget.controller.networkId;
    final memberClass = widget.manager.wallet.networks[networkId]?.memberClass;
    return memberClass == 'owner' || memberClass == 'admin';
  }

  Future<void> _openChannel(String channelId) async {
    unawaited(widget.controller.selectChannel(channelId));
    final session = _session;
    if (session == null) return;
    try {
      await session.openChannel(channelId);
    } on Object catch (e) {
      if (mounted) showFahErrorSnack(context, '$e');
    }
  }

  Future<void> _createChannel() async {
    final networkId = widget.controller.networkId;
    if (networkId == null) return;
    final created = await showDialog<({String name, bool isPublic})>(
      context: context,
      builder: (_) => const _CreateChannelDialog(),
    );
    if (created == null || !mounted) return;
    try {
      final channel = await widget.manager.createChannel(
        networkId,
        name: created.name,
        isPublic: created.isPublic,
      );
      // The creator generates the channel keypair locally — it never
      // touches the server (E2E, invariant I1).
      final keys = await EnvelopeCodec.newX25519KeyPair();
      await widget.manager.wallet.addChannelKeys(
        networkId: networkId,
        channel: channel.id,
        pub: keys.pub,
        priv: keys.priv,
      );
      await _openChannel(channel.id);
    } on FaNetworkException catch (e) {
      if (mounted) showFahErrorSnack(context, e.message);
    } on Object catch (e) {
      if (mounted) showFahErrorSnack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.manager,
        ?session,
      ]),
      builder: (context, _) => _build(context, session),
    );
  }

  Widget _build(BuildContext context, NetworkSession? session) {
    final colors = FahColors.of(context);
    final networkId = widget.controller.networkId;
    final networkName =
        widget.manager.wallet.networks[networkId]?.name ?? networkId ?? '';
    final live = session == null
        ? 0
        : session.roster.values
              .where((m) => m.presence == Presence.live)
              .length;
    final all = session?.channels ?? const <Channel>[];
    final channels = _showcasesOnly
        ? all.where((c) => c.isPublic).toList()
        : all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  networkName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (_canCreateChannel)
                IconButton(
                  key: const ValueKey('createChannelButton'),
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: context.l10n.networkNewChannel,
                  onPressed: () => unawaited(_createChannel()),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: session != null && !session.networkOffline
                      ? colors.teal
                      : colors.dim,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                context.l10n.networkOnlineCount(live),
                style: TextStyle(fontSize: 12, color: colors.dim),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              _Pill(
                label: context.l10n.networkFilterAll,
                selected: !_showcasesOnly,
                onTap: () => setState(() => _showcasesOnly = false),
              ),
              const SizedBox(width: 6),
              _Pill(
                label: context.l10n.networkFilterShowcases,
                selected: _showcasesOnly,
                onTap: () => setState(() => _showcasesOnly = true),
              ),
            ],
          ),
        ),
        Expanded(
          child: session == null
              ? Center(
                  child: Text(
                    context.l10n.networkConnecting,
                    style: TextStyle(color: colors.dim),
                  ),
                )
              : channels.isEmpty
              ? Center(
                  child: Text(
                    context.l10n.networkNoChannels,
                    style: TextStyle(color: colors.dim),
                  ),
                )
              : ListView.builder(
                  itemCount: channels.length,
                  itemBuilder: (context, index) => _ChannelTile(
                    key: ValueKey('channel:${channels[index].id}'),
                    channel: channels[index],
                    selected: widget.controller.channelId == channels[index].id,
                    wallet: widget.manager.wallet,
                    onTap: () => unawaited(_openChannel(channels[index].id)),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: selected
          ? (isLight ? const Color(0xFFEEF2FF) : colors.panelAlt)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? colors.indigo : colors.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected
                  ? (isLight ? colors.indigo : colors.teal)
                  : colors.dim,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    super.key,
    required this.channel,
    required this.selected,
    required this.wallet,
    required this.onTap,
  });

  final Channel channel;
  final bool selected;
  final KeyWallet wallet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? (isLight ? const Color(0xFFEEF2FF) : colors.panelAlt)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  channel.isPublic ? Icons.public : Icons.lock_outline,
                  size: 16,
                  color: colors.dim,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    channel.name ?? channel.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.text,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                // The AC-B17 "add an agent" pairing exists for PRIVATE
                // channels only (a public channel needs no key handover).
                if (!channel.isPublic)
                  PopupMenuButton<String>(
                    key: ValueKey('channelMenu:${channel.id}'),
                    icon: Icon(Icons.more_vert, size: 18, color: colors.dim),
                    tooltip: context.l10n.networkChannelOptions,
                    onSelected: (value) {
                      if (value == 'addAgent') {
                        unawaited(
                          showDialog<void>(
                            context: context,
                            builder: (_) => AddAgentDialog(
                              wallet: wallet,
                              networkId: channel.networkId,
                              channel: channel,
                            ),
                          ),
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'addAgent',
                        child: Text(context.l10n.networkAddAgent),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The create-channel dialog: name + showcase (public) toggle. Returns the
/// choice, or null when cancelled.
class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog();

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _name = TextEditingController();
  bool _isPublic = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.networkNewChannel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: context.l10n.networkNameLabel,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.networkShowcasePublic),
            value: _isPublic,
            onChanged: (value) => setState(() => _isPublic = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop((name: name, isPublic: _isPublic));
          },
          child: Text(context.l10n.networkCreate),
        ),
      ],
    );
  }
}
