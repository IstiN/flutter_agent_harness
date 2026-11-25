// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/device_display.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show AgentRunState, NetworkEnvelope, isDmChannel;
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

  /// The (session, channel, DM session) triple [_chat] is bound to.
  (NetworkSession, String, String?)? _chatFor;
  NetworkSession? _listenedSession;

  /// The open DM's peer run view — the standard status row's
  /// [FaChatService] on the REMOTE run; null for ordinary channels.
  /// See [_peerRunFor].
  _DmPeerRunService? _peerRun;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onSourcesChanged);
    widget.manager.addListener(_onSourcesChanged);
    _syncSessionSubscription();
    _syncChat();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSourcesChanged);
    widget.manager.removeListener(_onSourcesChanged);
    _listenedSession?.removeListener(_onSourcesChanged);
    _chat?.dispose();
    _peerRun?.dispose();
    super.dispose();
  }

  void _syncSessionSubscription() {
    final session = _session;
    if (identical(session, _listenedSession)) return;
    _listenedSession?.removeListener(_onSourcesChanged);
    _listenedSession = session;
    session?.addListener(_onSourcesChanged);
  }

  void _onSourcesChanged() {
    _syncSessionSubscription();
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
    final dmSessionId =
        session != null && channelId != null && isDmChannel(channelId)
        ? session.dmSessionTargets[channelId]
        : null;
    final wanted = (session != null && channelId != null)
        ? (session, channelId, dmSessionId)
        : null;
    if (wanted == _chatFor) return false;
    _chat?.dispose();
    _chat = null;
    _chatFor = null;
    if (wanted != null) {
      _chat = ChannelChatService(
        session: wanted.$1,
        channelId: wanted.$2,
        dmSessionId: wanted.$3,
        dmUndecryptablePlaceholder: () =>
            context.l10n.networkDmEncryptedOnAnotherDevice,
        dmEncryptedHistoryDivider: () => context.l10n.networkDmEarlierEncrypted,
      );
      _chatFor = wanted;
      unawaited(wanted.$1.openChannel(wanted.$2));
    }
    return true;
  }

  /// The peer run view for the open channel: created once per (session,
  /// channel) binding — kept across rebuilds so the row's elapsed clock
  /// survives session notifications — exchanged when the binding moves,
  /// and re-bound on every build until the session's device connector
  /// attaches (it can land AFTER the DM opened, review #2196 r1).
  _DmPeerRunService? _peerRunFor(NetworkSession session, String channelId) {
    final current = _peerRun;
    if (current == null || !current.owns(session, channelId)) {
      current?.dispose();
      _peerRun = isDmChannel(channelId)
          ? _DmPeerRunService(session, channelId)
          : null;
      _peerRun?.addListener(_onPeerRunChanged);
    }
    return _peerRun?..ensureBound();
  }

  /// The row is mounted only while the peer is busy (see [build]), so a
  /// published state change rebuilds the page with or without it.
  void _onPeerRunChanged() {
    if (mounted) setState(() {});
  }

  /// The peer's run view while the remote agent is busy; idle, live or
  /// unpublished yields null — no status row is mounted at all.
  static _DmPeerRunService? _whileBusy(_DmPeerRunService? peerRun) =>
      peerRun != null && peerRun.isStreaming ? peerRun : null;

  String _channelLabel(NetworkSession session, String channelId) {
    final name = _channel(session, channelId)?.name;
    if (isDmChannel(channelId)) {
      final sessionTitle = session.dmSessionTitle(channelId)?.trim();
      final sessionId = session.dmSessionTargets[channelId];
      if (sessionId != null && sessionId.isNotEmpty) {
        // The same display-name → project-folder → short-id title opened
        // from Devices drives both the header pill and the composer hint.
        // Legacy raw/compound UUID titles are sanitized here as well.
        return deviceSessionDisplayTitle(id: sessionId, title: sessionTitle);
      }
      if (sessionTitle != null && sessionTitle.isNotEmpty) {
        return sessionTitle;
      }
      // Server/inbox restores may carry the raw virtual id, or an old label
      // containing the raw device id, as `name`. The DM parser owns the one
      // sanitizing path used by both the header and composer.
      final usableName = name?.trim();
      return dmChannelPeerLabel(
        channelId,
        deviceLabel: usableName == channelId ? null : usableName,
      );
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

  Widget? _dynamicTile(BuildContext context, FaChatMessage message) {
    if (message.data != ChannelChatService.encryptedHistoryDividerData) {
      return null;
    }
    return _DmEncryptedHistoryDivider(label: message.content);
  }

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
        final busyPeer = _whileBusy(_peerRunFor(session, chatFor.$2));
        return Column(
          children: [
            if (widget.showChannelHeader)
              _ChannelHeader(
                channel: channel,
                label: label,
                manager: widget.manager,
              ),
            Expanded(
              child: FaChatStringsScope(
                strings: _ChannelChatStrings(
                  context.l10n.networkMessageHint(label),
                ),
                child: FaChatScreen(
                  key: ValueKey(
                    chatFor.$3 == null
                        ? 'channelChat:${chatFor.$2}'
                        : 'channelChat:${chatFor.$2}:${chatFor.$3}',
                  ),
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
                  // The shared notice slot floats over the transcript, so
                  // reconnecting never changes the chat's layout geometry.
                  noticeBanner: session.networkOffline
                      ? _OfflineBanner(session: session)
                      : null,
                  // The DM peer's run rides the SAME standard status row a
                  // local run does (the visually-last transcript entry,
                  // right above the composer): mounted only while the
                  // remote agent is busy — idle, live or unpublished is
                  // simply absent, never a header strip. The in-list row
                  // itself reads the channel service, which never streams
                  // (a REMOTE run must not flip the composer's own
                  // streaming state), so the peer's run view docks in the
                  // input-header slot and exactly one status row shows.
                  inputHeader: busyPeer == null
                      ? null
                      : FaRunStatusRow(service: busyPeer),
                  // Network channels are the same transparent chat surface
                  // as Local sessions, never an opaque black Scaffold.
                  wallpaperBuilder: (_) => const FahWallpaper(),
                  mentionOptionsBuilder: (query) =>
                      _mentionOptions(session, query),
                  projectIcon: widget.showAppBar
                      ? (channel?.isPublic == true ? Icons.public : Icons.tag)
                      : null,
                  projectLabel: isDmChannel(chatFor.$2)
                      ? null
                      : widget.projectLabel,
                  dynamicWidgetTileBuilder: _dynamicTile,
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

/// One quiet divider replaces a run of foreign-encrypted history bubbles.
class _DmEncryptedHistoryDivider extends StatelessWidget {
  const _DmEncryptedHistoryDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      key: const ValueKey('dmEncryptedHistoryDivider'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: colors.border)),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.dim, fontSize: 11),
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: colors.border)),
        ],
      ),
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
      key: const ValueKey('networkReconnectingBanner'),
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

/// The peer run state's pure transition (its own function so the
/// refresh stays a two-branch setter under the CRAP ratchet, and the
/// guard semantics are unit-testable without pumping a widget tree).
/// Review #2196 round 1: `null` must NOT overload "unchanged" and "agent
/// gone" — a peer disappearing from the roster while busy has to CLEAR
/// the status, so the result is `changed` + the (nullable) next state.
@visibleForTesting
({bool changed, AgentRunState? state}) dmRefreshedAgentRunState({
  required DeviceConnectorService? connector,
  required String? address,
  required String? networkId,
  required AgentRunState? current,
}) {
  if (connector == null || address == null || networkId == null) {
    return (changed: false, state: current);
  }
  final next = connector.agentRunState(address, networkId: networkId);
  return (changed: next != current, state: next);
}

/// The DM peer's run as the standard [FaRunStatusRow] reads it — the
/// visible acknowledgement that the remote agent picked the owner's
/// message up (owner feedback). `isStreaming` is the Devices roster's
/// busy flag; the roster publishes busy/idle only, never a phase, so
/// [messages] stays empty and [faRunPhase] holds the row on its
/// provider-wait («Thinking...») label for the whole run.
///
/// ONLY the status row consumes this view: [isStreaming], [messages] and
/// the [Listenable] are its whole contract. The chat keeps the real
/// [ChannelChatService] — a REMOTE run must not flip the local composer
/// into its own streaming state (stop capsule, follow-lock) — so every
/// other [FaChatService] member fails loudly instead of guessing.
///
/// The state plumbing is the one the retired header banner owned
/// (review #2196): `DeviceConnectorService.agentRunState` re-read on every
/// roster or presence frame of the session's device connector; `null`
/// while nothing is published (no connector yet, agent off the roster).
final class _DmPeerRunService extends ChangeNotifier implements FaChatService {
  _DmPeerRunService(this._session, this._channelId);

  final NetworkSession _session;
  final String _channelId;
  DeviceConnectorService? _connector;
  String? _address;
  AgentRunState? _state;
  final List<StreamSubscription<NetworkEnvelope>> _subs = [];

  /// Whether this view belongs to [session]'s [channelId].
  bool owns(NetworkSession session, String channelId) =>
      identical(_session, session) && _channelId == channelId;

  /// Binds to the session's device connector; a no-op once bound. Runs
  /// from build so a connector attaching AFTER the DM opened (digest,
  /// review #2196 r1) still goes live on the next frame.
  void ensureBound() {
    if (_connector != null) return;
    final connector = _session.dmConnector;
    final parts = parseDmChannelId(_channelId);
    if (connector == null || parts == null) return;
    _connector = connector;
    _address = '${parts.agentName}@${parts.deviceId}';
    _state = connector.agentRunState(_address!, networkId: _session.networkId);
    _subs.add(connector.rosterFrames.listen((_) => _refresh()));
    _subs.add(connector.presenceFrames.listen((_) => _refresh()));
  }

  void _refresh() {
    final next = dmRefreshedAgentRunState(
      connector: _connector,
      address: _address,
      networkId: _session.networkId,
      current: _state,
    );
    if (!next.changed) return;
    _state = next.state;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    super.dispose();
  }

  // FaChatService — the status row's whole read surface.

  @override
  bool get isStreaming => _state == AgentRunState.busy;

  @override
  List<FaChatMessage> get messages => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '_DmPeerRunService is the DM peer run view for FaRunStatusRow only '
    '(isStreaming, messages); ${invocation.memberName} is not modelled.',
  );
}
