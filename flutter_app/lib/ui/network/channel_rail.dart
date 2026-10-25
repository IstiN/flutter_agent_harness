// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';

/// The channel rail of a selected network (issue #955): a presence header
/// (live member count), then the channel list split into two sections —
/// Channels (private, lock icon) and Showcases (public, globe icon).
/// Private channels carry an overflow menu with the AC-B17 "Add agent"
/// invite.
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

  Future<void> _showRoster(NetworkSession? session) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        if (session == null) return const _NetworkRosterSheet(session: null);
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) => _NetworkRosterSheet(session: session),
        );
      },
    );
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
    final regular = all.where((c) => !c.isPublic).toList();
    final showcases = all.where((c) => c.isPublic).toList();
    // One list, two sections: Channels then Showcases.
    final rows = <Object>[
      if (regular.isNotEmpty) _Section.channels,
      ...regular,
      if (showcases.isNotEmpty) _Section.showcases,
      ...showcases,
    ];
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
              if (networkId != null)
                IconButton(
                  key: const ValueKey('networkAddAgentButton'),
                  icon: Icon(Icons.person_add_alt, size: 20, color: colors.dim),
                  tooltip: context.l10n.networkAddAgent,
                  onPressed: () => unawaited(
                    showDialog<void>(
                      context: context,
                      builder: (_) => AddAgentDialog(
                        wallet: widget.manager.wallet,
                        manager: widget.manager,
                        networkId: networkId,
                        channel: null,
                        initialScope: AgentInviteScope.network,
                      ),
                    ),
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
          padding: const EdgeInsets.fromLTRB(12, 0, 16, 4),
          child: Tooltip(
            message: context.l10n.networkRosterTitle,
            child: InkWell(
              key: const ValueKey('networkRosterButton'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => unawaited(_showRoster(session)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
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
                    const SizedBox(width: 2),
                    Icon(Icons.expand_more, size: 16, color: colors.dim),
                  ],
                ),
              ),
            ),
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
              : rows.isEmpty
              ? Center(
                  child: Text(
                    context.l10n.networkNoChannels,
                    style: TextStyle(color: colors.dim),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    if (row is _Section) {
                      return _SectionHeader(
                        key: ValueKey('section:${row.name}'),
                        label: switch (row) {
                          _Section.channels =>
                            context.l10n.networkChannelsSection,
                          _Section.showcases =>
                            context.l10n.networkShowcasesSection,
                        },
                      );
                    }
                    final channel = row as Channel;
                    return _ChannelTile(
                      key: ValueKey('channel:${channel.id}'),
                      channel: channel,
                      selected: widget.controller.channelId == channel.id,
                      manager: widget.manager,
                      onTap: () => unawaited(_openChannel(channel.id)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Live roster behind the presence counter. Names are shown verbatim so a
/// member can be addressed with the same `@displayName` in the composer.
class _NetworkRosterSheet extends StatelessWidget {
  const _NetworkRosterSheet({required this.session});

  final NetworkSession? session;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final session = this.session;
    final members =
        session == null ? const <Member>[] : session.roster.values.toList()
          ..sort(_compareMembers);
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Icon(Icons.group_outlined, size: 20, color: colors.dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.l10n.networkRosterTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            if (session == null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Flexible(child: Text(context.l10n.networkRosterLoading)),
                  ],
                ),
              )
            else if (members.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.networkRosterEmpty,
                  style: TextStyle(color: colors.dim),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: members.length,
                  itemBuilder: (context, index) =>
                      _RosterMemberTile(member: members[index]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static int _compareMembers(Member a, Member b) {
    final byPresence = _presenceRank(
      a.presence,
    ).compareTo(_presenceRank(b.presence));
    if (byPresence != 0) return byPresence;
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }

  static int _presenceRank(Presence presence) => switch (presence) {
    Presence.live => 0,
    Presence.busy => 1,
    Presence.offline => 2,
    Presence.unknown => 3,
  };
}

class _RosterMemberTile extends StatelessWidget {
  const _RosterMemberTile({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final online = member.presence == Presence.live;
    final presenceColor = switch (member.presence) {
      Presence.live => colors.teal,
      Presence.busy => colors.pending,
      _ => colors.dim,
    };
    final name = member.displayName.isEmpty ? member.id : member.displayName;
    return ListTile(
      key: ValueKey('networkRosterMember:${member.id}'),
      dense: true,
      leading: Icon(switch (member.memberClass) {
        MemberClass.agent => Icons.smart_toy_outlined,
        MemberClass.owner => Icons.star_outline,
        MemberClass.admin => Icons.admin_panel_settings_outlined,
        MemberClass.guest => Icons.person_outline,
        MemberClass.member => Icons.person,
        MemberClass.unknown => Icons.help_outline,
      }, color: colors.dim),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_memberClassLabel(context, member.memberClass)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: presenceColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _presenceLabel(context, member.presence),
            style: TextStyle(
              fontSize: 12,
              color: online ? colors.teal : colors.dim,
            ),
          ),
        ],
      ),
    );
  }

  static String _presenceLabel(BuildContext context, Presence presence) {
    final l10n = context.l10n;
    return switch (presence) {
      Presence.live => l10n.networkPresenceOnline,
      Presence.busy => l10n.networkPresenceBusy,
      Presence.offline || Presence.unknown => l10n.networkPresenceOffline,
    };
  }

  static String _memberClassLabel(
    BuildContext context,
    MemberClass memberClass,
  ) {
    final l10n = context.l10n;
    return switch (memberClass) {
      MemberClass.owner => l10n.networkMemberOwner,
      MemberClass.admin => l10n.networkMemberAdmin,
      MemberClass.member => l10n.networkMemberMember,
      MemberClass.guest => l10n.networkMemberGuest,
      MemberClass.agent => l10n.networkMemberAgent,
      MemberClass.unknown => l10n.networkMemberUnknown,
    };
  }
}

/// The channel-list section a header row stands for.
enum _Section { channels, showcases }

/// A section header in the channel list (Channels / Showcases).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: colors.dim,
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
    required this.manager,
    required this.onTap,
  });

  final Channel channel;
  final bool selected;
  final NetworkSessionManager manager;
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
                // AC-B17 agent pairing: private channels hand over the
                // keypair; public channels hand over a keyless link.
                if (true)
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
                              wallet: manager.wallet,
                              manager: manager,
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
