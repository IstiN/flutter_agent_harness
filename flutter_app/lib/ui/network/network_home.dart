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
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/network/network_mode_chip.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:fa/ui/network/quick_switcher.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart' show faIsMacOSDesktop;

/// The network-mode surface (issue #955), swapped in by `faHomeScreen`
/// when the mode controller says [AppMode.network]:
///
/// - no network selected → the network picker ([NetworksSidebar]:
///   memberships, search, join/create, wallet menu);
/// - network selected → the channel rail plus, on wide layouts, the chat
///   side by side (narrow shows rail OR chat, with a back button);
/// - channel selected → [NetworkChatPage].
///
/// The header always carries the [NetworkModeChip] (the way back to the
/// local surface). A wallet without an identity shows the inline
/// onboarding first (display name → [NetworkSessionManager.ensureIdentity]).
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
    final networkId = widget.controller.networkId;
    if (networkId == null) return;
    if (widget.manager.sessions.containsKey(networkId)) return;
    if (widget.manager.wallet.networks[networkId]?.password == null) return;
    try {
      await widget.manager.resume(networkId);
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
    final wide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
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
              _buildHeader(colors, wide, networkId, channelId),
              Divider(height: 1, color: colors.border),
              Expanded(child: _buildContent(wide, networkId, channelId)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    FahColors colors,
    bool wide,
    String? networkId,
    String? channelId,
  ) {
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

  Widget _buildContent(bool wide, String? networkId, String? channelId) {
    // First-run onboarding: no identity yet → the display-name gate.
    if (!widget.manager.wallet.hasIdentity) {
      return _IdentityOnboarding(manager: widget.manager);
    }
    if (networkId == null) {
      // The network picker (welcome + memberships grid/sidebar content).
      return wide
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: NetworksSidebar(
                  controller: widget.controller,
                  manager: widget.manager,
                ),
              ),
            )
          : NetworksSidebar(
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
    final rail = ChannelRail(
      controller: widget.controller,
      manager: widget.manager,
    );
    if (!wide) {
      return channelId == null
          ? rail
          : NetworkChatPage(
              controller: widget.controller,
              manager: widget.manager,
            );
    }
    return Row(
      children: [
        SizedBox(width: 280, child: rail),
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
  }
}

/// The inline first-run onboarding: a display name field creating the
/// device identity ([NetworkSessionManager.ensureIdentity]). Nothing else
/// is reachable before an identity exists — every join/sign needs it.
class _IdentityOnboarding extends StatefulWidget {
  const _IdentityOnboarding({required this.manager});

  final NetworkSessionManager manager;

  @override
  State<_IdentityOnboarding> createState() => _IdentityOnboardingState();
}

class _IdentityOnboardingState extends State<_IdentityOnboarding> {
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.manager.ensureIdentity(displayName: name);
      widget.manager.walletExternallyUpdated();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showFahErrorSnack(context, '$e');
      }
    }
  }

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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.networkWelcomeBody,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: context.l10n.networkDisplayNameLabel,
                ),
                onSubmitted: (_) => unawaited(_continue()),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('identityContinue'),
                onPressed: _busy ? null : () => unawaited(_continue()),
                child: Text(context.l10n.networkContinue),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
