// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/chats/local_session_folders.dart'
    show folderAvatarGradient;
import 'dart:math' as math;

import 'package:fa_ui/fa_ui.dart';
// The presence payload model is pure Dart in the connector core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// The DEVICES section page (issue #2062 chunk 16, owner IA pass): a
/// top-level device tree — one expandable row per machine (online /
/// degraded / offline dot), nested agents (live / busy / offline) and
/// exposed sessions (live / wake-on-DM / offline) under it. Same §5
/// three-level model the sidebar panel shows, but as a full section: the
/// row components are the panel's [DeviceRosterRow]s, only the tree
/// container is new.
///
/// Data: [DeviceConnectorService.presence] (the local machine's own
/// heartbeat view) + [DeviceConnectorService.presenceFrames] (network-wide
/// frames — ones carrying a foreign `payload.deviceId` accumulate as
/// remote machines). No remote device frames → only the This device row.
/// Signed out → nothing at all; connecting → skeleton line; link lost →
/// a muted reconnecting line over the last-known tree.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.service});

  /// The app-scope device connector service (one upstream socket, AC1).
  final DeviceConnectorService service;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  /// Remote machines accumulated from deviceId-taged presence frames,
  /// keyed by device id (latest frame wins).
  final _remote = <String, PresenceFrame>{};

  StreamSubscription<NetworkEnvelope>? _framesSubscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(DevicesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) _subscribe();
  }

  void _subscribe() {
    unawaited(_framesSubscription?.cancel());
    _framesSubscription = widget.service.presenceFrames.listen(_onFrame);
  }

  @override
  void dispose() {
    unawaited(_framesSubscription?.cancel());
    _framesSubscription = null;
    super.dispose();
  }

  /// Network-wide presence frames carry a `payload.deviceId` when the
  /// server means ANOTHER machine (§5 network-wide view). Ours ride the
  /// typed [DeviceConnectorService.presence] stream instead.
  void _onFrame(NetworkEnvelope envelope) {
    final deviceId = envelope.payload['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return;
    if (deviceId == widget.service.deviceId) return;
    final frame = PresenceFrame.fromEnvelope(envelope);
    if (frame == null) return;
    setState(() => _remote[deviceId] = frame);
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return StreamBuilder<DeviceConnectorPhase>(
      stream: widget.service.phaseStream,
      initialData: widget.service.phase,
      builder: (context, snapshot) {
        final phase = snapshot.data ?? DeviceConnectorPhase.signedOut;
        return Column(
          key: const ValueKey('devicesPage'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                context.l10n.networkDevicesTitle.toUpperCase(),
                style: TextStyle(
                  color: colors.dim,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Expanded(
              child: switch (phase) {
                DeviceConnectorPhase.preparing ||
                DeviceConnectorPhase.connecting => _phaseLine(
                  context,
                  key: const ValueKey('devicesSkeleton'),
                  label: context.l10n.networkDeviceConnecting,
                  color: colors.dim.withValues(alpha: 0.5),
                ),
                _ => ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    if (phase == DeviceConnectorPhase.reconnecting)
                      _phaseLine(
                        context,
                        key: const ValueKey('devicesReconnecting'),
                        label: context.l10n.networkDeviceReconnecting,
                        color: colors.pending,
                      ),
                    // A failed start leaves the phase signed-out while the
                    // section is still mounted (enrollment/keychain/WS
                    // failure) — never blank: say so, show the error, tap
                    // retries (issue #2062 field feedback).
                    if (phase == DeviceConnectorPhase.signedOut)
                      GestureDetector(
                        key: const ValueKey('devicesNotRunning'),
                        onTap: widget.service.start,
                        child: _phaseLine(
                          context,
                          key: const ValueKey('devicesNotRunningLine'),
                          label: context.l10n.networkDeviceNotRunning,
                          color: colors.dim,
                        ),
                      ),
                    if (phase == DeviceConnectorPhase.signedOut &&
                        widget.service.lastStartError != null)
                      Padding(
                        key: const ValueKey('devicesStartError'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Text(
                          widget.service.lastStartError!,
                          style: TextStyle(
                            color: colors.dim.withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    _OwnDeviceNode(service: widget.service),
                    for (final entry in _remote.entries)
                      _RemoteDeviceNode(
                        key: ValueKey('deviceNode:${entry.key}'),
                        deviceId: entry.key,
                        frame: entry.value,
                      ),
                  ],
                ),
              },
            ),
          ],
        );
      },
    );
  }

  /// The connecting skeleton / reconnecting muted line (the panel's
  /// one-line shape, page padding).
  Widget _phaseLine(
    BuildContext context, {
    required Key key,
    required String label,
    required Color color,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    child: DeviceRosterStatusLine(label: label, color: color),
  );
}

/// The local machine's tree node: the presence frame's machine state
/// drives the dot; agents and exposed sessions ride nested (§5).
class _OwnDeviceNode extends StatelessWidget {
  const _OwnDeviceNode({required this.service});

  final DeviceConnectorService service;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PresenceFrame?>(
      stream: service.presence,
      builder: (context, snapshot) {
        final frame = snapshot.data;
        return _DeviceNodeTile(
          key: const ValueKey('deviceNode:This device'),
          rowKey: const ValueKey('deviceRow'),
          avatarKey: const ValueKey('deviceAvatar'),
          dotKey: const ValueKey('deviceDot'),
          seed: service.deviceId ?? 'This device',
          machine: frame?.machine ?? MachinePresence.online,
          label: context.l10n.networkDeviceThisDevice,
          initiallyExpanded: true,
          agents: frame?.agents ?? const {},
          sessions: frame?.sessions ?? const {},
        );
      },
    );
  }
}

/// A remote machine's tree node (from a deviceId-taged presence frame).
class _RemoteDeviceNode extends StatelessWidget {
  const _RemoteDeviceNode({
    super.key,
    required this.deviceId,
    required this.frame,
  });

  final String deviceId;
  final PresenceFrame frame;

  @override
  Widget build(BuildContext context) => _DeviceNodeTile(
    rowKey: ValueKey('deviceRow:$deviceId'),
    avatarKey: ValueKey('deviceAvatar:$deviceId'),
    dotKey: ValueKey('deviceDot:$deviceId'),
    seed: deviceId,
    machine: frame.machine,
    label: deviceId,
    agents: frame.agents,
    sessions: frame.sessions,
  );
}

/// One expandable machine row + its nested agent/session rows. The row
/// itself is the NETWORKS-LIST row pattern (owner restyle): the Ø50 round
/// letter-gradient avatar with a vector device glyph, the 14/w600 name,
/// the right-aligned presence status, the disclosure chevron — the same
/// geometry as the networks page rows (70pt pitch, 10pt inset, 12pt gap).
/// Children indent to the name's leading edge, like the sidebar's channels
/// under their network.
class _DeviceNodeTile extends StatefulWidget {
  const _DeviceNodeTile({
    super.key,
    required this.rowKey,
    required this.avatarKey,
    required this.dotKey,
    required this.seed,
    required this.machine,
    required this.label,
    required this.agents,
    required this.sessions,
    this.initiallyExpanded = false,
  });

  final Key rowKey;
  final Key avatarKey;
  final Key dotKey;

  /// The avatar hue seed (the device id; the own device falls back to its
  /// display label).
  final String seed;
  final MachinePresence machine;
  final String label;
  final Map<String, AgentRunState> agents;
  final Map<String, ConnectorSessionPresence> sessions;
  final bool initiallyExpanded;

  @override
  State<_DeviceNodeTile> createState() => _DeviceNodeTileState();
}

class _DeviceNodeTileState extends State<_DeviceNodeTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final hasChildren = widget.agents.isNotEmpty || widget.sessions.isNotEmpty;
    return Column(
      key: widget.rowKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('deviceNodeToggle:${widget.label}'),
          onTap: hasChildren
              ? () => setState(() => _expanded = !_expanded)
              : null,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 70,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  _DeviceAvatar(
                    key: widget.avatarKey,
                    dotKey: widget.dotKey,
                    seed: widget.seed,
                    dotColor: deviceMachineDotColor(colors, widget.machine),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                  Text(
                    deviceMachineLabel(context, widget.machine),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: widget.machine == MachinePresence.offline
                          ? colors.dim
                          : colors.teal,
                    ),
                  ),
                  if (hasChildren)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Transform.rotate(
                        angle: _expanded ? math.pi : 0,
                        child: FaIcon(
                          FaSemanticIcon.expandMore,
                          size: 16,
                          color: colors.dim,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          for (final entry in widget.agents.entries)
            Padding(
              padding: const EdgeInsets.only(left: 72),
              child: DeviceRosterRow(
                key: ValueKey('agentRow:${entry.key}'),
                dotKey: ValueKey('agentDot:${entry.key}'),
                dotColor: deviceAgentDotColor(colors, entry.value),
                label: deviceAgentName(entry.key),
                stateLabel: deviceAgentLabel(context, entry.value),
                stateColor: entry.value == AgentRunState.offline
                    ? colors.dim
                    : colors.teal,
              ),
            ),
          for (final entry in widget.sessions.entries)
            Padding(
              padding: const EdgeInsets.only(left: 72),
              child: DeviceRosterRow(
                key: ValueKey('sessionRow:${entry.key}'),
                dotKey: ValueKey('sessionDot:${entry.key}'),
                dotColor: deviceSessionDotColor(colors, entry.value),
                label: entry.key,
                stateLabel: deviceSessionLabel(context, entry.value),
                stateColor: entry.value == ConnectorSessionPresence.offline
                    ? colors.dim
                    : colors.teal,
              ),
            ),
        ],
      ],
    );
  }
}

/// The device avatar: the networks row's round letter-gradient avatar
/// ([folderAvatarGradient] seeded by the device id) carrying a vector
/// device glyph in the letter's on-color spec (WHITE @ 95%) instead of a
/// letter, plus the §5 presence dot as the badge. No SVG assets ship in
/// the app bundle, so the glyph is the theme-resolved [FaSemanticIcon]
/// vector (the ratchet allows no `Icons.*` literals in Fa files).
class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({
    super.key,
    required this.dotKey,
    required this.seed,
    required this.dotColor,
  });

  final Key dotKey;
  final String seed;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    final (start, end) = folderAvatarGradient(seed);
    return SizedBox(
      width: 50,
      height: 50,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [start, end],
              ),
            ),
            alignment: Alignment.center,
            child: FaIcon(
              FaSemanticIcon.devices,
              size: 22,
              color: Colors.white.withValues(alpha: .95),
            ),
          ),
          Positioned(
            bottom: 1,
            right: 1,
            child: Container(
              key: dotKey,
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
