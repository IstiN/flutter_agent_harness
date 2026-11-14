// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show isDmChannel;
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/widgets/fah_wallpaper.dart';

import 'add_agent_dialog.dart';
import 'channel_key_import_dialog.dart';
import 'channel_rail.dart';

/// The channel chat surface (issue #955): the shared [FaChatScreen] over a
/// [ChannelChatService] with `FaChatFeatures.minimal()` — plain text
/// in/text out. Owns the service lifecycle: created when the selected
/// channel changes, disposed on leave. A slim banner shows while the relay
/// reports the network offline (the socket queues, messages flush on
/// reconnect).
class NetworkChatPage extends StatefulWidget {
  const NetworkChatPage({
    super.key,
    required this.controller,
    required this.manager,
    this.showAppBar = false,
    this.showChannelHeader = true,
    this.projectLabel,
    this.onProjectTap,
  });

  /// The mode controller — the selected channel id comes from here.
  final NetworkModeController controller;

  /// The session manager owning the live [NetworkSession].
  final NetworkSessionManager manager;

  /// Uses the shared adaptive chat header instead of an embedded bare body.
  final bool showAppBar;

  /// The legacy network-home channel strip; disabled in the messenger shell.
  final bool showChannelHeader;

  /// Network identity in the shared adaptive header's project slot.
  final String? projectLabel;

  /// Opens network details from the shared header's project slot.
  final VoidCallback? onProjectTap;

  @override
  State<NetworkChatPage> createState() => _NetworkChatPageState();
}

class _NetworkChatPageState extends State<NetworkChatPage> {
  ChannelChatService? _chat;

  /// The (session, channel) pair [_chat] is bound to.
  (NetworkSession, String)? _chatFor;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onSourcesChanged);
    widget.manager.addListener(_onSourcesChanged);
    _syncChat();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSourcesChanged);
    widget.manager.removeListener(_onSourcesChanged);
    _chat?.dispose();
    super.dispose();
  }

  void _onSourcesChanged() {
    if (_syncChat() && mounted) setState(() {});
  }

  NetworkSession? get _session =>
      widget.manager.sessions[widget.controller.networkId];

  /// Recreates the chat service when the (network, channel) selection
  /// moved (or the session landed after a resume); disposes it when no
  /// channel is selected. Returns true when the binding changed. Kill/
  /// resume safe: opening a channel is idempotent in the engine.
  bool _syncChat() {
    final session = _session;
    final channelId = widget.controller.channelId;
    final wanted = (session != null && channelId != null)
        ? (session, channelId)
        : null;
    if (wanted == _chatFor) return false;
    _chat?.dispose();
    _chat = null;
    _chatFor = null;
    if (wanted != null) {
      _chat = ChannelChatService(
        session: wanted.$1,
        channelId: wanted.$2,
        dmUndecryptablePlaceholder: () =>
            context.l10n.networkDmEncryptedOnAnotherDevice,
      );
      _chatFor = wanted;
      unawaited(wanted.$1.openChannel(wanted.$2));
    }
    return true;
  }

  String _channelLabel(NetworkSession session, String channelId) {
    final name = _channel(session, channelId)?.name;
    if (isDmChannel(channelId)) {
      // Server/inbox restores may carry the raw virtual id as `name`.
      // Never leak that routing identifier into the title or composer.
      final usableName = name?.trim();
      if (usableName != null &&
          usableName.isNotEmpty &&
          usableName != channelId) {
        return usableName;
      }
      return dmChannelPeerLabel(channelId);
    }
    return channelDisplayLabel(channelId, name);
  }

  Channel? _channel(NetworkSession session, String channelId) {
    for (final channel in session.channels) {
      if (channel.id == channelId) return channel;
    }
    return null;
  }

  /// A showcase (public channel) is read-only for regular members — only
  /// the owner/admins post (the rail's Showcases section).
  bool _isReadOnlyShowcase(NetworkSession session, String channelId) {
    final channel = _lastChannel(session, channelId);
    if (channel == null || !channel.isPublic) return false;
    return _regularMember(session);
  }

  /// A private channel is writable only when this device's wallet holds its
  /// E2E key. Network ownership/membership cannot substitute for that key.
  /// DM virtual channels are exempt: their transport is fanet1 sealed to
  /// the identity key, never the per-channel key ring (issue #2062).
  bool _isMissingPrivateKey(NetworkSession session, String channelId) {
    if (isDmChannel(channelId)) return false;
    final channel = _lastChannel(session, channelId);
    if (channel == null || channel.isPublic) return false;
    return widget.manager.wallet.channelKeysFor(
          widget.controller.networkId!,
          channelId,
        ) ==
        null;
  }

  /// The channel row for [channelId]; ids are unique per session but the
  /// scan keeps the LAST match, exactly like the lookup it replaces.
  Channel? _lastChannel(NetworkSession session, String channelId) {
    Channel? channel;
    for (final c in session.channels) {
      if (c.id == channelId) channel = c;
    }
    return channel;
  }

  /// True unless this wallet's membership is owner/admin.
  bool _regularMember(NetworkSession session) {
    final memberClass = widget
        .manager
        .wallet
        .networks[widget.controller.networkId]
        ?.memberClass;
    return memberClass != 'owner' && memberClass != 'admin';
  }

  Future<void> _showChannelDetails(NetworkSession session) {
    final networkId = widget.controller.networkId;
    final channelId = widget.controller.channelId;
    final channel = channelId == null ? null : _channel(session, channelId);
    if (networkId == null || channelId == null) return Future<void>.value();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: session,
        builder: (context, _) => NetworkRosterSheet(
          key: const ValueKey('channelDetailsSheet'),
          session: session,
          channelId: channelId,
          title: _channelLabel(session, channelId),
          titleIcon: channel?.isPublic == true ? Icons.public : Icons.tag,
          actions: [
            IconButton(
              key: const ValueKey('channelDetailsAddAgent'),
              tooltip: context.l10n.networkAddAgent,
              icon: const Icon(Icons.smart_toy_outlined),
              onPressed: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  showDialog<void>(
                    context: this.context,
                    builder: (_) => AddAgentDialog(
                      wallet: widget.manager.wallet,
                      manager: widget.manager,
                      networkId: networkId,
                      channel: channel,
                      initialScope: AgentInviteScope.channel,
                    ),
                  ),
                );
              },
            ),
            IconButton(
              key: const ValueKey('channelDetailsInvitePerson'),
              tooltip: context.l10n.networkInvitePerson,
              icon: const Icon(Icons.person_add_alt),
              onPressed: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  showDialog<void>(
                    context: this.context,
                    builder: (_) => _InvitePersonDialog(
                      manager: widget.manager,
                      networkId: networkId,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  List<FaChatMentionOption> _mentionOptions(
    NetworkSession session,
    String query,
  ) {
    final normalized = query.toLowerCase();
    final matches = session.roster.values
        .where(
          (member) =>
              member.displayName.isNotEmpty &&
              member.displayName.toLowerCase().startsWith(normalized),
        )
        .toList();
    matches.sort((a, b) {
      final byPresence = _presenceRank(
        a.presence,
      ).compareTo(_presenceRank(b.presence));
      if (byPresence != 0) return byPresence;
      final byName = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return [
      for (final member in matches)
        FaChatMentionOption(
          id: member.id,
          label: member.displayName,
          icon: member.memberClass == MemberClass.agent
              ? Icons.smart_toy_outlined
              : Icons.person_outline,
          online: member.presence == Presence.live,
        ),
    ];
  }

  static int _presenceRank(Presence presence) => switch (presence) {
    Presence.live => 0,
    Presence.busy => 1,
    _ => 2,
  };

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    final chatFor = _chatFor;
    if (chat == null || chatFor == null) {
      return Center(child: Text(context.l10n.networkSelectChannel));
    }
    final session = chatFor.$1;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final channel = _channel(session, chatFor.$2);
        final label = _channelLabel(session, chatFor.$2);
        return Column(
          children: [
            if (widget.showChannelHeader)
              _ChannelHeader(
                channel: channel,
                label: label,
                manager: widget.manager,
              ),
            if (session.networkOffline) _OfflineBanner(session: session),
            Expanded(
              child: FaChatStringsScope(
                strings: _ChannelChatStrings(
                  context.l10n.networkMessageHint(label),
                ),
                child: FaChatScreen(
                  key: ValueKey('channelChat:${chatFor.$2}'),
                  service: chat,
                  features: const FaChatFeatures(
                    attachments: false,
                    voiceInput: false,
                    approvals: false,
                    askSheets: false,
                    secretRequests: false,
                    mediaPlayback: false,
                    thinkingBlocks: false,
                    fileBrowser: false,
                    appLauncher: false,
                    trajectory: false,
                  ),
                  title: label,
                  showAppBar: widget.showAppBar,
                  // Network channels are the same transparent chat surface
                  // as Local sessions, never an opaque black Scaffold.
                  wallpaperBuilder: (_) => const FahWallpaper(),
                  mentionOptionsBuilder: (query) =>
                      _mentionOptions(session, query),
                  projectIcon: widget.showAppBar
                      ? (channel?.isPublic == true ? Icons.public : Icons.tag)
                      : null,
                  projectLabel: widget.projectLabel,
                  onProjectTap:
                      widget.onProjectTap ??
                      () => unawaited(_showChannelDetails(session)),
                  // Writable channels use the SAME shared composer as local
                  // sessions. Only a read-only showcase or a missing E2E key
                  // replaces it with the corresponding explanation.
                  composerBuilder: _isReadOnlyShowcase(session, chatFor.$2)
                      ? (context, service, drop) =>
                            const _ShowcaseReadOnlyNote()
                      : _isMissingPrivateKey(session, chatFor.$2)
                      ? (context, service, drop) => _MissingChannelKeyComposer(
                          manager: widget.manager,
                          session: session,
                          networkId: widget.controller.networkId!,
                          channelId: chatFor.$2,
                          // A successful import swaps this composer for
                          // the real one; rebuild deterministically from
                          // the dialog result instead of relying on the
                          // session-notify relay.
                          onKeyImported: () {
                            if (mounted) setState(() {});
                          },
                        )
                      : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InvitePersonDialog extends StatelessWidget {
  const _InvitePersonDialog({required this.manager, required this.networkId});

  final NetworkSessionManager manager;
  final String networkId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final invite = buildNetworkJoinLink(
      host: Uri.parse(AddAgentDialog.networkJoinHost),
      networkId: networkId,
      password: manager.wallet.networks[networkId]?.password,
    );
    return AlertDialog(
      key: const ValueKey('invitePersonDialog'),
      title: Text(l10n.networkInvitePersonTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.networkInvitePersonBody),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: FahColors.of(context).panelAlt,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  invite,
                  key: const ValueKey('invitePersonLink'),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.networkClose),
        ),
        FilledButton.icon(
          key: const ValueKey('invitePersonCopy'),
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: invite)));
            showFahSnack(context, l10n.networkInviteCopied);
          },
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: Text(l10n.networkCopy),
        ),
      ],
    );
  }
}

/// The offline banner: the socket queues while the relay is unreachable
/// and flushes once on reconnect (engine contract E1).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.session});

  final NetworkSession session;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Container(
      width: double.infinity,
      color: colors.pending.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 16, color: colors.pending),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.networkReconnecting,
              style: TextStyle(fontSize: 12, color: colors.text),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: context.l10n.networkReconnectNow,
            onPressed: session.reconnect,
            icon: Icon(Icons.refresh, size: 18, color: colors.text),
          ),
        ],
      ),
    );
  }
}

/// Composer replacement for a private channel whose E2E key exists only on
/// another device. The network password grants membership, never this key.
class _MissingChannelKeyComposer extends StatelessWidget {
  const _MissingChannelKeyComposer({
    required this.manager,
    required this.session,
    required this.networkId,
    required this.channelId,
    required this.onKeyImported,
  });

  final NetworkSessionManager manager;
  final NetworkSession session;
  final String networkId;
  final String channelId;

  /// Called when the import dialog reported success — the page rebuilds
  /// so the composer swap does not depend on the session-notify relay.
  final VoidCallback onKeyImported;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: colors.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.networkChannelKeyMissing,
                    style: TextStyle(color: colors.dim, fontSize: 12),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  final imported = await showChannelKeyImportDialog(
                    context,
                    wallet: manager.wallet,
                    session: session,
                    networkId: networkId,
                    channelId: channelId,
                  );
                  if (imported && context.mounted) onKeyImported();
                },
                icon: const Icon(Icons.key_outlined, size: 18),
                label: Text(context.l10n.networkChannelKeyImport),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The read-only note replacing the composer in a showcase (public
/// channel) for regular members — only the owner/admins post.
class _ShowcaseReadOnlyNote extends StatelessWidget {
  const _ShowcaseReadOnlyNote();

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.public, size: 16, color: colors.dim),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                context.l10n.networkShowcaseMemberReadOnly,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.dim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat strings with the channel-aware composer hint
/// (`Message <channel>`, localized); everything else is the stock
/// English set.
class _ChannelChatStrings extends FaChatStringsEn {
  const _ChannelChatStrings(this.inputHint);

  /// The localized composer hint (`Message <channel>`).
  final String inputHint;

  @override
  String get chatInputHint => inputHint;
}

/// The slim channel header: lock/globe + name, and for private channels
/// the add-agent action (AC-B17) — the discoverable entry point the
/// rail's overflow menu mirrors.
class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.channel,
    required this.label,
    required this.manager,
  });

  final Channel? channel;
  final String label;
  final NetworkSessionManager manager;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final channel = this.channel;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            channel?.isPublic ?? false ? Icons.public : Icons.lock_outline,
            size: 16,
            color: colors.dim,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
          ),
          if (channel != null)
            IconButton(
              key: const ValueKey('channelAddAgent'),
              icon: Icon(Icons.person_add_alt, size: 20, color: colors.dim),
              tooltip: context.l10n.networkAddAgent,
              onPressed: () => unawaited(
                showDialog<void>(
                  context: context,
                  builder: (_) => AddAgentDialog(
                    wallet: manager.wallet,
                    manager: manager,
                    networkId: channel.networkId,
                    channel: channel,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
