// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa_ui/fa_ui.dart' show FahColors;
// The presence payload model is pure Dart in the connector core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

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
              DeviceConnectorPhase.connecting => _StatusLine(
                key: const ValueKey('deviceRosterSkeleton'),
                label: context.l10n.networkDeviceConnecting,
                color: FahColors.of(context).dim.withValues(alpha: 0.5),
              ),
              DeviceConnectorPhase.reconnecting => _StatusLine(
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
            _RosterRow(
              key: const ValueKey('deviceRow'),
              dotKey: const ValueKey('deviceDot'),
              dotColor: switch (machine) {
                MachinePresence.online => colors.teal,
                MachinePresence.degraded => colors.pending,
                MachinePresence.offline => colors.dim,
              },
              label: context.l10n.networkDeviceThisDevice,
              stateLabel: _machineLabel(context, machine),
              stateColor: machine == MachinePresence.offline
                  ? colors.dim
                  : colors.teal,
            ),
            for (final entry in (presence?.agents ?? const {}).entries)
              _RosterRow(
                key: ValueKey('agentRow:${entry.key}'),
                dotKey: ValueKey('agentDot:${entry.key}'),
                dotColor: switch (entry.value) {
                  AgentRunState.live => colors.teal,
                  AgentRunState.busy => colors.pending,
                  AgentRunState.offline => colors.dim,
                },
                label: _agentName(entry.key),
                stateLabel: _agentLabel(context, entry.value),
                stateColor: entry.value == AgentRunState.offline
                    ? colors.dim
                    : colors.teal,
              ),
            for (final entry in (presence?.sessions ?? const {}).entries)
              _RosterRow(
                key: ValueKey('sessionRow:${entry.key}'),
                dotKey: ValueKey('sessionDot:${entry.key}'),
                dotColor: switch (entry.value) {
                  ConnectorSessionPresence.live => colors.teal,
                  ConnectorSessionPresence.wakeOnDm => colors.pending,
                  ConnectorSessionPresence.offline => colors.dim,
                },
                label: entry.key,
                stateLabel: _sessionLabel(context, entry.value),
                stateColor: entry.value == ConnectorSessionPresence.offline
                    ? colors.dim
                    : colors.teal,
              ),
          ],
        );
      },
    );
  }

  String _agentName(String address) {
    final at = address.indexOf('@');
    return at <= 0 ? address : address.substring(0, at);
  }

  String _machineLabel(BuildContext context, MachinePresence machine) =>
      switch (machine) {
        MachinePresence.online => context.l10n.networkPresenceOnline,
        MachinePresence.degraded => context.l10n.networkPresenceBusy,
        MachinePresence.offline => context.l10n.networkPresenceOffline,
      };

  String _agentLabel(BuildContext context, AgentRunState state) =>
      switch (state) {
        AgentRunState.live => context.l10n.networkPresenceOnline,
        AgentRunState.busy => context.l10n.networkPresenceBusy,
        AgentRunState.offline => context.l10n.networkPresenceOffline,
      };

  String _sessionLabel(BuildContext context, ConnectorSessionPresence state) =>
      switch (state) {
        ConnectorSessionPresence.live => context.l10n.networkPresenceOnline,
        ConnectorSessionPresence.wakeOnDm =>
          context.l10n.networkPresenceWakeOnDm,
        ConnectorSessionPresence.offline => context.l10n.networkPresenceOffline,
      };
}

/// One roster line: presence dot + name + a trailing state label (the
/// membership tile's single-row shape).
class _RosterRow extends StatelessWidget {
  const _RosterRow({
    super.key,
    required this.dotKey,
    required this.dotColor,
    required this.label,
    required this.stateLabel,
    required this.stateColor,
  });

  final Key dotKey;
  final Color dotColor;
  final String label;
  final String stateLabel;
  final Color stateColor;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
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
  }
}

/// The skeleton (connecting) / muted (reconnecting) one-line states.
class _StatusLine extends StatelessWidget {
  const _StatusLine({super.key, required this.label, required this.color});

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
