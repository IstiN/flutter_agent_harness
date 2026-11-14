// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of wide_layout_shell.dart: the sidebar's NETWORKS surface and its
// membership/channel flows (join sheet, resume, channel entry) live here
// so the main file stays under the 2800-line guard. Same library, so
// private members resolve.

part of 'wide_layout_shell.dart';

/// The networks sidebar family: the identity-globe NETWORKS surface, the
/// channel open/resume/join flows it drives, and the network chat column
/// swapped into the center surface.
extension _WideLayoutShellNetworks on _WideLayoutShellState {
  /// The chats sidebar's NETWORKS surface (Telegram pattern, owner pass):
  /// the identity globe swaps the SIDEBAR content to the networks strip
  /// with the in-place channel drill-down — the same slot the Local
  /// drill-down uses. Networks is a ROOT destination: only a drilled
  /// network's channel list has a back chevron; the manage action keeps the
  /// management dialog reachable. Opening a channel keeps the surface open:
  /// only the message column swaps to the channel's messages and the tapped
  /// row highlights.
  Widget _buildNetworksSidebar() {
    return ChatNetworksPanel(
      manager: widget.networkSessions,
      mode: widget.networkMode,
      chatList: _chatController,
      compact: _isNarrow,
      onCollapse: _isNarrow
          ? null
          : () => _updateShell(() {
              _sidebarCollapsed = true;
              _sidebarStateBeforePresentation = null;
            }),
      onManageNetworks: () => unawaited(
        showChatNetworksDialog(
          context,
          manager: widget.networkSessions,
          networkMode: widget.networkMode,
        ),
      ),
      onOpenChannel: (networkId, channel) =>
          unawaited(_openSidebarNetworkChannel(networkId, channel)),
    );
  }

  /// The DEVICES section (issue #2062 chunk 16): the master-rail machine
  /// roster ([DevicesPage] — the networks-strip avatar rail beside the
  /// selected device's pane) over the app-scope connector — one upstream
  /// socket for every surface that shows it (AC1). The narrow form embeds the
  /// same page in the section surface; the wide form takes the sidebar
  /// column (the Local panel's slot) and keeps the message column. The
  /// This-device pane enumerates the app's LOCAL chat sessions (the same
  /// [ChatListController] the Local panel projects — no connector
  /// involvement) and opens them through the shell's canonical open flow
  /// (`_openLocalEntry`): live sessions switch in place, persisted ones
  /// clone/relay. Remote devices' cards stay read-only.
  Widget _buildDevicesPanel({bool compact = false}) {
    final sessions = widget.networkSessions;
    if (sessions == null || !sessions.hasJwt) return const SizedBox.shrink();
    return DevicesPage(
      service: _devicesConnector,
      sessions: _chatController,
      onOpenSession: (entry) => unawaited(_openLocalEntry(entry)),
      onOpenRemoteConversation:
          ({
            required String deviceId,
            required String deviceLabel,
            required String agentAddress,
            String? sessionId,
          }) => unawaited(
            _openDeviceConversation(
              deviceId: deviceId,
              deviceLabel: deviceLabel,
              agentAddress: agentAddress,
              sessionId: sessionId,
            ),
          ),
      // The open session's card carries the accent-fill selected state
      // (the same ONE selected id the Local panel's rows compare
      // against — pending wins, then live, then persisted).
      selectedSessionId: _selectedSessionId,
    );
  }

  /// Remote roster session/agent tap: the DM opens as a VIRTUAL CHANNEL
  /// of the account-personal network — the same [NetworkChatPage] the
  /// regular channels use (§7), fed by the device connector's fanet1
  /// transport through [NetworkSessionDm]. The sidebar keeps the roster;
  /// only the message column swaps (the channel-rail contract).
  Future<void> _openDeviceConversation({
    required String deviceId,
    required String deviceLabel,
    required String agentAddress,
    String? sessionId,
  }) async {
    final manager = widget.networkSessions;
    final mode = widget.networkMode;
    if (manager == null || mode == null) return;
    final connector = _devicesConnector;
    final personal = connector.personalNetworkId;
    if (personal == null) {
      showFahErrorSnack(context, 'device not enrolled yet');
      return;
    }
    final agentName = agentAddress.substring(0, agentAddress.indexOf('@'));
    final channelId = await connector.dmChannelForAgent(
      deviceId: deviceId,
      agentName: agentName,
    );
    if (!mounted) return;
    // The owner is already a member of the auto-provisioned personal
    // network: the server's auth-first re-entry admits the JWT with no
    // password prompt (never the join sheet here).
    if (!manager.sessions.containsKey(personal)) {
      try {
        await manager.join(networkId: personal, password: '');
      } on Object catch (error) {
        if (mounted) showFahErrorSnack(context, error.toString());
        return;
      }
    }
    if (!mounted) return;
    final session = manager.sessions[personal];
    if (session == null) return;
    session.attachDmConnector(connector);
    session.dmSessionTargets[channelId] = sessionId;
    await _openSidebarChannelEntry(
      manager,
      mode,
      personal,
      Channel(
        id: channelId,
        networkId: personal,
        name: '$deviceLabel · $agentName',
      ),
    );
  }

  /// The sidebar channel-row tap: membership first, then the channel
  /// entry (channel-rail contract).
  Future<void> _openSidebarNetworkChannel(
    String networkId,
    Channel channel,
  ) async {
    final manager = widget.networkSessions;
    final mode = widget.networkMode;
    if (manager == null || mode == null) {
      _updateShell(() => _networksSurfaceOpen = false);
      return;
    }
    await _ensureSidebarNetworkMembership(manager, mode, networkId);
    await _openSidebarChannelEntry(manager, mode, networkId, channel);
  }

  /// Joins or resumes the network when the tapped channel's session is
  /// not live yet (open networks get the join sheet; password-protected
  /// ones resume straight from the saved credential).
  ///
  /// The membership arms (join sheet / resume) are structurally reachable
  /// only when the rail's channel rows rendered without a live session —
  /// the panel sources its rows from the session itself — so the helpers
  /// stay small (CC ≤ 3) instead of relying on UI coverage that cannot
  /// reach them.
  Future<void> _ensureSidebarNetworkMembership(
    NetworkSessionManager manager,
    NetworkModeController mode,
    String networkId,
  ) async {
    await mode.enterNetwork(networkId);
    if (manager.sessions.containsKey(networkId)) return;
    if (manager.wallet.networks[networkId]?.password == null) {
      await _showSidebarJoinSheet(mode, manager, networkId);
    } else {
      await _resumeSidebarNetwork(manager, networkId);
    }
  }

  /// The open-network membership arm: the join sheet, gated on mount.
  /// Awaited by the caller so the channel entry opens only after the
  /// sheet closes — the original inline behavior.
  Future<void> _showSidebarJoinSheet(
    NetworkModeController mode,
    NetworkSessionManager manager,
    String networkId,
  ) async {
    if (!mounted) return;
    await showJoinSheet(
      context,
      controller: mode,
      manager: manager,
      initialNetworkId: networkId,
    );
  }

  /// The password-protected membership arm: resume from the saved
  /// credential; a rejection lands in the error snack without swapping
  /// the content pane.
  Future<void> _resumeSidebarNetwork(
    NetworkSessionManager manager,
    String networkId,
  ) async {
    try {
      await manager.resume(networkId);
    } on Object catch (error) {
      if (mounted) showFahErrorSnack(context, error.toString());
    }
  }

  /// Select + open the tapped channel's messages right away. Deliberately
  /// NO setNetworkFilter here: a latched network filter narrowed the All
  /// facet to that network's rows only (owner bug).
  Future<void> _openSidebarChannelEntry(
    NetworkSessionManager manager,
    NetworkModeController mode,
    String networkId,
    Channel channel,
  ) async {
    final session = manager.sessions[networkId];
    if (session != null) {
      try {
        await session.openChannel(channel.id);
      } on Object catch (error) {
        if (mounted) showFahErrorSnack(context, error.toString());
      }
    }
    if (!mounted) return;
    await mode.selectChannel(channel.id);
    // Land the tap exactly like the chat-list row open does, but the
    // surface STAYS open (owner pass): ONLY the content pane swaps to
    // the channel's message view; the strip + channels list keep
    // their place and the tapped row highlights through
    // mode.selectChannel above. The projection row still becomes the
    // selected network entry so the All home carries the row's
    // selection once the back chevrons close the surface.
    // Session-snapshot fallback rows have no projection row; a
    // minimal stand-in entry keeps the content-pane contract there.
    final entry = _chatController.networkChannelEntries
        .where(
          (candidate) =>
              candidate.networkId == networkId &&
              candidate.id.value == channel.id,
        )
        .firstOrNull;
    if (!mounted) return;
    _updateShell(() {
      _activeNetworkEntry =
          entry ?? _standInNetworkChannelEntry(manager, networkId, channel);
    });
    // The row-open parity: the tap marks the projection row read.
    if (entry != null) await _chatController.markOpened(entry);
    if (mounted && _isNarrow) await _pushNarrowChat();
  }

  /// The fallback entry for session-snapshot rows with no projection row.
  ChatListEntry _standInNetworkChannelEntry(
    NetworkSessionManager manager,
    String networkId,
    Channel channel,
  ) {
    return ChatListEntry(
      id: ChatEntryId.network(
        ChatListEntryKind.networkChannel,
        networkId: networkId,
        id: channel.id,
      ),
      kind: ChatListEntryKind.networkChannel,
      networkId: networkId,
      networkName: manager.wallet.networks[networkId]?.name,
      title: channel.name ?? channel.id,
      createdAt: DateTime.now(),
    );
  }

  Widget _buildNetworkChatArea(ChatListEntry entry) {
    final manager = widget.networkSessions!;
    return NetworkChatPage(
      controller: widget.networkMode!,
      manager: manager,
      showAppBar: true,
      showChannelHeader: false,
      projectLabel: entry.networkName ?? entry.networkId,
    );
  }
}
