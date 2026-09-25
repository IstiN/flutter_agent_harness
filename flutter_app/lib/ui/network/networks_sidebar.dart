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
import 'package:fa/network/wallet_export.dart' show WalletKdfParams;
import 'package:fa/ui/network/create_network_dialog.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/wallet_menu.dart';

/// The network-mode sidebar content (issue #955): the wallet's network
/// memberships with live badges, a search filter, the `+ Join` / `+ Create`
/// affordances and the wallet overflow menu. Doubles as the narrow
/// layout's network picker (the home page embeds it full-width when no
/// network is selected).
class NetworksSidebar extends StatefulWidget {
  const NetworksSidebar({
    super.key,
    required this.controller,
    required this.manager,
    this.walletExportKdf,
  });

  /// The mode controller — tapping a membership enters the network.
  final NetworkModeController controller;

  /// The session manager — memberships come from its wallet, live badges
  /// from its sessions.
  final NetworkSessionManager manager;

  /// Test seam forwarded to [WalletMenuButton] (fast Argon2id).
  final WalletKdfParams? walletExportKdf;

  @override
  State<NetworksSidebar> createState() => _NetworksSidebarState();
}

class _NetworksSidebarState extends State<NetworksSidebar> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openNetwork(String networkId) async {
    unawaited(widget.controller.enterNetwork(networkId));
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
          child: Row(
            children: [
              Text(
                context.l10n.networkNetworksTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              WalletMenuButton(
                manager: widget.manager,
                exportKdf: widget.walletExportKdf,
              ),
              IconButton(
                key: const ValueKey('joinNetworkButton'),
                icon: const Icon(Icons.add, size: 20),
                tooltip: context.l10n.networkJoinTitle,
                onPressed: () => unawaited(
                  showJoinSheet(
                    context,
                    controller: widget.controller,
                    manager: widget.manager,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.manager.hasJwt)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('createNetworkButton'),
              onPressed: () => unawaited(
                runCreateNetworkFlow(
                  context,
                  controller: widget.controller,
                  manager: widget.manager,
                ),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: Text(context.l10n.networkCreateNetwork),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: context.l10n.networkSearchHint,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.border),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.manager,
            builder: (context, _) => _buildList(colors),
          ),
        ),
      ],
    );
  }

  Widget _buildList(FahColors colors) {
    final query = _searchController.text.trim().toLowerCase();
    final entries = widget.manager.wallet.networks.entries
        .where(
          (e) =>
              query.isEmpty ||
              e.value.name.toLowerCase().contains(query) ||
              e.key.toLowerCase().contains(query),
        )
        .toList();
    if (widget.manager.wallet.networks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.networkEmptyTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: colors.dim),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('joinFirstNetwork'),
                onPressed: () => unawaited(
                  showJoinSheet(
                    context,
                    controller: widget.controller,
                    manager: widget.manager,
                  ),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.l10n.networkJoinFirst),
              ),
            ],
          ),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Text(
          context.l10n.networkNoMatches,
          style: TextStyle(color: colors.dim),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _MembershipTile(
          key: ValueKey('membership:${entry.key}'),
          networkId: entry.key,
          name: entry.value.name,
          memberClass: entry.value.memberClass,
          selected: widget.controller.networkId == entry.key,
          status: _statusOf(entry.key),
          onTap: () => unawaited(_openNetwork(entry.key)),
        );
      },
    );
  }

  _MembershipStatus _statusOf(String networkId) {
    final session = widget.manager.sessions[networkId];
    if (session == null) return _MembershipStatus.idle;
    return session.networkOffline
        ? _MembershipStatus.offline
        : _MembershipStatus.live;
  }
}

enum _MembershipStatus { idle, live, offline }

class _MembershipTile extends StatelessWidget {
  const _MembershipTile({
    super.key,
    required this.networkId,
    required this.name,
    required this.memberClass,
    required this.selected,
    required this.status,
    required this.onTap,
  });

  final String networkId;
  final String name;
  final String memberClass;
  final bool selected;
  final _MembershipStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final dot = switch (status) {
      _MembershipStatus.live => colors.teal,
      _MembershipStatus.offline => Colors.orange,
      _MembershipStatus.idle => colors.dim,
    };
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
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.text,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      Text(
                        '$memberClass · $networkId', // l10n:ignore
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: colors.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
