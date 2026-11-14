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
    this.onOpenRemoteConversation,
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

  /// Remote session/agent tap: the SHELL opens the DM as a virtual
  /// channel in its message column (NetworkChatPage reuse — the sidebar
  /// keeps the roster, the tapped row highlights). Null = read-only rows.
  final void Function({
    required String deviceId,
    required String deviceLabel,
    required String agentAddress,
    String? sessionId,
  })?
  onOpenRemoteConversation;

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

  /// The open DM conversation (a remote session/agent tap); null shows
  /// the selected device's pane. Switching devices clears it.
  /// The tapped remote session awaiting its chat in the shell's message
  /// column (highlight only — the conversation itself is the shell's).
  String? _selectedRemoteSessionId;

  StreamSubscription<NetworkEnvelope>? _framesSubscription;
  StreamSubscription<NetworkEnvelope>? _rosterSubscription;
  var _fetchingRoster = false;

  /// False only until the first usable own/remote projection has been shown.
  /// Later WS phase flips must not replace that projection with a skeleton.
  var _hasPresentedBody = false;

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
    _hasPresentedBody = false;
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
      final remoteIds = remote.map((device) => device.deviceId).toSet();
      setState(() {
        // A successful account snapshot also RETIRES rows that disappeared
        // or were revoked. Presence-only rows stay until the next roster
        // refresh; cached REST rows must not become permanent phantoms.
        _remote.removeWhere(
          (id, node) => node.rosterFromAccount && !remoteIds.contains(id),
        );
        for (final device in remote) {
          final previous = _remote[device.deviceId];
          _remote[device.deviceId] = _RemoteDeviceNode(
            roster: device,
            presence: previous?.presence,
            agentDmPubs: device.agentDmPubs.isNotEmpty
                ? device.agentDmPubs
                : previous?.agentDmPubs ?? const {},
            rosterFromAccount: true,
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

  /// Test seam for the full-address DM public-key projection on one device.
  @visibleForTesting
  Map<String, String> debugRemoteAgentDmPubs(String deviceId) =>
      Map.unmodifiable(_remote[deviceId]?.agentDmPubs ?? const {});

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
        agentDmPubs: _remote[deviceId]?.agentDmPubs ?? const {},
        rosterFromAccount: _remote[deviceId]?.rosterFromAccount ?? false,
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
      rosterFromAccount: previous?.rosterFromAccount ?? false,
      agentDmPubs: device['agents'] is List
          ? roster.agentDmPubs
          : previous?.agentDmPubs ?? const {},
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
        sessionMetadata: _serverSessionMetadata(
          device['sessions'],
          oldPresence?.sessionMetadata,
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
    // ROSTER carries the complete persisted projection. PRESENCE carries
    // live/heartbeat deltas from the registry (often live-only, sometimes an
    // explicit empty list): merge those deltas instead of erasing hundreds of
    // persisted REST rows after the next heartbeat.
    final sessions = <String, ConnectorSessionPresence>{
      if (kind == NetworkEnvelopeKind.presence) ...?previous,
    };
    for (final node in value) {
      if (node is! Map) continue;
      final id = node['id'];
      if (id is! String || id.isEmpty) continue;
      final legacyKnownRow =
          kind == NetworkEnvelopeKind.presence &&
          node['networks'] is! List &&
          (previous?.containsKey(id) ?? false);
      if (!_serverSessionVisible(node, kind) && !legacyKnownRow) {
        if (kind == NetworkEnvelopeKind.presence && node['networks'] is List) {
          sessions.remove(id);
        }
        continue;
      }
      final state = ConnectorSessionPresence.tryParse('${node['state'] ?? ''}');
      if (state != null) sessions[id] = state;
    }
    return sessions;
  }

  Map<String, ConnectorSessionMetadata> _serverSessionMetadata(
    Object? value,
    Map<String, ConnectorSessionMetadata>? previous,
    NetworkEnvelopeKind kind,
  ) {
    if (value is! List) return previous ?? const {};
    final metadata = <String, ConnectorSessionMetadata>{
      if (kind == NetworkEnvelopeKind.presence) ...?previous,
    };
    for (final node in value) {
      if (node is! Map) continue;
      final id = node['id'];
      if (id is! String || id.isEmpty) continue;
      final legacyKnownRow =
          kind == NetworkEnvelopeKind.presence &&
          node['networks'] is! List &&
          (previous?.containsKey(id) ?? false);
      if (!_serverSessionVisible(node, kind) && !legacyKnownRow) {
        if (kind == NetworkEnvelopeKind.presence && node['networks'] is List) {
          metadata.remove(id);
        }
        continue;
      }
      final parsed = ConnectorSessionMetadata.fromJson(node);
      if (parsed != null) metadata[id] = parsed;
    }
    return metadata;
  }

  bool _serverSessionVisible(
    Map<Object?, Object?> session,
    NetworkEnvelopeKind kind,
  ) {
    final networks = session['networks'];
    // An explicitly empty exposure list is a deletion/retraction patch, not
    // a persisted row to render. Stop/offline rows that remain exposed keep
    // their personal network and therefore remain visible.
    if (networks is List && networks.isEmpty) return false;
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
        final waitingForConnection =
            phase == DeviceConnectorPhase.preparing ||
            phase == DeviceConnectorPhase.connecting;
        if (!waitingForConnection) _hasPresentedBody = true;
        return Column(
          key: const ValueKey('devicesPage'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader(context, colors),
            Expanded(
              child: waitingForConnection && !_hasPresentedBody
                  ? _phaseLine(
                      context,
                      key: const ValueKey('devicesSkeleton'),
                      label: context.l10n.networkDeviceConnecting,
                      color: colors.dim.withValues(alpha: 0.5),
                    )
                  : _connectedBody(context, colors, phase),
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
      if (phase == DeviceConnectorPhase.preparing ||
          phase == DeviceConnectorPhase.connecting)
        _phaseLine(
          context,
          key: const ValueKey('devicesConnecting'),
          label: context.l10n.networkDeviceConnecting,
          color: colors.dim.withValues(alpha: 0.5),
        ),
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
            // TEMP flap trace (issue #2062 field feedback).
            assert(() {
              debugPrint(
                '[roster] entries=${devices.map((d) => d.id).join(',')} '
                'remote=${_remote.keys.join('|')} phase=${widget.service.phase}',
              );
              return true;
            }());
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: DevicesPage.railWidth,
                  child: _DeviceRail(
                    devices: devices,
                    selectedId: selected.id,
                    onSelect: (id) => setState(() {
                      _selectedDeviceId = id;
                      _selectedRemoteSessionId = null;
                    }),
                    onRenameOwn: () => unawaited(_renameOwnDevice()),
                  ),
                ),
                VerticalDivider(width: 1, color: FahColors.of(context).border),
                Expanded(
                  child: _DevicePane(
                    device: selected,
                    onOpenSession: widget.onOpenSession,
                    selectedSessionId: widget.selectedSessionId,
                    selectedRemoteSessionId: _selectedRemoteSessionId,
                    onRenameOwn: () => unawaited(_renameOwnDevice()),
                    onOpenConversation: (deviceId, agentAddress, sessionId) {
                      setState(() => _selectedRemoteSessionId = sessionId);
                      widget.onOpenRemoteConversation?.call(
                        deviceId: deviceId,
                        deviceLabel: selected.label,
                        agentAddress: agentAddress,
                        sessionId: sessionId,
                      );
                    },
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
    final ownMachineKey = _enrollmentMachineGroupKey(ownDevice);
    final ownSessionIds = <String>{
      ...?ownFrame?.sessions.keys,
      ...?controller?.localEntries.map((entry) => entry.id.value),
    };

    // One PHYSICAL machine = one card. Union enrollments by a meaningful
    // hostname (or owner-friendly identity for legacy `device` rows) AND by
    // shared persisted session ids. The latter recovers duplicate generic
    // enrollments of the same machine without merging unrelated online
    // devices that merely share the placeholder name `device`.
    final entries = [
      for (final entry in _remote.entries)
        if (!_hiddenRemoteEnrollment(entry.value)) entry,
    ];
    final parents = List<int>.generate(entries.length, (index) => index);
    int rootOf(int index) {
      var root = index;
      while (parents[root] != root) {
        root = parents[root];
      }
      while (parents[index] != index) {
        final next = parents[index];
        parents[index] = root;
        index = next;
      }
      return root;
    }

    void union(int left, int right) {
      final leftRoot = rootOf(left);
      final rightRoot = rootOf(right);
      if (leftRoot != rightRoot) parents[rightRoot] = leftRoot;
    }

    final identityOwners = <String, int>{};
    final sessionOwners = <String, int>{};
    final ownMembers = List<bool>.filled(entries.length, false);
    for (var i = 0; i < entries.length; i++) {
      final node = entries[i].value;
      final identity = _enrollmentMachineGroupKey(node.roster);
      if (identity != null) {
        if (identity == ownMachineKey) ownMembers[i] = true;
        final previous = identityOwners[identity];
        if (previous == null) {
          identityOwners[identity] = i;
        } else {
          union(previous, i);
        }
      }
      for (final id in node.presence?.sessions.keys ?? const <String>{}) {
        if (ownSessionIds.contains(id)) ownMembers[i] = true;
        final previous = sessionOwners[id];
        if (previous == null) {
          sessionOwners[id] = i;
        } else {
          union(previous, i);
        }
      }
    }
    final ownRoots = <int>{
      for (var i = 0; i < entries.length; i++)
        if (ownMembers[i]) rootOf(i),
    };
    final ownMerged = <_RemoteDeviceNode>[];
    final groupedIndexes = <int, List<int>>{};
    final order = <int>[];
    for (var i = 0; i < entries.length; i++) {
      if (ownRoots.contains(rootOf(i))) {
        ownMerged.add(entries[i].value);
        continue;
      }
      final root = rootOf(i);
      if (!groupedIndexes.containsKey(root)) order.add(root);
      (groupedIndexes[root] ??= []).add(i);
    }
    final remoteGroups = <String, List<_RemoteDeviceNode>>{};
    final groupDevices = <String, List<String>>{};
    final groupKeys = <String>[];
    for (final root in order) {
      final indexes = groupedIndexes[root]!;
      final ids = [for (final index in indexes) entries[index].key];
      final identity = indexes
          .map(
            (index) => _enrollmentMachineGroupKey(entries[index].value.roster),
          )
          .whereType<String>()
          .firstOrNull;
      final key =
          identity ??
          (ids.length == 1 ? 'device:${ids.first}' : 'shared:${ids.first}');
      groupKeys.add(key);
      remoteGroups[key] = [for (final index in indexes) entries[index].value];
      groupDevices[key] = ids;
    }

    Map<String, AgentRunState> mergedAgents(Iterable<_RemoteDeviceNode> nodes) {
      final result = <String, AgentRunState>{};
      for (final node in nodes) {
        result.addAll(node.presence?.agents ?? const {});
      }
      return result;
    }

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
        icon: devicePlatformIcon(
          name: ownDevice?.name,
          friendlyName: ownFriendlyName,
        ),
        // The app is running on this machine — ONLINE locally, the
        // connector's link state stays the banners' story above.
        dotColor: FahColors.of(context).teal,
        agents: {...?ownFrame?.agents, ...mergedAgents(ownMerged)},
        agentDmPubs: {for (final node in ownMerged) ...node.agentDmPubs},
        exposedSessions: {
          for (final node in ownMerged) ...?node.presence?.sessions,
        },
        sessionMetadata: {
          for (final node in ownMerged) ...?node.presence?.sessionMetadata,
        },
        memberDeviceIds: {
          ?widget.service.deviceId,
          for (final entry in _remote.entries)
            if (ownMerged.contains(entry.value)) entry.key,
        },
        sessionDeviceIds: {
          for (final entry in _remote.entries)
            if (ownMerged.contains(entry.value))
              for (final id
                  in entry.value.presence?.sessions.keys ?? const <String>{})
                id: entry.key,
        },
        agentDeviceIds: {
          for (final entry in _remote.entries)
            if (ownMerged.contains(entry.value))
              for (final name
                  in entry.value.presence?.agents.keys ?? const <String>{})
                name: entry.key,
        },
        localSessions: controller == null
            ? const <ChatListEntry>[]
            : deviceVisibleLocalSessions(controller),
      ),
      for (final groupKey in groupKeys)
        _remoteGroupEntry(
          context,
          groupKey,
          remoteGroups[groupKey]!,
          groupDevices[groupKey]!,
        ),
    ];
  }

  /// One remote card: a single device keeps its id/label; a same-hostname
  /// group merges agents/sessions with any-online presence.
  _DeviceEntry _remoteGroupEntry(
    BuildContext context,
    String groupKey,
    List<_RemoteDeviceNode> nodes,
    List<String> deviceIds,
  ) {
    final colors = FahColors.of(context);
    final first = nodes.first;
    final single = nodes.length == 1;
    // Any-online group presence: the BEST member state wins (online >
    // degraded > offline — enum declaration order).
    final best = nodes
        .map((node) => node.machine)
        .reduce((a, b) => a.index <= b.index ? a : b);
    final label = single
        ? (first.roster?.displayName ?? deviceIds.first)
        : (nodes
                  .map((node) => node.roster?.friendlyName)
                  .whereType<String>()
                  .firstOrNull ??
              first.roster?.name ??
              groupKey);
    return _DeviceEntry(
      id: single ? deviceIds.first : 'machine:$groupKey',
      label: label,
      subtitle: single
          ? (first.roster?.friendlyName == null ? null : first.roster!.name)
          : first.roster?.name,
      dotColor: deviceMachineDotColor(colors, best),
      icon: devicePlatformIcon(
        name: first.roster?.name,
        friendlyName: first.roster?.friendlyName,
      ),
      agents: {for (final node in nodes) ...?node.presence?.agents},
      agentDmPubs: {for (final node in nodes) ...node.agentDmPubs},
      exposedSessions: {for (final node in nodes) ...?node.presence?.sessions},
      sessionMetadata: {
        for (final node in nodes) ...?node.presence?.sessionMetadata,
      },
      memberDeviceIds: deviceIds.toSet(),
      sessionDeviceIds: {
        for (var i = 0; i < nodes.length; i++)
          for (final id in nodes[i].presence?.sessions.keys ?? const <String>{})
            id: deviceIds[i],
      },
      agentDeviceIds: {
        for (var i = 0; i < nodes.length; i++)
          for (final name in nodes[i].presence?.agents.keys ?? const <String>{})
            name: deviceIds[i],
      },
    );
  }

  /// The pane's device: the stored selection while the device exists,
  /// otherwise the rail's first entry (stream updates never reset a
  /// live selection).
  _DeviceEntry _resolveSelected(List<_DeviceEntry> devices) {
    final id = _selectedDeviceId;
    for (final device in devices) {
      if (device.id == id || device.memberDeviceIds.contains(id)) {
        return device;
      }
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

/// The machine-group key for an enrollment hostname: normalized lowercase,
/// null for generic/empty names. A generic placeholder alone is NOT proof
/// that two machines match; shared sessions or a friendly identity must also
/// link them (see the rail's grouping pass).
String? machineGroupKey(String? name) {
  final normalized = name?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty || normalized == 'device') return null;
  return normalized;
}

String? _enrollmentMachineGroupKey(DeviceInfo? device) =>
    machineGroupKey(device?.name) ?? machineGroupKey(device?.friendlyName);

/// Repeated integration-test enrollments have no useful identity, presence,
/// or children. Hide those dead account rows instead of letting dozens of
/// `device` phantoms dominate the rail. A live row, a named/friendly row, or
/// any exposed child remains visible; presence-only legacy rows are retained.
bool _hiddenRemoteEnrollment(_RemoteDeviceNode node) {
  final roster = node.roster;
  if (roster == null) return false;
  if (roster.revokedAt != null) return true;
  if (_enrollmentMachineGroupKey(roster) != null) return false;
  if (node.machine != MachinePresence.offline) return false;
  final empty =
      (node.presence?.agents.isEmpty ?? true) &&
      (node.presence?.sessions.isEmpty ?? true);
  final enrolledAt = roster.createdAt;
  final longDead =
      enrolledAt != null &&
      DateTime.now().difference(enrolledAt) > const Duration(hours: 24);
  return empty || longDead;
}

/// The platform glyph for a device avatar: laptop for desktop-class
/// hostnames, phone for mobile enrollments, null = the generic device
/// glyph. Heuristic until the server carries a platform field.
FaSemanticIcon? devicePlatformIcon({String? name, String? friendlyName}) {
  final text = '${name ?? ''} ${friendlyName ?? ''}'.toLowerCase();
  if (text.contains('iphone') ||
      text.contains('ipad') ||
      text.contains('android') ||
      text.contains('phone') ||
      text.contains('duo')) {
    return FaSemanticIcon.phone;
  }
  if (text.contains('mac') ||
      text.contains('imac') ||
      RegExp(r'\b(epby|epam|mbp|pc|win|ubuntu|linux)\b').hasMatch(text) ||
      RegExp(r'^[a-z]{2,}[0-9]{2,}').hasMatch(text.trim())) {
    return FaSemanticIcon.laptop;
  }
  return null;
}

/// The merge point for one remote machine's REST identity and live presence.
/// Before either source reports a state, the honest fallback is offline.
class _RemoteDeviceNode {
  const _RemoteDeviceNode({
    this.roster,
    this.presence,
    this.agentDmPubs = const {},
    this.rosterFromAccount = false,
  });

  final DeviceInfo? roster;
  final PresenceFrame? presence;

  /// Whether [roster] came from the account device list (rather than a
  /// network roster envelope). Only account-owned rows are pruned when a
  /// later account snapshot omits them.
  final bool rosterFromAccount;

  /// Roster `agents[].dmPub`, keyed by full agent address for DM sending.
  final Map<String, String> agentDmPubs;

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
    this.agentDmPubs = const {},
    this.exposedSessions = const {},
    this.sessionMetadata = const {},
    this.memberDeviceIds = const {},
    this.sessionDeviceIds = const {},
    this.agentDeviceIds = const {},
    this.localSessions = const [],
    this.icon,
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

  /// Full agent address → base64 X25519 public key from the server roster.
  final Map<String, String> agentDmPubs;
  final Map<String, ConnectorSessionPresence> exposedSessions;
  final Map<String, ConnectorSessionMetadata> sessionMetadata;

  /// All enrollment ids folded into this physical-machine entry. Used to
  /// preserve a selection when a duplicate arrives and the group id changes.
  final Set<String> memberDeviceIds;

  /// Exposed session id → its origin device id (machine-grouped cards
  /// merge sessions from several devices; the DM target needs the origin).
  final Map<String, String> sessionDeviceIds;

  /// Agent name → its origin device id (the same grouping merge; agent
  /// rows key by plain name, so the DM address is rebuilt per device).
  final Map<String, String> agentDeviceIds;
  final List<ChatListEntry> localSessions;

  /// The platform glyph override (null = the generic device vector glyph).
  final FaSemanticIcon? icon;
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
                    icon: device.icon,
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
    this.icon,
  });

  final String seed;
  final Key dotKey;
  final Color dotColor;

  /// The platform glyph (null = the generic device vector glyph).
  final FaSemanticIcon? icon;

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
              icon ?? FaSemanticIcon.devices,
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
    this.selectedRemoteSessionId,
    this.onRenameOwn,
    this.onOpenConversation,
  });

  final _DeviceEntry device;
  final VoidCallback? onRenameOwn;

  /// Opens the DM conversation for (deviceId, full agent address, sessionId?).
  final void Function(String deviceId, String agentAddress, String? sessionId)?
  onOpenConversation;

  /// The shell's open flow for [_DeviceEntry.localSessions]; null keeps
  /// them read-only (remote machines never carry local sessions).
  final ValueChanged<ChatListEntry>? onOpenSession;

  /// The currently open session's id — its card renders the accent fill.
  final String? selectedSessionId;

  /// The remote session whose DM is open in the shell's message column.
  final String? selectedRemoteSessionId;

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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
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
                        ),
                        if (device.isOwn)
                          Container(
                            key: const ValueKey('currentDeviceBadge'),
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.teal.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              context.l10n.networkDeviceThisDevice
                                  .toLowerCase(),
                              style: TextStyle(
                                color: colors.teal,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
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

  /// The children: agents first (the roster-row form), then Local-style
  /// session rows. Duplicate enrollments folded into This device must not
  /// repeat a session already supplied by the canonical local controller.
  Widget _childrenList(BuildContext context, FahColors colors) {
    final localIds = device.localSessions
        .map((entry) => entry.id.value)
        .toSet();
    final remote = [
      for (final entry in device.exposedSessions.entries)
        if (!localIds.contains(entry.key)) entry,
    ];
    DateTime? activity(MapEntry<String, ConnectorSessionPresence> entry) =>
        device.sessionMetadata[entry.key]?.lastActivity;
    remote.sort((left, right) {
      final leftActivity = activity(left);
      final rightActivity = activity(right);
      if (leftActivity == null && rightActivity != null) return 1;
      if (leftActivity != null && rightActivity == null) return -1;
      final byActivity = rightActivity?.compareTo(leftActivity!) ?? 0;
      return byActivity != 0 ? byActivity : left.key.compareTo(right.key);
    });
    final sessionCount = device.localSessions.length + remote.length;
    var sessionIndex = 0;
    return ListView(
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
              onTap: onOpenConversation == null
                  ? null
                  : () {
                      final deviceId =
                          device.agentDeviceIds[entry.key] ?? device.id;
                      onOpenConversation!(
                        deviceId,
                        '${entry.key}@$deviceId',
                        null,
                      );
                    },
            ),
          ),
        for (final entry in device.localSessions)
          _localSessionCard(
            context,
            colors,
            entry,
            hairline: sessionIndex++ < sessionCount - 1,
          ),
        for (final entry in remote)
          DeviceSessionCard(
            key: ValueKey('sessionRow:${entry.key}'),
            dotKey: ValueKey('sessionDot:${entry.key}'),
            dotColor: deviceSessionDotColor(colors, entry.value),
            title: _sessionTitle(
              entry.key,
              device.sessionMetadata[entry.key]?.title,
            ),
            subtitle: device.sessionMetadata[entry.key]?.path ?? '',
            timestamp: chatListRelativeTime(
              context,
              device.sessionMetadata[entry.key]?.lastActivity,
            ),
            showPresenceDot: entry.value == ConnectorSessionPresence.live,
            hairline: sessionIndex++ < sessionCount - 1,
            selected: entry.key == selectedRemoteSessionId,
            onTap: _sessionConversation(entry.key),
          ),
      ],
    );
  }

  /// The DM target for an exposed session card: its origin device (the
  /// group-merge map) plus that device's first exposed agent address.
  /// Null keeps the card read-only (no agent published for the device).
  VoidCallback? _sessionConversation(String sessionId) {
    final open = onOpenConversation;
    if (open == null) return null;
    final deviceId = device.sessionDeviceIds[sessionId] ?? device.id;
    for (final name in device.agents.keys) {
      if ((device.agentDeviceIds[name] ?? device.id) == deviceId) {
        return () => open(deviceId, '$name@$deviceId', sessionId);
      }
    }
    return null;
  }

  /// One Local-format chat row: title + right timestamp + project path.
  /// Only an actually live/streaming local session carries an activity dot.
  Widget _localSessionCard(
    BuildContext context,
    FahColors colors,
    ChatListEntry entry, {
    required bool hairline,
  }) {
    final id = entry.id.value;
    final active =
        entry.presence == ChatPresence.live ||
        entry.presence == ChatPresence.busy;
    return DeviceSessionCard(
      key: ValueKey('sessionRow:$id'),
      dotKey: ValueKey('sessionDot:$id'),
      dotColor: deviceLocalSessionDotColor(colors, entry.presence),
      title: _sessionTitle(id, entry.title),
      subtitle: entry.folderPath ?? '',
      timestamp: chatListRelativeTime(
        context,
        entry.lastActivity ?? entry.createdAt,
      ),
      hairline: hairline,
      showPresenceDot: active,
      selected: id == selectedSessionId,
      onTap: onOpenSession == null ? null : () => onOpenSession!(entry),
    );
  }
}

String _sessionTitle(String id, String? rawTitle) {
  final title = rawTitle?.trim();
  // ChatListEntry's last-resort title is the id itself. Treat that as "no
  // title" too, so a full UUID never leaks through the rich metadata path.
  if (title != null && title.isNotEmpty && title != id) return title;
  return id.length > 8 ? id.substring(0, 8) : id;
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
