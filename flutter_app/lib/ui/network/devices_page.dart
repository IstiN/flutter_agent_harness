// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show chatListRelativeTime;
import 'package:fa/ui/chats/local_session_folders.dart'
    show folderAvatarGradient;

import 'package:fa_ui/fa_ui.dart';
// The presence payload model is pure Dart in the connector core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// The DEVICES section page (issue #2062 chunk 16, owner master-rail
/// pass): the SAME split the network center uses for rail + pane
/// ([Row] → `SizedBox(rail width)` + [VerticalDivider] + `Expanded`
/// pane, scaled to the section column) over a NETWORKS-strip rail —
/// a narrow left column of device AVATARS ONLY (the letter-gradient
/// avatar with the vector device glyph, Ø50 on the ~70pt pitch, the
/// accent selection capsule flush to the selected avatar's left edge,
/// the §5 presence dot riding the avatar badge). No inline device
/// rows, no trailing status text, no disclosure chevron: the selection
/// capsule + squared-up avatar are the whole level-1 affordance, and
/// status lives in the avatar dot (the OWN device is ONLINE LOCALLY —
/// the app is running on this machine, connector-independent; remote
/// machines read their latest [PresenceFrame]).
///
/// The RIGHT pane shows the SELECTED device's children: agents in the
/// roster-row form, this machine's LOCAL chat sessions as
/// [DeviceSessionCard] channel cards (the channel-card anatomy, tap
/// routes through the shell's open flow), a remote machine's exposed
/// sessions as read-only cards — or the muted no-sessions hint. The
/// first device is selected by default and the selection PERSISTS
/// while presence frames stream updates.
///
/// Data: [DeviceConnectorService.presence] (the local machine's own
/// heartbeat view) + roster/presence streams whose `payload.devices` rows
/// accumulate as remote machines (legacy `payload.deviceId` frames remain
/// supported). Signed out → the not-running retry line above the rail;
/// connecting → skeleton line; link lost → a muted reconnecting line above
/// the last-known rail.
class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.service,
    this.sessions,
    this.onOpenSession,
    this.selectedSessionId,
  });

  /// The rail's geometry — the networks strip's contract scaled to the
  /// section's rail+pane split (network_center's Row): Ø~50 avatars on a
  /// ~70pt pitch, the ~6x51 accent capsule flush to the strip's left
  /// edge. The rail column is ~100pt so the pane keeps a usable card
  /// width inside the ~260pt sidebar.
  static const double railWidth = 104;
  static const double railItemPitch = 70;
  static const double railAvatarSize = 50;
  static const double capsuleWidth = 6;
  static const double capsuleHeight = 51;

  /// The app-scope device connector service (one upstream socket, AC1).
  final DeviceConnectorService service;

  /// The app's local chat list — the same controller the chat screen's
  /// Local sessions panel projects. The This-device pane ALWAYS lists its
  /// sessions (no connector involvement); null renders the pane without
  /// local session rows.
  final ChatListController? sessions;

  /// The shell's canonical open-session flow (the Local panel's
  /// onOpenSession): a live session switches in place, a persisted one
  /// clones/relays. Null keeps the local session rows read-only.
  final ValueChanged<ChatListEntry>? onOpenSession;

  /// The shell's ONE selected session id (pending wins, then live, then
  /// persisted) — the currently open local session's card carries the
  /// accent-fill selected state. Null highlights nothing.
  final String? selectedSessionId;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  /// The identity fallback for the own rail entry when the connector has
  /// no enrolled device id yet (the avatar hue seed + selection id).
  static const _ownFallbackId = 'This device';

  /// Remote machines keyed by stable id. REST roster data supplies names and
  /// an offline-first entry; the latest live presence frame merges into the
  /// same node instead of creating a duplicate rail cell.
  final _remote = <String, _RemoteDeviceNode>{};

  /// The selected device id; null = the first device (This device, the
  /// rail's constant first entry).
  String? _selectedDeviceId;

  StreamSubscription<NetworkEnvelope>? _framesSubscription;
  StreamSubscription<NetworkEnvelope>? _rosterSubscription;
  var _fetchingRoster = false;

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
    unawaited(_rosterSubscription?.cancel());
    final service = widget.service;
    _remote.clear();
    _fetchingRoster = false;
    // Seed from the cached per-network roster frames: the server pushes
    // them once per connect (before this page exists), and REST carries no
    // sessions — without the replay every remote pane stays empty.
    for (final envelope in service.currentRosterFrames) {
      _onFrame(envelope);
    }
    _framesSubscription = service.presenceFrames.listen(_onFrame);
    _rosterSubscription = service.rosterFrames.listen((envelope) {
      _onFrame(envelope);
      unawaited(_refreshOwnDevice(service));
      unawaited(_refreshRoster(service));
    });
    // The REST roster is authoritative for names and includes machines whose
    // live presence frame has not arrived. A roster frame is the invalidation
    // signal for subsequent refreshes; opening the page always refreshes too.
    unawaited(_refreshOwnDevice(service));
    unawaited(_refreshRoster(service));
  }

  Future<void> _refreshOwnDevice(DeviceConnectorService service) async {
    try {
      await service.refreshOwnDevice();
    } on Object {
      // The existing connector phase/banners own connectivity errors. A stale
      // local label remains useful while the account roster is unavailable.
    }
  }

  Future<void> _refreshRoster(DeviceConnectorService service) async {
    if (_fetchingRoster) return;
    _fetchingRoster = true;
    try {
      final devices = await service.listNetworkDevices();
      if (!mounted || !identical(service, widget.service)) return;
      final ownId = service.deviceId;
      final remote = [
        for (final device in devices)
          if (device.deviceId.isNotEmpty && device.deviceId != ownId) device,
      ];
      if (remote.isEmpty) return;
      setState(() {
        for (final device in remote) {
          final previous = _remote[device.deviceId];
          _remote[device.deviceId] = _RemoteDeviceNode(
            roster: device,
            presence: previous?.presence,
          );
        }
      });
    } on Object {
      // Presence remains a working offline/degraded data source when the REST
      // roster is temporarily unavailable (or predates this deployed route).
    } finally {
      if (identical(service, widget.service)) _fetchingRoster = false;
    }
  }

  @override
  void dispose() {
    unawaited(_framesSubscription?.cancel());
    unawaited(_rosterSubscription?.cancel());
    _framesSubscription = null;
    _rosterSubscription = null;
    super.dispose();
  }

  /// Server roster and presence frames carry their device projections in
  /// `payload.devices`. The legacy device-level `payload.deviceId` shape
  /// remains a fallback for older connectors.
  void _onFrame(NetworkEnvelope envelope) {
    final devices = envelope.payload['devices'];
    if (devices is List) {
      _onServerDevices(envelope, devices);
      return;
    }
    _onLegacyPresenceFrame(envelope);
  }

  void _onLegacyPresenceFrame(NetworkEnvelope envelope) {
    final deviceId = envelope.payload['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return;
    if (deviceId == widget.service.deviceId) return;
    final frame = PresenceFrame.fromEnvelope(envelope);
    if (frame == null) return;
    setState(() {
      _remote[deviceId] = _RemoteDeviceNode(
        roster: _remote[deviceId]?.roster,
        presence: frame,
      );
    });
  }

  /// Upserts every foreign row without treating one network's roster as a
  /// complete account snapshot (the server sends one frame per network).
  void _onServerDevices(NetworkEnvelope envelope, List<Object?> devices) {
    final updates = <String, _RemoteDeviceNode>{};
    final ownId = widget.service.deviceId;
    for (final device in devices) {
      if (device is! Map) continue;
      final deviceId = device['deviceId'];
      if (deviceId is! String || deviceId.isEmpty || deviceId == ownId) {
        continue;
      }
      updates[deviceId] = _mergeServerDevice(
        envelope,
        device,
        _remote[deviceId],
      );
    }
    if (updates.isEmpty) return;
    setState(() => _remote.addAll(updates));
  }

  _RemoteDeviceNode _mergeServerDevice(
    NetworkEnvelope envelope,
    Map<Object?, Object?> device,
    _RemoteDeviceNode? previous,
  ) {
    final roster = DeviceInfo.fromJson(device.cast<String, Object?>());
    final oldPresence = previous?.presence;
    final machine =
        MachinePresence.tryParse(roster.presence ?? '') ??
        previous?.machine ??
        MachinePresence.offline;
    return _RemoteDeviceNode(
      roster: roster,
      presence: PresenceFrame(
        msgId: envelope.msgId,
        ts: envelope.ts,
        machine: machine,
        agents: _serverAgents(device['agents'], oldPresence?.agents),
        sessions: _serverSessions(
          device['sessions'],
          oldPresence?.sessions,
          envelope.kind,
        ),
      ),
    );
  }

  /// An omitted projection is a patch with no child changes; an explicit
  /// list is its new snapshot, so an empty list deliberately clears it.
  Map<String, AgentRunState> _serverAgents(
    Object? value,
    Map<String, AgentRunState>? previous,
  ) {
    if (value is! List) return previous ?? const {};
    final agents = <String, AgentRunState>{};
    for (final node in value) {
      if (node is! Map || node['exposed'] != true) continue;
      final name = node['name'];
      final state = AgentRunState.tryParse('${node['state'] ?? ''}');
      if (name is! String || name.isEmpty || state == null) continue;
      agents[name] = state;
    }
    return agents;
  }

  Map<String, ConnectorSessionPresence> _serverSessions(
    Object? value,
    Map<String, ConnectorSessionPresence>? previous,
    NetworkEnvelopeKind kind,
  ) {
    if (value is! List) return previous ?? const {};
    final sessions = <String, ConnectorSessionPresence>{};
    for (final node in value) {
      if (node is! Map || !_serverSessionVisible(node, kind)) continue;
      final id = node['id'];
      final state = ConnectorSessionPresence.tryParse('${node['state'] ?? ''}');
      if (id is! String || id.isEmpty || state == null) continue;
      sessions[id] = state;
    }
    return sessions;
  }

  bool _serverSessionVisible(
    Map<Object?, Object?> session,
    NetworkEnvelopeKind kind,
  ) {
    final networks = session['networks'];
    // REST's personal-network roster predates exposure lists and remains
    // visible by default. Presence patches need the explicit personal id.
    if (networks is! List) return kind == NetworkEnvelopeKind.roster;
    final personalId = widget.service.personalNetworkId;
    return personalId != null && networks.contains(personalId);
  }

  Future<void> _renameOwnDevice() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _RenameDeviceDialog(
        initialName: widget.service.ownFriendlyName ?? '',
        onRename: widget.service.renameOwnDevice,
      ),
    );
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
            _sectionHeader(context, colors),
            Expanded(
              child: switch (phase) {
                DeviceConnectorPhase.preparing ||
                DeviceConnectorPhase.connecting => _phaseLine(
                  context,
                  key: const ValueKey('devicesSkeleton'),
                  label: context.l10n.networkDeviceConnecting,
                  color: colors.dim.withValues(alpha: 0.5),
                ),
                _ => _connectedBody(context, colors, phase),
              },
            ),
          ],
        );
      },
    );
  }

  /// The small-caps section header (the page's one label line — the
  /// selected device's name lives in the pane header).
  Widget _sectionHeader(BuildContext context, FahColors colors) => Padding(
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
  );

  /// The connected body: the phase banners above the last-known rail +
  /// pane (a failed start keeps the rail mounted — the own device stays
  /// ONLINE LOCALLY even while the connector tells its story above).
  Widget _connectedBody(
    BuildContext context,
    FahColors colors,
    DeviceConnectorPhase phase,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (phase == DeviceConnectorPhase.reconnecting)
        _phaseLine(
          context,
          key: const ValueKey('devicesReconnecting'),
          label: context.l10n.networkDeviceReconnecting,
          color: colors.pending,
        ),
      // A failed start leaves the phase signed-out while the section is
      // still mounted (enrollment/keychain/WS failure) — never blank:
      // say so, show the error, tap retries (issue #2062 field feedback).
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
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
      Expanded(child: _railBody(context)),
    ],
  );

  /// The master-rail split (network_center's Row): the device-avatar
  /// rail in a fixed [SizedBox], the border [VerticalDivider], and the
  /// selected device's pane in the [Expanded] remainder. The own frame
  /// stream + the local chat list rebuild BOTH sides together (the pane
  /// projects the controller the same way the Local panel does).
  Widget _railBody(BuildContext context) {
    final controller = widget.sessions;
    Widget body = StreamBuilder<DeviceInfo?>(
      stream: widget.service.ownDeviceStream,
      initialData: widget.service.ownDevice,
      builder: (context, ownSnapshot) {
        return StreamBuilder<PresenceFrame?>(
          stream: widget.service.presence,
          builder: (context, snapshot) {
            final devices = _deviceEntries(
              context,
              snapshot.data,
              ownSnapshot.data,
            );
            final selected = _resolveSelected(devices);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: DevicesPage.railWidth,
                  child: _DeviceRail(
                    devices: devices,
                    selectedId: selected.id,
                    onSelect: (id) => setState(() => _selectedDeviceId = id),
                    onRenameOwn: () => unawaited(_renameOwnDevice()),
                  ),
                ),
                VerticalDivider(width: 1, color: FahColors.of(context).border),
                Expanded(
                  child: _DevicePane(
                    device: selected,
                    onOpenSession: widget.onOpenSession,
                    selectedSessionId: widget.selectedSessionId,
                    onRenameOwn: () => unawaited(_renameOwnDevice()),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (controller == null) return body;
    // The chat list notifies on loads/previews/pins — the rail+pane
    // re-project with it, exactly like the Local sessions panel's
    // ListenableBuilder.
    return ListenableBuilder(listenable: controller, builder: (_, _) => body);
  }

  /// The rail's devices: This device first (always present), then the
  /// remote machines in frame-arrival order. The OWN dot is ONLINE
  /// LOCALLY — teal, connector-independent; remote dots read their
  /// latest frame (offline before one exists). The connector's
  /// exposed-session view never owns the own pane's children — the
  /// app's local chat list does.
  List<_DeviceEntry> _deviceEntries(
    BuildContext context,
    PresenceFrame? ownFrame,
    DeviceInfo? ownDevice,
  ) {
    final controller = widget.sessions;
    final defaultOwnLabel = context.l10n.networkDeviceThisDevice;
    final ownFriendlyName = ownDevice?.friendlyName;
    return [
      _DeviceEntry(
        id: widget.service.deviceId ?? _ownFallbackId,
        label: ownFriendlyName ?? defaultOwnLabel,
        subtitle: ownFriendlyName == null
            ? null
            : (ownDevice?.name.isNotEmpty == true
                  ? ownDevice!.name
                  : defaultOwnLabel),
        isOwn: true,
        // The app is running on this machine — ONLINE locally, the
        // connector's link state stays the banners' story above.
        dotColor: FahColors.of(context).teal,
        agents: ownFrame?.agents ?? const {},
        localSessions: controller == null
            ? const <ChatListEntry>[]
            : deviceVisibleLocalSessions(controller),
      ),
      for (final entry in _remote.entries)
        _DeviceEntry(
          id: entry.key,
          label: entry.value.roster?.displayName ?? entry.key,
          subtitle: entry.value.roster?.friendlyName == null
              ? null
              : entry.value.roster!.name,
          dotColor: deviceMachineDotColor(
            FahColors.of(context),
            entry.value.machine,
          ),
          agents: entry.value.presence?.agents ?? const {},
          exposedSessions: entry.value.presence?.sessions ?? const {},
        ),
    ];
  }

  /// The pane's device: the stored selection while the device exists,
  /// otherwise the rail's first entry (stream updates never reset a
  /// live selection).
  _DeviceEntry _resolveSelected(List<_DeviceEntry> devices) {
    final id = _selectedDeviceId;
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return devices.first;
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

/// The merge point for one remote machine's REST identity and live presence.
/// Before either source reports a state, the honest fallback is offline.
class _RemoteDeviceNode {
  const _RemoteDeviceNode({this.roster, this.presence});

  final DeviceInfo? roster;
  final PresenceFrame? presence;

  MachinePresence get machine =>
      presence?.machine ??
      MachinePresence.tryParse(roster?.presence ?? '') ??
      MachinePresence.offline;
}

/// One device's rail+pane view model: identity (id + label + optional raw
/// host-name subtitle), the §5 presence dot color, and the pane children
/// (agents, this machine's local chat sessions, or exposed sessions).
class _DeviceEntry {
  const _DeviceEntry({
    required this.id,
    required this.label,
    this.subtitle,
    required this.dotColor,
    this.isOwn = false,
    this.agents = const {},
    this.exposedSessions = const {},
    this.localSessions = const [],
  });

  /// The selection identity + avatar hue seed (the device id; the own
  /// device falls back to its display id).
  final String id;
  final String label;

  /// The enrollment host name shown in L2 when a friendly name is set.
  final String? subtitle;

  /// True for This device (the `deviceRow`/`deviceAvatar`/`deviceDot`
  /// unsuffixed keys).
  final bool isOwn;
  final Color dotColor;
  final Map<String, AgentRunState> agents;
  final Map<String, ConnectorSessionPresence> exposedSessions;
  final List<ChatListEntry> localSessions;
}

/// The device avatar rail — the NETWORKS strip over devices (owner pass):
/// one Ø50 letter-gradient avatar per [DevicesPage.railItemPitch] cell,
/// no labels or status meta. The selected device paints the accent
/// capsule flush to the rail's left edge and squares its avatar; a tap
/// switches the pane. No scrollbar thumb (the strip's owner clip).
class _DeviceRail extends StatelessWidget {
  const _DeviceRail({
    required this.devices,
    required this.selectedId,
    required this.onSelect,
    required this.onRenameOwn,
  });

  final List<_DeviceEntry> devices;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onRenameOwn;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) return const SizedBox.shrink();
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView(
        key: const ValueKey('deviceRail'),
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final device in devices)
            _DeviceRailCell(
              key: ValueKey(
                device.isOwn ? 'deviceRow' : 'deviceRow:${device.id}',
              ),
              device: device,
              selected: device.id == selectedId,
              onTap: onSelect,
              onLongPress: device.isOwn ? onRenameOwn : null,
            ),
        ],
      ),
    );
  }
}

/// One rail cell: the avatar centered on the ~70pt pitch, the selection
/// capsule flush to the rail's left edge when selected (the networks
/// strip's indicator, key-for-key naming).
class _DeviceRailCell extends StatelessWidget {
  const _DeviceRailCell({
    super.key,
    required this.device,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final _DeviceEntry device;
  final bool selected;
  final ValueChanged<String> onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      width: DevicesPage.railWidth,
      height: DevicesPage.railItemPitch,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onTap(device.id),
          onLongPress: onLongPress,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Tooltip(
                message: device.label,
                // Own-avatar long press is rename, not tooltip reveal.
                triggerMode: onLongPress == null
                    ? null
                    : TooltipTriggerMode.manual,
                child: Semantics(
                  button: true,
                  selected: selected,
                  label: device.label,
                  child: _DeviceAvatar(
                    key: ValueKey(
                      device.isOwn
                          ? 'deviceAvatar'
                          : 'deviceAvatar:${device.id}',
                    ),
                    seed: device.id,
                    dotKey: ValueKey(
                      device.isOwn ? 'deviceDot' : 'deviceDot:${device.id}',
                    ),
                    dotColor: device.dotColor,
                    selected: selected,
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  left: 0,
                  top:
                      (DevicesPage.railItemPitch - DevicesPage.capsuleHeight) /
                      2,
                  child: Container(
                    key: const ValueKey('deviceSelectedCapsule'),
                    width: DevicesPage.capsuleWidth,
                    height: DevicesPage.capsuleHeight,
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      borderRadius: BorderRadius.circular(
                        DevicesPage.capsuleWidth / 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The device avatar: the strip avatar's geometry ([folderAvatarGradient]
/// seeded by the device id — circles rest unselected, the selected one
/// squares up at ~25% radius) carrying the vector device glyph in the
/// letter's on-color spec (WHITE @ 95%) instead of a letter, plus the §5
/// presence dot as the badge — status rides the avatar dot. No SVG
/// assets ship in the app bundle, so the glyph is the theme-resolved
/// [FaSemanticIcon] vector (the ratchet allows no `Icons.*` literals in
/// Fa files).
class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({
    super.key,
    required this.seed,
    required this.dotKey,
    required this.dotColor,
    required this.selected,
  });

  final String seed;
  final Key dotKey;
  final Color dotColor;

  /// The selected cell's squircle (the networks strip's treatment — no
  /// ring: the capsule is the selection indicator).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final size = DevicesPage.railAvatarSize;
    final (start, end) = folderAvatarGradient(seed);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                selected ? size * 0.25 : size / 2,
              ),
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

/// The selected device's pane: the device label as the pane header, then
/// the children — agents in the roster-row form, the session cards
/// (local ones tappable through the shell's open flow, remote exposed
/// ones read-only) — or the muted no-sessions hint.
class _DevicePane extends StatelessWidget {
  const _DevicePane({
    required this.device,
    this.onOpenSession,
    this.selectedSessionId,
    this.onRenameOwn,
  });

  final _DeviceEntry device;
  final VoidCallback? onRenameOwn;

  /// The shell's open flow for [_DeviceEntry.localSessions]; null keeps
  /// them read-only (remote machines never carry local sessions).
  final ValueChanged<ChatListEntry>? onOpenSession;

  /// The currently open session's id — its card renders the accent fill.
  final String? selectedSessionId;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final hasChildren =
        device.agents.isNotEmpty ||
        device.exposedSessions.isNotEmpty ||
        device.localSessions.isNotEmpty;
    return Column(
      key: ValueKey('devicePane:${device.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.label,
                      key: const ValueKey('devicePaneTitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (device.subtitle case final subtitle?)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          key: const ValueKey('devicePaneSubtitle'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.dim, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
              if (device.isOwn)
                IconButton(
                  key: const ValueKey('renameOwnDeviceButton'),
                  onPressed: onRenameOwn,
                  tooltip: context.l10n.networkDeviceRenameAction,
                  visualDensity: VisualDensity.compact,
                  icon: FaIcon(
                    FaSemanticIcon.edit,
                    size: 17,
                    color: colors.dim,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: hasChildren
              ? _childrenList(context, colors)
              : _emptyHint(context, colors),
        ),
      ],
    );
  }

  /// The honest empty state — the networks pane's centered muted line.
  Widget _emptyHint(BuildContext context, FahColors colors) => Center(
    child: Padding(
      key: const ValueKey('deviceNoSessionsHint'),
      padding: const EdgeInsets.all(16),
      child: Text(
        context.l10n.noSessionsHint,
        textAlign: TextAlign.center,
        style: TextStyle(color: colors.dim, fontSize: 12),
      ),
    ),
  );

  /// The children: agents first (the roster-row form), then the session
  /// cards — the local chat sessions (tappable, the shell's open flow)
  /// before the remote machine's exposed sessions (read-only).
  Widget _childrenList(BuildContext context, FahColors colors) => ListView(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    children: [
      for (final entry in device.agents.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
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
      for (final entry in device.localSessions)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _localSessionCard(context, colors, entry),
        ),
      for (final entry in device.exposedSessions.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: DeviceSessionCard(
            key: ValueKey('sessionRow:${entry.key}'),
            dotKey: ValueKey('sessionDot:${entry.key}'),
            dotColor: deviceSessionDotColor(colors, entry.value),
            title: entry.key,
            subtitle: deviceSessionLabel(context, entry.value),
          ),
        ),
    ],
  );

  /// One local chat session card: the chat list's presence colors the
  /// glyph-tile badge, the subtitle is the last-activity timestamp, and
  /// the tap routes through the shell's open flow (null ⇒ read-only).
  /// The shell's currently open session renders the accent fill.
  Widget _localSessionCard(
    BuildContext context,
    FahColors colors,
    ChatListEntry entry,
  ) {
    final id = entry.id.value;
    return DeviceSessionCard(
      key: ValueKey('sessionRow:$id'),
      dotKey: ValueKey('sessionDot:$id'),
      dotColor: deviceLocalSessionDotColor(colors, entry.presence),
      title: entry.title,
      subtitle: chatListRelativeTime(
        context,
        entry.lastActivity ?? entry.createdAt,
      ),
      selected: id == selectedSessionId,
      onTap: onOpenSession == null ? null : () => onOpenSession!(entry),
    );
  }
}

/// Friendly-name editor. Validation is rune-based to match the deployed
/// server contract (a 64-emoji name is valid despite 128 UTF-16 code units).
class _RenameDeviceDialog extends StatefulWidget {
  const _RenameDeviceDialog({
    required this.initialName,
    required this.onRename,
  });

  final String initialName;
  final Future<String?> Function(String name) onRename;

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController _name;
  var _busy = false;
  var _tooLong = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _name.text;
    if (name.runes.length > 64) {
      setState(() {
        _tooLong = true;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _tooLong = false;
      _error = null;
    });
    try {
      await widget.onRename(name);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.networkDeviceRenameError(error.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return AlertDialog(
      title: Text(context.l10n.networkDeviceRenameTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('renameDeviceName'),
            controller: _name,
            autofocus: true,
            enabled: !_busy,
            maxLines: 1,
            decoration: InputDecoration(
              labelText: context.l10n.networkDeviceNameLabel,
              helperText: context.l10n.networkDeviceNameClearHint,
              errorText: _tooLong
                  ? context.l10n.networkDeviceNameTooLong
                  : null,
              counter: Text(
                '${_name.text.runes.length}/64',
                key: const ValueKey('renameDeviceNameCounter'),
                style: TextStyle(
                  color: _tooLong ? colors.error : colors.dim,
                  fontSize: 11,
                ),
              ),
            ),
            onChanged: (_) => setState(() {
              if (_tooLong && _name.text.runes.length <= 64) _tooLong = false;
              _error = null;
            }),
            onSubmitted: (_) => unawaited(_submit()),
          ),
          if (_error case final error?)
            Padding(
              key: const ValueKey('renameDeviceError'),
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('renameDeviceConfirm'),
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.networkRename),
        ),
      ],
    );
  }
}
