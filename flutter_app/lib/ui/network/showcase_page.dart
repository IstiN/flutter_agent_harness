// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/showcase_chat_service.dart';
import 'package:fa/network/showcase_viewer.dart';

/// The anonymous read-only showcase page (issue #955): a public network's
/// public channels, browsable without join or password. Left: the channel
/// list; right: the shared Grok-style chat with the composer replaced by
/// a read-only note. Everything rides [ShowcaseViewer] — REST only, no
/// socket, no wallet.
class ShowcasePage extends StatefulWidget {
  const ShowcasePage({
    super.key,
    required this.controller,
    required this.manager,
  });

  final NetworkModeController controller;

  /// Borrowed for its base URL + http client (the viewer is anonymous —
  /// no tokens are ever sent).
  final NetworkSessionManager manager;

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

class _ShowcasePageState extends State<ShowcasePage> {
  ShowcaseViewer? _viewer;
  String? _viewerFor;
  String? _channelId;
  ShowcaseChatService? _chat;

  @override
  void dispose() {
    _chat?.dispose();
    super.dispose();
  }

  void _sync(String? networkId) {
    if (networkId == null || networkId == _viewerFor) return;
    _chat?.dispose();
    _chat = null;
    _channelId = null;
    _viewerFor = networkId;
    _viewer = widget.manager.newShowcaseViewer(networkId);
    unawaited(_viewer!.load());
  }

  void _openChannel(String channelId) {
    _chat?.dispose();
    _chat = ShowcaseChatService(viewer: _viewer!, channelId: channelId);
    setState(() => _channelId = channelId);
    unawaited(_viewer!.loadMessages(channelId));
  }

  @override
  Widget build(BuildContext context) {
    final networkId = widget.controller.showcaseNetworkId;
    _sync(networkId);
    final viewer = _viewer;
    final colors = FahColors.of(context);
    if (networkId == null || viewer == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: viewer,
      builder: (context, _) {
        final showcase = viewer.showcase;
        if (showcase == null) {
          if (viewer.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          // Generic 404 by contract (unknown or non-public) — no details.
          return Center(
            child: Text(
              context.l10n.networkShowcaseUnavailable,
              style: TextStyle(color: colors.dim),
            ),
          );
        }
        return Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('showcaseBack'),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    onPressed: () =>
                        unawaited(widget.controller.backToNetworks()),
                    tooltip: context.l10n.networkBackToNetworks,
                  ),
                  Icon(Icons.public, size: 16, color: colors.dim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      showcase.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    context.l10n.networkShowcaseReadOnlyBadge,
                    style: TextStyle(color: colors.dim, fontSize: 11),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      children: [
                        for (final channel in showcase.channels)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Material(
                              color: _channelId == channel.id
                                  ? colors.panelAlt
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => _openChannel(channel.id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.public,
                                        size: 14,
                                        color: colors.dim,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          channel.name ?? channel.id,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  VerticalDivider(width: 1, color: colors.border),
                  Expanded(
                    child: _channelId == null || _chat == null
                        ? Center(
                            child: Text(
                              context.l10n.networkSelectChannel,
                              style: TextStyle(color: colors.dim),
                            ),
                          )
                        : FaChatScreen(
                            key: ValueKey('showcase:$_channelId'),
                            service: _chat!,
                            features: const FaChatFeatures.minimal(),
                            title: _channelId ?? '',
                            showAppBar: false,
                            composerBuilder: (context, service, drop) =>
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(10),
                                  color: colors.panelAlt,
                                  child: Text(
                                    context.l10n.networkShowcaseReadOnly,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: colors.dim,
                                      fontSize: 12,
                                    ),
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
    );
  }
}
