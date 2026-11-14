// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/messenger_list_row_style.dart';
import 'package:fa_ui/fa_ui.dart'
    show FahColors, FaDesignTokens, FaIcon, FaSemanticIcon;
// The presence payload model is pure Dart in the connector core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// The §5 machine dot color (online teal / degraded pending / offline dim)
/// — shared by the roster panel and the devices tree page.
Color deviceMachineDotColor(FahColors colors, MachinePresence machine) =>
    switch (machine) {
      MachinePresence.online => colors.teal,
      MachinePresence.degraded => colors.pending,
      MachinePresence.offline => colors.dim,
    };

/// The agent dot color (live teal / busy pending / offline dim).
Color deviceAgentDotColor(FahColors colors, AgentRunState state) =>
    switch (state) {
      AgentRunState.live => colors.teal,
      AgentRunState.busy => colors.pending,
      AgentRunState.offline => colors.dim,
    };

/// The exposed-session dot color (live teal / wake-on-DM pending /
/// offline dim).
Color deviceSessionDotColor(FahColors colors, ConnectorSessionPresence state) =>
    switch (state) {
      ConnectorSessionPresence.live => colors.teal,
      ConnectorSessionPresence.wakeOnDm => colors.pending,
      ConnectorSessionPresence.offline => colors.dim,
    };

/// The machine state label (degraded reads as Busy — the §5 degraded
/// window means "socket lost, agents keep working").
String deviceMachineLabel(BuildContext context, MachinePresence machine) =>
    switch (machine) {
      MachinePresence.online => context.l10n.networkPresenceOnline,
      MachinePresence.degraded => context.l10n.networkPresenceBusy,
      MachinePresence.offline => context.l10n.networkPresenceOffline,
    };

/// The agent state label.
String deviceAgentLabel(BuildContext context, AgentRunState state) =>
    switch (state) {
      AgentRunState.live => context.l10n.networkPresenceOnline,
      AgentRunState.busy => context.l10n.networkPresenceBusy,
      AgentRunState.offline => context.l10n.networkPresenceOffline,
    };

/// The exposed-session state label.
String deviceSessionLabel(
  BuildContext context,
  ConnectorSessionPresence state,
) => switch (state) {
  ConnectorSessionPresence.live => context.l10n.networkPresenceOnline,
  ConnectorSessionPresence.wakeOnDm => context.l10n.networkPresenceWakeOnDm,
  ConnectorSessionPresence.offline => context.l10n.networkPresenceOffline,
};

/// The LOCAL chat session's dot color — the chat list's own presence, not
/// the connector's: a streaming session reads busy (pending), a live one
/// teal, everything else dim.
Color deviceLocalSessionDotColor(FahColors colors, ChatPresence? presence) =>
    switch (presence) {
      ChatPresence.live => colors.teal,
      ChatPresence.busy => colors.pending,
      ChatPresence.offline || null => colors.dim,
    };

/// The local chat session's state label (same vocabulary as the roster).
String deviceLocalSessionLabel(BuildContext context, ChatPresence? presence) =>
    switch (presence) {
      ChatPresence.live => context.l10n.networkPresenceOnline,
      ChatPresence.busy => context.l10n.networkPresenceBusy,
      ChatPresence.offline || null => context.l10n.networkPresenceOffline,
    };

/// The This-device tree's local-session projection: the app's canonical
/// enumeration ([ChatListController.localEntries]) with the messenger
/// list's visibility rule — a subagent session whose parent chat is still
/// projected rides that parent's badge instead of a roster row; orphaned
/// subagents stay visible. Mirrors chat_list_panel's
/// `_isSubagentWithLiveParent` (kept in step by its test).
List<ChatListEntry> deviceVisibleLocalSessions(ChatListController controller) {
  final entries = controller.localEntries;
  final parentIds = {for (final entry in entries) entry.id.value};
  return [
    for (final entry in entries)
      if (!_ridesParentBadge(parentIds, entry)) entry,
  ];
}

/// True when [entry] is a subagent session whose parent chat is still in
/// the projection.
bool _ridesParentBadge(Set<String> parentIds, ChatListEntry entry) {
  if (!entry.isSubagent) return false;
  final parent = entry.parentId;
  return parent != null && parentIds.contains(parent);
}

/// The agent NAME part of a §1 address (`goal_builder@macbook` →
/// `goal_builder`).
String deviceAgentName(String address) {
  final at = address.indexOf('@');
  return at <= 0 ? address : address.substring(0, at);
}

/// The 'My devices' roster panel (issue #2062 chunk 15): rendered at the
/// TOP of the networks sidebar, above the memberships — devices with
/// online/degraded/offline dots, nested agents (live/busy/offline) and
/// exposed sessions (live/wake-on-DM/offline), driven by the
/// [DeviceConnectorService]'s streams via [StreamBuilder] (no timers).
///
/// Graceful states: not signed in → nothing at all; connecting → a
/// skeleton line; link lost → a muted 'reconnecting' line. Presence dots
/// follow the channel rail's convention (teal = live, pending = busy /
/// degraded, dim = offline).
class DeviceRosterPanel extends StatelessWidget {
  const DeviceRosterPanel({super.key, required this.service});

  /// The device connector service (streams + phase).
  final DeviceConnectorService service;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DeviceConnectorPhase>(
      stream: service.phaseStream,
      initialData: service.phase,
      builder: (context, snapshot) {
        final phase = snapshot.data ?? DeviceConnectorPhase.signedOut;
        if (phase == DeviceConnectorPhase.signedOut) {
          return const SizedBox.shrink();
        }
        return Column(
          key: const ValueKey('deviceRosterPanel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text(
                context.l10n.networkDevicesTitle.toUpperCase(),
                style: TextStyle(
                  color: FahColors.of(context).dim,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            switch (phase) {
              DeviceConnectorPhase.online => _OnlineRoster(service: service),
              DeviceConnectorPhase.preparing ||
              DeviceConnectorPhase.connecting => DeviceRosterStatusLine(
                key: const ValueKey('deviceRosterSkeleton'),
                label: context.l10n.networkDeviceConnecting,
                color: FahColors.of(context).dim.withValues(alpha: 0.5),
              ),
              DeviceConnectorPhase.reconnecting => DeviceRosterStatusLine(
                key: const ValueKey('deviceRosterReconnecting'),
                label: context.l10n.networkDeviceReconnecting,
                color: FahColors.of(context).pending,
              ),
              DeviceConnectorPhase.signedOut => const SizedBox.shrink(),
            },
          ],
        );
      },
    );
  }
}

/// The connected roster: the local machine's row plus the agent and
/// session presence riding in the latest server presence frame (§5).
class _OnlineRoster extends StatelessWidget {
  const _OnlineRoster({required this.service});

  final DeviceConnectorService service;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PresenceFrame?>(
      stream: service.presence,
      builder: (context, snapshot) {
        final colors = FahColors.of(context);
        final presence = snapshot.data;
        final machine =
            presence?.machine ??
            MachinePresence.online; // link up ⇒ machine online
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DeviceRosterRow(
              key: const ValueKey('deviceRow'),
              dotKey: const ValueKey('deviceDot'),
              dotColor: deviceMachineDotColor(colors, machine),
              label: context.l10n.networkDeviceThisDevice,
              stateLabel: deviceMachineLabel(context, machine),
              stateColor: machine == MachinePresence.offline
                  ? colors.dim
                  : colors.teal,
            ),
            for (final entry in (presence?.agents ?? const {}).entries)
              DeviceRosterRow(
                key: ValueKey('agentRow:${entry.key}'),
                dotKey: ValueKey('agentDot:${entry.key}'),
                dotColor: deviceAgentDotColor(colors, entry.value),
                label: deviceAgentName(entry.key),
                stateLabel: deviceAgentLabel(context, entry.value),
                stateColor: entry.value == AgentRunState.offline
                    ? colors.dim
                    : colors.teal,
              ),
            for (final entry in (presence?.sessions ?? const {}).entries)
              DeviceRosterRow(
                key: ValueKey('sessionRow:${entry.key}'),
                dotKey: ValueKey('sessionDot:${entry.key}'),
                dotColor: deviceSessionDotColor(colors, entry.value),
                label: entry.key,
                stateLabel: deviceSessionLabel(context, entry.value),
                stateColor: entry.value == ConnectorSessionPresence.offline
                    ? colors.dim
                    : colors.teal,
              ),
          ],
        );
      },
    );
  }
}

/// One roster line: presence dot + name + a trailing state label (the
/// membership tile's single-row shape).
class DeviceRosterRow extends StatelessWidget {
  const DeviceRosterRow({
    super.key,
    required this.dotKey,
    required this.dotColor,
    required this.label,
    required this.stateLabel,
    required this.stateColor,
    this.onTap,
  });

  final Key dotKey;
  final Color dotColor;
  final String label;
  final String stateLabel;
  final Color stateColor;

  /// When set, the whole row is tappable (the This-device tree's local
  /// session rows open their chat); the remote roster rows stay read-only.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          Container(
            key: dotKey,
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.dim, fontSize: 13),
            ),
          ),
          Text(stateLabel, style: TextStyle(fontSize: 11, color: stateColor)),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

/// The skeleton (connecting) / muted (reconnecting) one-line states.
class DeviceRosterStatusLine extends StatelessWidget {
  const DeviceRosterStatusLine({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.dim, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// One session row in the Local panel's anatomy: a bold title with a
/// right-aligned relative timestamp, a muted PATH subtitle (never a message
/// preview or presence word), a hairline separator, and a chevron only when
/// the row opens. Live/busy activity may show the small subtitle dot; closed
/// and unknown sessions have no misleading "Offline" label.
class DeviceSessionCard extends StatelessWidget {
  const DeviceSessionCard({
    super.key,
    required this.dotKey,
    required this.dotColor,
    required this.title,
    required this.subtitle,
    this.timestamp = '',
    this.selected = false,
    this.hairline = false,
    this.showPresenceDot = false,
    this.onTap,
  });

  /// The activity dot key (the `sessionDot:<id>` contract when visible).
  final Key dotKey;
  final Color dotColor;
  final String title;
  final String subtitle;
  final String timestamp;
  final bool selected;
  final bool hairline;
  final bool showPresenceDot;

  /// The shell's open flow; null renders the read-only row (no chevron).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final ink = selected ? tokens.accentInk : colors.text;
    final subdued = selected
        ? tokens.accentInk.withValues(alpha: .82)
        : colors.dim;
    return Material(
      color: messengerListRowColor(selected: selected, accent: tokens.accent),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 64,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: ink,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                if (timestamp.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    timestamp,
                                    style: TextStyle(
                                      color: subdued,
                                      fontSize: 10.5,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (subtitle.isNotEmpty || showPresenceDot) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: subdued,
                                        fontSize: 12,
                                        height: 1.25,
                                      ),
                                    ),
                                  ),
                                  if (showPresenceDot)
                                    Container(
                                      key: dotKey,
                                      margin: const EdgeInsets.only(left: 6),
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: dotColor,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onTap != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: FaIcon(
                            FaSemanticIcon.chevronRight,
                            size: 16,
                            color: subdued,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (hairline)
                Container(
                  height: .5,
                  margin: const EdgeInsets.only(left: 10, right: 8),
                  color: colors.border.withValues(alpha: .45),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
