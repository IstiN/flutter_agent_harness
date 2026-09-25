// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';

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
  });

  /// The mode controller — the selected channel id comes from here.
  final NetworkModeController controller;

  /// The session manager owning the live [NetworkSession].
  final NetworkSessionManager manager;

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
      _chat = ChannelChatService(session: wanted.$1, channelId: wanted.$2);
      _chatFor = wanted;
      unawaited(wanted.$1.openChannel(wanted.$2));
    }
    return true;
  }

  String _channelLabel(NetworkSession session, String channelId) {
    for (final channel in session.channels) {
      if (channel.id == channelId) return channel.name ?? channel.id;
    }
    return channelId;
  }

  /// A showcase (public channel) is read-only for regular members — only
  /// the owner/admins post (the rail's Showcases section).
  bool _isReadOnlyShowcase(NetworkSession session, String channelId) {
    Channel? channel;
    for (final c in session.channels) {
      if (c.id == channelId) channel = c;
    }
    if (channel == null || !channel.isPublic) return false;
    final memberClass = widget
        .manager
        .wallet
        .networks[widget.controller.networkId]
        ?.memberClass;
    return memberClass != 'owner' && memberClass != 'admin';
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    final chatFor = _chatFor;
    if (chat == null || chatFor == null) {
      return Center(child: Text(context.l10n.networkSelectChannel));
    }
    final session = chatFor.$1;
    final label = _channelLabel(session, chatFor.$2);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        return Column(
          children: [
            if (session.networkOffline) const _OfflineBanner(),
            Expanded(
              child: FaChatStringsScope(
                strings: _ChannelChatStrings(
                  context.l10n.networkMessageHint(label),
                ),
                child: FaChatScreen(
                  key: ValueKey('channelChat:${chatFor.$2}'),
                  service: chat,
                  features: const FaChatFeatures.minimal(),
                  title: label,
                  showAppBar: false,
                  composerBuilder: (context, service, drop) =>
                      _isReadOnlyShowcase(session, chatFor.$2)
                      ? const _ShowcaseReadOnlyNote()
                      : ChannelComposer(
                          service: service,
                          hint: context.l10n.networkMessageHint(label),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The offline banner: the socket queues while the relay is unreachable
/// and flushes once on reconnect (engine contract E1).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

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
        ],
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
                context.l10n.networkShowcaseReadOnly,
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

/// The minimal channel composer (a channel has no attachments, no voice,
/// no approvals — see [FaChatFeatures.minimal]): a text field with the
/// channel-aware hint and a send button. Enter sends.
class ChannelComposer extends StatefulWidget {
  const ChannelComposer({super.key, required this.service, required this.hint});

  /// The chat service the composer sends through.
  final FaChatService service;

  /// The input hint (`Message <channel>`).
  final String hint;

  @override
  State<ChannelComposer> createState() => _ChannelComposerState();
}

class _ChannelComposerState extends State<ChannelComposer> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    try {
      await widget.service.sendText(text);
      if (mounted) _text.clear();
    } on Object catch (e) {
      if (mounted) showFahErrorSnack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => unawaited(_send()),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: colors.border),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('channelSend'),
              icon: Icon(Icons.send, color: colors.indigo),
              tooltip: context.l10n.chatSendTooltip,
              onPressed: () => unawaited(_send()),
            ),
          ],
        ),
      ),
    );
  }
}
