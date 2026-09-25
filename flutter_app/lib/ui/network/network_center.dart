// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:fa/ui/network/create_network_dialog.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/network_chat_page.dart';

/// Silently re-joins the selected network when a restored selection (boot
/// relaunch) has no live session — the wallet's stored password is enough
/// (the contract's sessionToken is memory-only). Fire-and-forget for the
/// caller; failures throw for the caller to surface as a snackbar and
/// leave the picker reachable. Shared by the narrow [NetworkHomePage] and
/// the wide [NetworkCenterPane].
Future<void> ensureNetworkSession(
  NetworkModeController controller,
  NetworkSessionManager manager,
) async {
  final networkId = controller.networkId;
  if (networkId == null) return;
  if (manager.sessions.containsKey(networkId)) return;
  if (manager.wallet.networks[networkId]?.password == null) return;
  await manager.resume(networkId);
}

/// The wide shell's CENTER area in network mode (issue #955, owner
/// feedback: network mode lives INSIDE the shells, never a full-screen
/// takeover):
///
/// - no network selected → the welcome empty state with the Join/Create
///   entry points (the "сразу список/авторизация" the owner asked for);
/// - network selected → the [ChannelRail] beside the [NetworkChatPage]
///   (or the select-a-channel placeholder).
///
/// Owns the silent resume of a restored selection (see
/// [ensureNetworkSession]).
class NetworkCenterPane extends StatefulWidget {
  const NetworkCenterPane({
    super.key,
    required this.controller,
    required this.manager,
  });

  /// The mode navigation state machine.
  final NetworkModeController controller;

  /// The session manager (wallet, memberships, live sessions).
  final NetworkSessionManager manager;

  @override
  State<NetworkCenterPane> createState() => _NetworkCenterPaneState();
}

class _NetworkCenterPaneState extends State<NetworkCenterPane> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_ensureSession);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSession());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_ensureSession);
    super.dispose();
  }

  Future<void> _ensureSession() async {
    try {
      await ensureNetworkSession(widget.controller, widget.manager);
    } on StateError catch (e) {
      if (mounted) showFahErrorSnack(context, e.message);
    } on FaNetworkException catch (e) {
      if (mounted) showFahErrorSnack(context, e.message);
    } on Object catch (e) {
      if (mounted) showFahErrorSnack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, widget.manager]),
      builder: (context, _) {
        final networkId = widget.controller.networkId;
        if (networkId == null) {
          return _NetworkEmptyState(
            controller: widget.controller,
            manager: widget.manager,
          );
        }
        final session = widget.manager.sessions[networkId];
        if (session == null) {
          // A restored selection waiting for the silent resume (or a
          // failed one — the snackbar already said why).
          return const Center(child: CircularProgressIndicator());
        }
        final channelId = widget.controller.channelId;
        return Row(
          children: [
            SizedBox(
              width: 260,
              child: ChannelRail(
                controller: widget.controller,
                manager: widget.manager,
              ),
            ),
            VerticalDivider(width: 1, color: FahColors.of(context).border),
            Expanded(
              child: channelId == null
                  ? Center(
                      child: Text(
                        context.l10n.networkSelectChannel,
                        style: TextStyle(color: FahColors.of(context).dim),
                      ),
                    )
                  : NetworkChatPage(
                      controller: widget.controller,
                      manager: widget.manager,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// The wide network-mode welcome pane: a short welcome line plus the two
/// entry points — join an existing network, create a new one (owner flow,
/// shown only with a JWT, matching the sidebar's affordance).
class _NetworkEmptyState extends StatelessWidget {
  const _NetworkEmptyState({required this.controller, required this.manager});

  final NetworkModeController controller;
  final NetworkSessionManager manager;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.networkWelcomeTitle,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.networkWelcomeBody,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('networkCenterJoin'),
                onPressed: () => unawaited(
                  showJoinSheet(
                    context,
                    controller: controller,
                    manager: manager,
                  ),
                ),
                icon: const Icon(Icons.login, size: 18),
                label: Text(context.l10n.networkJoinTitle),
              ),
              if (manager.hasJwt) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('networkCenterCreate'),
                  onPressed: () => unawaited(
                    runCreateNetworkFlow(
                      context,
                      controller: controller,
                      manager: manager,
                    ),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(context.l10n.networkCreateNetwork),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
