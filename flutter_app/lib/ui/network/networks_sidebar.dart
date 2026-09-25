// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/models.dart' show PublicNetworkInfo;
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/wallet_export.dart' show WalletKdfParams;
import 'package:fa/ui/network/create_network_dialog.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:fa/ui/network/wallet_menu.dart';
import 'package:fa/ui/widgets/session_search_field.dart';

/// The network-mode sidebar content (issue #955, iteration 2): visually
/// mirrors the sessions list in the wide shell — the same small-caps
/// section header with a circle-outline `+` button, the same search
/// field, and single-row membership tiles (status dot + name). Adds the
/// account row (sign in / signed-in + sign out), the `+ Create` gate for
/// JWT holders, and the public-networks directory section (only when the
/// server ships `GET /api/networks/public`). Doubles as the narrow
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
  /// from its sessions, the JWT/account state drives the account row.
  final NetworkSessionManager manager;

  /// Test seam forwarded to [WalletMenuButton] (fast Argon2id).
  final WalletKdfParams? walletExportKdf;

  @override
  State<NetworksSidebar> createState() => _NetworksSidebarState();
}

class _NetworksSidebarState extends State<NetworksSidebar> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  /// The public-networks directory snapshot; null = absent (endpoint not
  /// deployed, not permitted, empty, or not yet fetched) — the section
  /// simply never renders then.
  List<PublicNetworkInfo>? _publicNetworks;

  /// The membership set the last directory fetch was issued for — a join
  /// (wallet mutation) re-probes, the "pull-to-refresh" equivalent.
  Set<String> _fetchedForMemberships = {};

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    _fetchedForMemberships = _membershipIds;
    unawaited(_fetchPublicNetworks());
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Set<String> get _membershipIds => widget.manager.wallet.networks.keys.toSet();

  void _onManagerChanged() {
    final ids = _membershipIds;
    if (!setEquals(ids, _fetchedForMemberships)) {
      _fetchedForMemberships = ids;
      unawaited(_fetchPublicNetworks());
    }
  }

  /// Silent probe: failures (offline, rate-limited, malformed) leave the
  /// section hidden — never an error in the UI. Only the first page is
  /// fetched (50 entries; lazy pagination is a later polish).
  Future<void> _fetchPublicNetworks() async {
    List<PublicNetworkInfo>? items;
    try {
      items = (await widget.manager.listPublicNetworks())?.items;
    } on Object {
      items = null;
    }
    if (!mounted) return;
    final usable = (items == null || items.isEmpty) ? null : items;
    if (usable == null && _publicNetworks == null) return;
    setState(() => _publicNetworks = usable);
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

  Future<void> _openJoinSheet({String? networkId}) => showJoinSheet(
    context,
    controller: widget.controller,
    manager: widget.manager,
    initialNetworkId: networkId,
  );

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header — mirrors the sessions list's: small-caps dim section
        // label + the circle-outline `+` IconButton (opens the join
        // sheet). The wallet ⋮ keeps export/import reachable (the
        // sessions header has no equivalent affordance).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Text(
                context.l10n.networkNetworksTitle.toUpperCase(),
                style: TextStyle(
                  color: colors.dim,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              WalletMenuButton(
                manager: widget.manager,
                exportKdf: widget.walletExportKdf,
              ),
              IconButton(
                key: const ValueKey('joinNetworkButton'),
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => unawaited(_openJoinSheet()),
                tooltip: context.l10n.networkJoinTitle,
                iconSize: 20,
                color: colors.dim,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
        // The account row + the JWT-gated create affordance.
        ListenableBuilder(
          listenable: widget.manager,
          builder: (context, _) => _buildAccountArea(colors),
        ),
        // The search row — the same SessionSearchField the sessions list
        // pins between the header and the list.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: SessionSearchField(
            controller: _searchController,
            focusNode: _searchFocus,
            hintText: context.l10n.networkSearchHint,
            onQueryChanged: (q) {
              if (q != _query) setState(() => _query = q);
            },
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.manager,
            builder: (context, _) => _buildBody(colors),
          ),
        ),
      ],
    );
  }

  /// Sign-in row (guest) or the signed-in account with a sign-out action.
  Widget _buildAccountArea(FahColors colors) {
    final manager = widget.manager;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!manager.hasJwt)
          InkWell(
            key: const ValueKey('signInRow'),
            onTap: () => unawaited(showSignInDialog(context, manager: manager)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.login, size: 16, color: colors.dim),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.networkSignInTitle,
                    style: TextStyle(color: colors.dim, fontSize: 13),
                  ),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Icon(
                  Icons.account_circle_outlined,
                  size: 16,
                  color: colors.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    manager.accountLogin ?? context.l10n.networkAccountFallback,
                    key: const ValueKey('accountLabel'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.text, fontSize: 13),
                  ),
                ),
                TextButton(
                  key: const ValueKey('signOutButton'),
                  onPressed: manager.signOut,
                  child: Text(context.l10n.networkSignOut),
                ),
              ],
            ),
          ),
        if (manager.hasJwt)
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
      ],
    );
  }

  Widget _buildBody(FahColors colors) {
    final query = _query.trim().toLowerCase();
    final entries = widget.manager.wallet.networks.entries
        .where(
          (e) =>
              query.isEmpty ||
              e.value.name.toLowerCase().contains(query) ||
              e.key.toLowerCase().contains(query),
        )
        .toList();
    final public = _publicNetworks;
    final walletEmpty = widget.manager.wallet.networks.isEmpty;
    if (walletEmpty && public == null) {
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
                onPressed: () => unawaited(_openJoinSheet()),
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.l10n.networkJoinFirst),
              ),
              if (!widget.manager.hasJwt) ...[
                const SizedBox(height: 4),
                TextButton(
                  key: const ValueKey('emptyStateSignIn'),
                  onPressed: () => unawaited(
                    showSignInDialog(context, manager: widget.manager),
                  ),
                  child: Text(context.l10n.networkSignInTitle),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        if (walletEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Text(
              context.l10n.networkEmptyTitle,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: colors.dim),
            ),
          )
        else if (entries.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                context.l10n.networkNoMatches,
                style: TextStyle(color: colors.dim),
              ),
            ),
          )
        else
          for (final entry in entries)
            _MembershipTile(
              key: ValueKey('membership:${entry.key}'),
              networkId: entry.key,
              name: entry.value.name,
              selected: widget.controller.networkId == entry.key,
              status: _statusOf(entry.key),
              onTap: () => unawaited(_openNetwork(entry.key)),
            ),
        if (public != null) ...[
          Padding(
            key: const ValueKey('publicNetworksSection'),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
            child: Text(
              context.l10n.networkPublicSection.toUpperCase(),
              style: TextStyle(
                color: colors.dim,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          for (final network in public)
            _PublicNetworkTile(
              key: ValueKey('publicNetwork:${network.id}'),
              network: network,
              onJoin: () => unawaited(_openJoinSheet(networkId: network.id)),
            ),
        ],
      ],
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

/// One membership row — mirrors the sessions list's SessionTile: a single
/// row with a status dot and the network name, the same rounded-10
/// selected/hover highlight, no card chrome.
class _MembershipTile extends StatelessWidget {
  const _MembershipTile({
    super.key,
    required this.networkId,
    required this.name,
    required this.selected,
    required this.status,
    required this.onTap,
  });

  final String networkId;
  final String name;
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
      _MembershipStatus.idle => colors.dim.withValues(alpha: 0.35),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: selected
            ? (isLight ? const Color(0xFFEEF2FF) : colors.panelAlt)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? colors.text : colors.dim,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
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

/// One public-directory row: globe icon + name (+ member count when the
/// server reports it) and a trailing Join button that opens the join
/// sheet prefilled with the network id.
class _PublicNetworkTile extends StatelessWidget {
  const _PublicNetworkTile({
    super.key,
    required this.network,
    required this.onJoin,
  });

  final PublicNetworkInfo network;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final memberCount = network.memberCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.public, size: 16, color: colors.dim),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    network.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.text, fontSize: 13),
                  ),
                  if (memberCount != null)
                    Text(
                      context.l10n.networkPublicMembers(memberCount),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.dim.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              key: ValueKey('publicJoin:${network.id}'),
              onPressed: onJoin,
              child: Text(context.l10n.networkJoin),
            ),
          ],
        ),
      ),
    );
  }
}
