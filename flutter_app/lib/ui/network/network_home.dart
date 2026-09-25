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
import 'package:fa/ui/network/network_center.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/network/network_mode_chip.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:fa/ui/network/quick_switcher.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart' show faIsMacOSDesktop;

/// The NARROW network-mode surface (issue #955), swapped in by
/// `faHomeScreen` when the mode controller says [AppMode.network] (wide
/// desktops never see this page — the [WideLayoutShell] swaps its sidebar
/// and center in place instead):
///
/// - no network selected → the network picker ([NetworksSidebar]:
///   memberships, search, join/create, wallet menu) — this IS the first
///   screen, there is no identity onboarding gate (identity is created
///   lazily at join/send);
/// - network selected → the channel rail, with a back button to the
///   picker;
/// - channel selected → [NetworkChatPage].
///
/// The header always carries the [NetworkModeChip] (the way back to the
/// local surface).
class NetworkHomePage extends StatefulWidget {
  const NetworkHomePage({
    super.key,
    required this.controller,
    required this.manager,
  });

  /// The mode navigation state machine.
  final NetworkModeController controller;

  /// The session manager (wallet, memberships, live sessions).
  final NetworkSessionManager manager;

  @override
  State<NetworkHomePage> createState() => _NetworkHomePageState();
}

class _NetworkHomePageState extends State<NetworkHomePage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_ensureSession);
    widget.manager.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSession());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_ensureSession);
    widget.manager.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// A restored selection (boot relaunch) has no live session — silently
  /// re-join with the wallet password. Fire-and-forget; failures surface
  /// as a snackbar and leave the picker reachable.
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
    final colors = FahColors.of(context);
    final networkId = widget.controller.networkId;
    final channelId = widget.controller.channelId;
    return NetworkQuickSwitcher(
      controller: widget.controller,
      manager: widget.manager,
      child: Scaffold(
        backgroundColor: colors.bg,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(colors, networkId, channelId),
              Divider(height: 1, color: colors.border),
              Expanded(child: _buildContent(networkId, channelId)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(FahColors colors, String? networkId, String? channelId) {
    final wallet = widget.manager.wallet;
    final networkName = networkId == null
        ? null
        : (wallet.networks[networkId]?.name ?? networkId);
    return Padding(
      // macOS: the traffic lights float over the window's top strip
      // (fullSizeContentView) — clear them exactly like the local shell's
      // sidebar header does.
      padding: EdgeInsets.fromLTRB(8, faIsMacOSDesktop ? 32 : 8, 12, 8),
      child: Row(
        children: [
          if (networkId != null)
            IconButton(
              key: const ValueKey('networkBack'),
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: context.l10n.networkBackTooltip,
              onPressed: () => unawaited(
                channelId != null
                    ? widget.controller.backToChannels()
                    : widget.controller.backToNetworks(),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: FaBrandTile(size: 24),
            ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              networkName ?? context.l10n.networkNetworksTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          NetworkModeChip(
            controller: widget.controller,
            manager: widget.manager,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(String? networkId, String? channelId) {
    if (networkId == null) {
      // The network picker — the first screen of the narrow flow.
      return NetworksSidebar(
        controller: widget.controller,
        manager: widget.manager,
      );
    }
    final session = widget.manager.sessions[networkId];
    if (session == null) {
      // A restored selection waiting for the silent resume (or a failed
      // one — the snackbar already said why).
      return const Center(child: CircularProgressIndicator());
    }
    return channelId == null
        ? ChannelRail(controller: widget.controller, manager: widget.manager)
        : NetworkChatPage(
            controller: widget.controller,
            manager: widget.manager,
          );
  }
}
