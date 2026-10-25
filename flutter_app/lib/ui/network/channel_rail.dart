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

  /// Channel and agent management is owner/admin only (the wallet entry
  /// carries the member class recorded at join).
  bool get _canManageNetwork {
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
    final channelId = widget.controller.channelId;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        if (session == null) return const _NetworkRosterSheet(session: null);
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) => _NetworkRosterSheet(
            session: session,
            channelId: channelId,
            canDropAgents: _canManageNetwork,
            onDropAgent: (member) => unawaited(_dropAgent(session, member)),
          ),
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

  Future<void> _renameChannel(Channel channel) async {
    final session = _session;
    if (session == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameChannelDialog(initialName: channel.name ?? ''),
    );
    if (name == null || !mounted) return;
    try {
      await session.renameChannel(channel.id, name);
    } on FaNetworkException catch (e) {
      if (mounted) showFahErrorSnack(context, e.message);
    } on Object catch (e) {
      if (mounted) showFahErrorSnack(context, '$e');
    }
  }

  Future<void> _deleteChannel(Channel channel) async {
    final session = _session;
    if (session == null) return;
    final label = channelDisplayLabel(channel.id, channel.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkDeleteChannelTitle),
        content: Text(
          '"$label"\n\n${dialogContext.l10n.networkDeleteChannelBody}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('confirmDeleteChannel'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await session.deleteChannel(channel.id);
      if (!mounted) return;
      if (widget.controller.channelId == channel.id) {
        final remaining = session.channels;
        if (remaining.isEmpty) {
          await widget.controller.backToChannels();
        } else {
          await _openChannel(remaining.first.id);
        }
      }
      if (mounted) {
        showFahSnack(context, context.l10n.networkChannelDeleted);
      }
    } on FaNetworkException catch (e) {
      if (mounted) showFahErrorSnack(context, e.message);
    } on Object catch (e) {
      if (mounted) showFahErrorSnack(context, '$e');
    }
  }

  Future<void> _dropAgent(NetworkSession session, Member member) async {
    final name = member.displayName.isEmpty ? member.id : member.displayName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkDropAgentTitle),
        content: Text(dialogContext.l10n.networkDropAgentBody(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('confirmDropAgent'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.networkDropAgentConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      // Pure-DAP agents go through the hub-agent route; store members
      // (guests and other non-agent classes) through the member route,
      // which also revokes their sessions.
      if (member.memberClass == MemberClass.agent) {
        await session.deleteAgent(member.id);
      } else {
        await session.deleteMember(member.id);
      }
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
              if (_canManageNetwork)
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
                      onRename: _canManageNetwork
                          ? () => unawaited(_renameChannel(channel))
                          : null,
                      onDelete: _canManageNetwork
                          ? () => unawaited(_deleteChannel(channel))
                          : null,
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
  const _NetworkRosterSheet({
    required this.session,
    this.channelId,
    this.canDropAgents = false,
    this.onDropAgent,
  });

  final NetworkSession? session;
  final String? channelId;
  final bool canDropAgents;
  final ValueChanged<Member>? onDropAgent;

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
                  itemBuilder: (context, index) {
                    final member = members[index];
                    final canDrop =
                        canDropAgents &&
                        onDropAgent != null &&
                        member.memberClass != MemberClass.owner &&
                        member.memberClass != MemberClass.admin &&
                        member.id != session.identity.id;
                    return _RosterMemberTile(
                      member: member,
                      channelId: channelId,
                      onDrop: canDrop ? () => onDropAgent!(member) : null,
                    );
                  },
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
  const _RosterMemberTile({required this.member, this.channelId, this.onDrop});

  final Member member;
  final String? channelId;
  final VoidCallback? onDrop;

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
    final accessLabel = _accessLabel(context);
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
          if (accessLabel != null) ...[
            Container(
              key: ValueKey('networkRosterAccess:${member.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                accessLabel,
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: colors.dim),
              ),
            ),
            const SizedBox(width: 10),
          ],
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
          if (onDrop != null)
            IconButton(
              key: ValueKey('dropAgent:${member.id}'),
              onPressed: onDrop,
              icon: const Icon(Icons.person_remove_outlined, size: 19),
              color: Theme.of(context).colorScheme.error,
              tooltip: context.l10n.networkDropAgent,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.only(left: 6),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
        ],
      ),
    );
  }

  String? _accessLabel(BuildContext context) {
    final access = member.access;
    if (access == null) return null;
    final l10n = context.l10n;
    if (access.isNetworkWide) return l10n.networkAccessWholeNetwork;
    if (access.scope != MemberAccessScope.channels) return null;
    final ids = access.channelIds;
    final currentChannel = channelId;
    if (currentChannel == null) return l10n.networkAccessChannels(ids.length);
    if (ids.contains(currentChannel)) {
      if (ids.length == 1) return l10n.networkAccessThisChannelOnly;
      return l10n.networkAccessThisChannelAndOthers(ids.length - 1);
    }
    return l10n.networkAccessOtherChannels(ids.length);
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
    this.onRename,
    this.onDelete,
  });

  final Channel channel;
  final bool selected;
  final NetworkSessionManager manager;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

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
                    channelDisplayLabel(channel.id, channel.name),
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
                      } else if (value == 'rename') {
                        onRename?.call();
                      } else if (value == 'delete') {
                        onDelete?.call();
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'addAgent',
                        child: Text(context.l10n.networkAddAgent),
                      ),
                      if (onRename != null)
                        PopupMenuItem(
                          key: ValueKey('renameChannel:${channel.id}'),
                          value: 'rename',
                          child: Text(context.l10n.networkRenameChannel),
                        ),
                      if (onDelete != null)
                        PopupMenuItem(
                          key: ValueKey('deleteChannel:${channel.id}'),
                          value: 'delete',
                          child: Text(
                            context.l10n.networkDeleteChannel,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
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

/// Rename dialog with the current real name prefilled. Unnamed channels start
/// with an empty field rather than turning their id preview into a real name.
class _RenameChannelDialog extends StatefulWidget {
  const _RenameChannelDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameChannelDialog> createState() => _RenameChannelDialogState();
}

class _RenameChannelDialogState extends State<_RenameChannelDialog> {
  late final TextEditingController _name;
  bool _showRequired = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _showRequired = true);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.networkRenameChannelTitle),
      content: TextField(
        key: const ValueKey('renameChannelName'),
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(
          labelText: context.l10n.networkNameLabel,
          errorText: _showRequired
              ? context.l10n.networkChannelNameRequired
              : null,
        ),
        onChanged: (_) {
          if (_showRequired && _name.text.trim().isNotEmpty) {
            setState(() => _showRequired = false);
          }
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('renameChannelConfirm'),
          onPressed: _submit,
          child: Text(context.l10n.networkRename),
        ),
      ],
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
