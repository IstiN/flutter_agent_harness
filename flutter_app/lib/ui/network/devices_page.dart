// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/device_display.dart';
import 'package:fa/network/device_name.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart' show chatListRelativeTime;
import 'package:fa/ui/chats/local_session_folders.dart'
    show folderAvatarGradient;
import 'package:fa/ui/chats/messenger_drilldown_panel.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';

import 'package:fa_ui/fa_ui.dart';
// The presence payload model is pure Dart in the connector core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// The DEVICES section reuses the Networks navigation composition: level 1
/// is a comfortable named device list; a tap opens the same 70pt avatar
/// mini-strip beside the selected device's content with the shared slide /
/// fade transition and a back + current-device header.
///
/// The content lists agents followed by one flat, avatarless session adapter
/// for both local and remote devices. Project paths remain row metadata and
/// never conditionally change the navigation shape. Local cards use the
/// shell's open flow; remote cards open their exposed DM when available.
/// Selection persists while presence frames stream updates. The own device
/// is ONLINE LOCALLY; remote machines read their latest [PresenceFrame].
///
/// Data: [DeviceConnectorService.presence] (the local machine's own
/// heartbeat view) + roster/presence streams whose `payload.devices` rows
/// accumulate as remote machines (legacy `payload.deviceId` frames remain
/// supported). Signed out → the not-running retry line above the rail;
/// connecting → skeleton line; link lost → a muted reconnecting line above
/// the last-known rail.
/// Shared desktop/mobile first-connect friendly-name question. Empty input
/// resolves to [defaultName]; dismissing returns null (the connector retains
/// the same default rather than creating an unnamed device).
Future<String?> showDeviceEnrollmentNameDialog(
  BuildContext context, {
  required String defaultName,
}) => showDialog<String>(
  context: context,
  builder: (_) => _DeviceEnrollmentNameDialog(defaultName: defaultName),
);

final class _DeviceEnrollmentNameDialog extends StatefulWidget {
  const _DeviceEnrollmentNameDialog({required this.defaultName});

  final String defaultName;

  @override
  State<_DeviceEnrollmentNameDialog> createState() =>
      _DeviceEnrollmentNameDialogState();
}

final class _DeviceEnrollmentNameDialogState
    extends State<_DeviceEnrollmentNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.defaultName.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final entered = _controller.text.trim();
    Navigator.of(context).pop(entered.isEmpty ? widget.defaultName : entered);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const ValueKey('enrollDeviceNameDialog'),
      title: Text(l10n.networkDeviceEnrollNameTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.networkDeviceEnrollNamePrompt),
          const SizedBox(height: 16),
          FaTextField(
            key: const ValueKey('enrollDeviceName'),
            controller: _controller,
            autofocus: true,
            maxLength: 64,
            labelText: l10n.networkDeviceNameLabel,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        FaButton(
          key: const ValueKey('enrollDeviceNameCancel'),
          label: l10n.commonCancel,
          variant: FaButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FaButton(
          key: const ValueKey('enrollDeviceNameConfirm'),
          label: l10n.networkDeviceEnrollNameAction,
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// Stale, timestamped offline rows disappear from Devices after 30 days.
/// This is only a client display TTL; fa_network must reap its stored rows.
const deviceOfflineSessionRetention = Duration(days: 30);

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.service,
    this.compact = false,
    this.now,
    this.sessions,
    this.onOpenSession,
    this.selectedSessionId,
    this.onOpenRemoteConversation,
    this.initialDeviceId,
  });

  /// The exact shared Networks strip geometry: 70pt column and pitch,
  /// Ø50 avatars, and the ~6x51 accent selection capsule.
  static const double railWidth = MessengerDrilldownMetrics.stripWidth;
  static const double railItemPitch = MessengerDrilldownMetrics.itemPitch;
  static const double railAvatarSize = MessengerDrilldownMetrics.avatarSize;
  static const double capsuleWidth = MessengerDrilldownMetrics.capsuleWidth;
  static const double capsuleHeight = MessengerDrilldownMetrics.capsuleHeight;

  /// The app-scope device connector service (one upstream socket, AC1).
  final DeviceConnectorService service;

  /// Narrow shell chrome uses the same 54pt glass band as Networks.
  final bool compact;

  /// Clock for the 30-day offline-row TTL (injectable in tests).
  final DateTime Function()? now;

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
    String? sessionTitle,
  })?
  onOpenRemoteConversation;

  /// Optional restored drill-down target. Null opens the root device list,
  /// exactly like Networks; legacy pane-oriented tests inject the own id.
  final String? initialDeviceId;

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

  /// The drilled-in device id; null = the root list, like Networks.
  String? _selectedDeviceId;
  String? _selectedDeviceLabel;
  var _selectedDeviceIsOwn = false;

  /// The open DM conversation (a remote session/agent tap); null shows
  /// the selected device's pane. Switching devices clears it.
  /// The tapped remote session awaiting its chat in the shell's message
  /// column (highlight only — the conversation itself is the shell's).
  String? _selectedRemoteSessionId;

  StreamSubscription<NetworkEnvelope>? _framesSubscription;
  StreamSubscription<NetworkEnvelope>? _rosterSubscription;
  var _fetchingRoster = false;

  @override
  void initState() {
    super.initState();
    _selectedDeviceId = widget.initialDeviceId;
    _selectedDeviceIsOwn =
        widget.initialDeviceId != null &&
        (widget.initialDeviceId == widget.service.deviceId ||
            widget.initialDeviceId == _ownFallbackId);
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
      final remoteIds = remote.map((device) => device.deviceId).toSet();
      setState(() {
        // Enrollment can finish AFTER a cached server roster was replayed.
        // At that point the formerly anonymous own echo is known by id and
        // must leave the remote source, not merely be hidden by the layout.
        if (ownId != null && ownId.isNotEmpty) _remote.remove(ownId);
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
            agentDmPubs: _mergedAgentDmPubs(device, previous),
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

  Map<String, String> _mergedAgentDmPubs(
    DeviceInfo device,
    _RemoteDeviceNode? previous,
  ) => device.agentDmPubs.isNotEmpty
      ? device.agentDmPubs
      : previous?.agentDmPubs ?? const {};

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
    // A roster replay can precede credential restoration. Once the local id
    // is available, retract its already-cached echo at the source as well as
    // filtering new own frames below.
    final ownId = widget.service.deviceId;
    if (ownId != null &&
        ownId.isNotEmpty &&
        _remote.remove(ownId) != null &&
        mounted) {
      setState(() {});
    }
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
    final previous = _remote[deviceId];
    final name = envelope.payload['name'] ?? envelope.payload['hostname'];
    final friendly = envelope.payload['friendlyName'];
    final fallbackRoster =
        previous?.roster ??
        ((name is String || friendly is String)
            ? DeviceInfo(
                deviceId: deviceId,
                name: name is String ? name : '',
                friendlyName: friendly is String ? friendly : null,
              )
            : null);
    setState(() {
      _remote[deviceId] = _RemoteDeviceNode(
        roster: fallbackRoster,
        presence: frame,
        agentDmPubs: previous?.agentDmPubs ?? const {},
        rosterFromAccount: previous?.rosterFromAccount ?? false,
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
        agents: _serverAgents(
          device['agents'],
          oldPresence?.agents,
          deviceId: roster.deviceId,
        ),
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
    Map<String, AgentRunState>? previous, {
    required String deviceId,
  }) {
    if (value is! List) return previous ?? const {};
    final agents = <String, AgentRunState>{};
    for (final node in value) {
      if (node is! Map || node['exposed'] == false) continue;
      final rawAddress = node['address'];
      final rawName = node['name'];
      final state = AgentRunState.tryParse('${node['state'] ?? ''}');
      if (rawAddress is String && rawAddress.trim().isNotEmpty) {
        if (state == null) continue;
        final address = rawAddress.trim();
        agents[address.contains('@') ? address : '$address@$deviceId'] = state;
      } else if (rawName is String &&
          rawName.trim().isNotEmpty &&
          state != null) {
        // Legacy `name` is already the roster key (sometimes the bare agent,
        // sometimes a full address); retain it verbatim for DM compatibility.
        agents[rawName.trim()] = state;
      }
    }
    return agents;
  }

  Map<String, ConnectorSessionPresence> _serverSessions(
    Object? value,
    Map<String, ConnectorSessionPresence>? previous,
    NetworkEnvelopeKind kind,
  ) => _projectServerSessions(
    value,
    previous,
    kind,
    (node, _) => ConnectorSessionPresence.tryParse('${node['state'] ?? ''}'),
  );

  Map<String, ConnectorSessionMetadata> _serverSessionMetadata(
    Object? value,
    Map<String, ConnectorSessionMetadata>? previous,
    NetworkEnvelopeKind kind,
  ) => _projectServerSessions(value, previous, kind, (_, metadata) => metadata);

  /// Applies one roster/presence row to either session projection. ROSTER is
  /// a complete snapshot; PRESENCE starts from the persisted rows and merges
  /// live deltas, including explicit removals.
  Map<String, T> _projectServerSessions<T>(
    Object? value,
    Map<String, T>? previous,
    NetworkEnvelopeKind kind,
    T? Function(Map<Object?, Object?> node, ConnectorSessionMetadata? metadata)
    project,
  ) {
    if (value is! List) return previous ?? const {};
    final projected = <String, T>{
      if (kind == NetworkEnvelopeKind.presence) ...?previous,
    };
    for (final node in value) {
      if (node is! Map) continue;
      final id = node['id'];
      if (id is! String || id.isEmpty) continue;
      final metadata = ConnectorSessionMetadata.fromJson(node);
      final action = _serverSessionAction(node, previous, kind, id, metadata);
      if (action == _ServerSessionAction.remove) {
        projected.remove(id);
        continue;
      }
      if (action == _ServerSessionAction.skip) continue;
      final row = project(node, metadata);
      if (row != null) projected[id] = row;
    }
    return projected;
  }

  _ServerSessionAction _serverSessionAction<T>(
    Map<Object?, Object?> node,
    Map<String, T>? previous,
    NetworkEnvelopeKind kind,
    String id,
    ConnectorSessionMetadata? metadata,
  ) {
    if ((metadata?.isSubagent ?? false) || _serverSessionExpired(node)) {
      return _ServerSessionAction.remove;
    }
    final legacyKnownRow = _legacyKnownServerSession(node, previous, kind, id);
    if (_serverSessionVisible(node, kind) || legacyKnownRow) {
      return _ServerSessionAction.retain;
    }
    if (kind == NetworkEnvelopeKind.presence && node['networks'] is List) {
      return _ServerSessionAction.remove;
    }
    return _ServerSessionAction.skip;
  }

  bool _localSessionExpired(ChatListEntry session) {
    if (session.presence == ChatPresence.live ||
        session.presence == ChatPresence.busy ||
        session.isStreaming) {
      return false;
    }
    final activity = session.lastActivity ?? session.createdAt;
    final now = widget.now?.call() ?? DateTime.now();
    return now.toUtc().difference(activity.toUtc()) >
        deviceOfflineSessionRetention;
  }

  bool _serverSessionExpired(Map<Object?, Object?> session) {
    if (ConnectorSessionPresence.tryParse('${session['state'] ?? ''}') !=
        ConnectorSessionPresence.offline) {
      return false;
    }
    final raw = session['lastActivity'] ?? session['lastActiveAt'];
    final lastActivity = raw is String ? DateTime.tryParse(raw) : null;
    if (lastActivity == null) return false;
    final now = widget.now?.call() ?? DateTime.now();
    return now.toUtc().difference(lastActivity.toUtc()) >
        deviceOfflineSessionRetention;
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
    if (!mounted || !_selectedDeviceIsOwn) return;
    setState(() => _selectedDeviceLabel = widget.service.ownFriendlyName);
  }

  String _openDeviceTitle(BuildContext context) {
    if (_selectedDeviceIsOwn) {
      return widget.service.ownFriendlyName ??
          _selectedDeviceLabel ??
          context.l10n.networkDeviceThisDevice;
    }
    // The appbar is now the ONLY device-name surface. Read the current
    // roster row so a friendly-name refresh cannot leave a stale title
    // behind after the redundant in-list header was removed.
    final roster = _remote[_selectedDeviceId]?.roster;
    if (roster != null) {
      return _deviceDisplayLabel(roster.deviceId, roster.displayName);
    }
    if (_selectedDeviceLabel case final label?) return label;
    return shortDeviceId(_selectedDeviceId ?? '');
  }

  Widget? _deviceOptionsMenu(BuildContext context) {
    if (_selectedDeviceId == null || !_selectedDeviceIsOwn) return null;
    return PopupMenuButton<String>(
      key: const ValueKey('deviceOptionsMenu'),
      tooltip: context.l10n.networkDeviceRenameAction,
      iconSize: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      icon: FaIcon(
        FaSemanticIcon.more,
        size: 20,
        color: FahColors.of(context).dim,
      ),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          key: const ValueKey('deviceRenameMenuItem'),
          value: 'rename',
          child: Text(context.l10n.networkDeviceRenameAction),
        ),
      ],
      onSelected: (_) => unawaited(_renameOwnDevice()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final drilledIn = _selectedDeviceId != null;
    final header = MessengerSectionHeader(
      title: drilledIn
          ? _openDeviceTitle(context)
          : context.l10n.networkDevicesTitle,
      compact: widget.compact,
      searchController: null,
      searchCollapsed: true,
      searchHint: context.l10n.launcherSearchHint,
      onProfile: null,
      onNew: null,
      leading: drilledIn
          ? IconButton(
              key: const ValueKey('deviceBackButton'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => setState(() {
                _selectedDeviceId = null;
                _selectedDeviceLabel = null;
                _selectedDeviceIsOwn = false;
                _selectedRemoteSessionId = null;
              }),
              icon: const FaIcon(FaSemanticIcon.back),
              iconSize: 26,
              color: colors.text,
              visualDensity: VisualDensity.compact,
            )
          : null,
      trailing: StreamBuilder<DeviceConnectorPhase>(
        stream: widget.service.phaseStream,
        initialData: widget.service.phase,
        builder: (context, snapshot) {
          final phase = snapshot.data ?? DeviceConnectorPhase.signedOut;
          final connecting =
              phase == DeviceConnectorPhase.preparing ||
              phase == DeviceConnectorPhase.connecting;
          if (!connecting) {
            return _deviceOptionsMenu(context) ?? const SizedBox.shrink();
          }
          return Row(
            key: const ValueKey('devicesConnecting'),
            mainAxisSize: MainAxisSize.min,
            children: [
              FaIcon(FaSemanticIcon.sync, size: 12, color: colors.dim),
              const SizedBox(width: 6),
              Text(
                context.l10n.networkDeviceConnecting,
                style: TextStyle(color: colors.dim, fontSize: 11),
              ),
              const SizedBox(width: 8),
              _deviceOptionsMenu(context) ?? const SizedBox.shrink(),
            ],
          );
        },
      ),
    );
    return StreamBuilder<DeviceConnectorPhase>(
      stream: widget.service.phaseStream,
      initialData: widget.service.phase,
      builder: (context, snapshot) {
        final phase = snapshot.data ?? DeviceConnectorPhase.signedOut;
        return MessengerGlassPanel(
          key: const ValueKey('devicesPage'),
          compact: widget.compact,
          underlayKey: const ValueKey('devicesChromeUnderlay'),
          header: header,
          body: Builder(
            builder: (context) => _connectedBody(context, colors, phase),
          ),
        );
      },
    );
  }

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
      // Connecting lives in the header. Keeping the same list and its single
      // glass inset mounted prevents a second header-height gap and the jump
      // when the phase resolves.
      if (phase == DeviceConnectorPhase.reconnecting ||
          phase == DeviceConnectorPhase.signedOut)
        SizedBox(height: MessengerGlassBodyInsets.topOf(context)),
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

  /// The own frame stream + local chat list rebuild both projections. Every
  /// width follows Networks: labeled root list → mini device strip + sessions.
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
            final drilledIn = _selectedDeviceId != null;
            final items = _avatarItems(context, devices);
            void open(String id) =>
                _selectDevice(devices.firstWhere((device) => device.id == id));
            return MessengerDrilldownBody(
              key: const ValueKey('deviceDrilldownBody'),
              drilledIn: drilledIn,
              strip: MessengerAvatarStrip(
                items: items,
                selectedId: selected.id,
                onOpen: open,
                stripKey: const ValueKey('deviceRail'),
                selectedCapsuleKey: const ValueKey('deviceSelectedCapsule'),
              ),
              contentKey: ValueKey(
                'devicesContent-${drilledIn ? selected.id : 'list'}',
              ),
              content: drilledIn
                  ? Padding(
                      padding: EdgeInsets.only(
                        top: MessengerGlassBodyInsets.topOf(context),
                      ),
                      child: _devicePane(selected),
                    )
                  : MessengerAvatarList(
                      items: items,
                      onOpen: open,
                      listKey: const ValueKey('deviceList'),
                      bottomReserve: widget.compact
                          ? MessengerFloatingDockInsets.bottomOf(context)
                          : 0,
                    ),
            );
          },
        );
      },
    );
    if (controller == null) return body;
    return ListenableBuilder(listenable: controller, builder: (_, _) => body);
  }

  List<MessengerAvatarItem> _avatarItems(
    BuildContext context,
    List<_DeviceEntry> devices,
  ) => [
    for (final device in devices)
      MessengerAvatarItem(
        key: ValueKey(device.isOwn ? 'deviceRow' : 'deviceRow:${device.id}'),
        id: device.id,
        label: device.label,
        subtitle: [
          if (device.isOwn) context.l10n.networkDeviceThisDevice,
          if (!device.isOwn && device.subtitle != null) device.subtitle!,
          deviceMachineLabel(context, device.machine),
        ].join(' · '),
        avatar: (selected) => _DeviceAvatar(
          key: ValueKey(
            device.isOwn ? 'deviceAvatar' : 'deviceAvatar:${device.id}',
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
  ];

  void _selectDevice(_DeviceEntry device) => setState(() {
    _selectedDeviceId = device.id;
    _selectedDeviceLabel = device.label;
    _selectedDeviceIsOwn = device.isOwn;
    _selectedRemoteSessionId = null;
  });

  Widget _devicePane(_DeviceEntry selected) => _DevicePane(
    device: selected,
    now: widget.now ?? DateTime.now,
    onOpenSession: widget.onOpenSession,
    selectedSessionId: widget.selectedSessionId,
    selectedRemoteSessionId: _selectedRemoteSessionId,
    onOpenConversation: (deviceId, agentAddress, sessionId, sessionTitle) {
      setState(() => _selectedRemoteSessionId = sessionId);
      widget.onOpenRemoteConversation?.call(
        deviceId: deviceId,
        deviceLabel: selected.label,
        agentAddress: agentAddress,
        sessionId: sessionId,
        sessionTitle: sessionTitle,
      );
    },
  );

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
    final ownMachineKeys = _enrollmentMachineGroupKeys(ownDevice);
    final visibleLocalSessions = controller == null
        ? const <ChatListEntry>[]
        : deviceVisibleLocalSessions(controller)
              .where((entry) => !_localSessionExpired(entry))
              .toList(growable: false);
    final ownSessionIds = <String>{
      ...?ownFrame?.sessions.keys,
      for (final entry in visibleLocalSessions) entry.id.value,
    };

    final grouping = _RemoteDeviceGrouping.build(
      entries: [
        for (final entry in _remote.entries)
          if (entry.key != widget.service.deviceId &&
              !_hiddenRemoteEnrollment(entry.value))
            entry,
      ],
      ownMachineKeys: ownMachineKeys,
      ownSessionIds: ownSessionIds,
    );
    final ownMerged = grouping.ownMerged;
    final remoteGroups = grouping.remoteGroups;
    final groupDevices = grouping.groupDevices;
    final groupKeys = grouping.groupKeys;

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
        machine: MachinePresence.online,
        agents: _canonicalAgentStates([
          ownFrame?.agents ?? const {},
          for (final node in ownMerged) node.presence?.agents ?? const {},
        ]),
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
                deviceAgentName(name): entry.key,
        },
        localSessions: visibleLocalSessions,
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
    final rawLabel = single
        ? first.roster?.displayName
        : (nodes
                  .map((node) => node.roster?.friendlyName)
                  .whereType<String>()
                  .firstOrNull ??
              first.roster?.name ??
              groupKey);
    final label = _deviceDisplayLabel(deviceIds.first, rawLabel);
    return _DeviceEntry(
      id: single ? deviceIds.first : 'machine:$groupKey',
      label: label,
      subtitle: single
          ? (first.roster?.friendlyName == null ? null : first.roster!.name)
          : first.roster?.name,
      dotColor: deviceMachineDotColor(colors, best),
      machine: best,
      isOffline: best == MachinePresence.offline,
      icon: devicePlatformIcon(
        name: first.roster?.name,
        friendlyName: first.roster?.friendlyName,
      ),
      agents: _canonicalAgentStates([
        for (final node in nodes) node.presence?.agents ?? const {},
      ]),
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
            deviceAgentName(name): deviceIds[i],
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

/// REST can spell one agent as `fa` while presence uses `fa@device`. Merge
/// those aliases by mailbox name so a re-enrollment cannot duplicate rows;
/// an online/busy projection wins over a stale offline alias.
Map<String, AgentRunState> _canonicalAgentStates(
  Iterable<Map<String, AgentRunState>> sources,
) {
  final result = <String, AgentRunState>{};
  for (final source in sources) {
    for (final entry in source.entries) {
      final name = deviceAgentName(entry.key);
      final previous = result[name];
      if (previous == null || previous == AgentRunState.offline) {
        result[name] = entry.value;
      }
    }
  }
  return result;
}

/// Groups remote enrollments into physical-machine cards.
///
/// One PHYSICAL machine = one card. Union enrollments by a meaningful hostname
/// (or owner-friendly identity for legacy `device` rows) AND by shared
/// persisted session ids. The latter recovers duplicate generic enrollments
/// of the same machine without merging unrelated online devices that merely
/// share the placeholder name `device`.
class _RemoteDeviceGrouping {
  _RemoteDeviceGrouping._({
    required this.entries,
    required this.ownMachineKeys,
    required this.ownSessionIds,
  });

  factory _RemoteDeviceGrouping.build({
    required List<MapEntry<String, _RemoteDeviceNode>> entries,
    required Set<String> ownMachineKeys,
    required Set<String> ownSessionIds,
  }) {
    final grouping = _RemoteDeviceGrouping._(
      entries: entries,
      ownMachineKeys: ownMachineKeys,
      ownSessionIds: ownSessionIds,
    );
    grouping
      .._indexEntries()
      .._findOwnRoots()
      .._partitionEntries()
      .._buildRemoteGroups();
    return grouping;
  }

  final List<MapEntry<String, _RemoteDeviceNode>> entries;
  final Set<String> ownMachineKeys;
  final Set<String> ownSessionIds;

  late final _parents = List<int>.generate(entries.length, (index) => index);
  late final _ownMembers = List<bool>.filled(entries.length, false);
  final _identityOwners = <String, int>{};
  final _sessionOwners = <String, int>{};
  final _ownRoots = <int>{};
  final _groupedIndexes = <int, List<int>>{};
  final _order = <int>[];

  final ownMerged = <_RemoteDeviceNode>[];
  final remoteGroups = <String, List<_RemoteDeviceNode>>{};
  final groupDevices = <String, List<String>>{};
  final groupKeys = <String>[];

  void _indexEntries() {
    for (var i = 0; i < entries.length; i++) {
      _indexIdentity(i);
      _indexSessions(i);
    }
  }

  void _indexIdentity(int index) {
    final node = entries[index].value;
    for (final identity in _enrollmentMachineGroupKeys(node.roster)) {
      if (ownMachineKeys.contains(identity)) _ownMembers[index] = true;
      _linkOwner(_identityOwners, identity, index);
    }
  }

  void _indexSessions(int index) {
    final node = entries[index].value;
    for (final id in node.presence?.sessions.keys ?? const <String>{}) {
      if (ownSessionIds.contains(id)) _ownMembers[index] = true;
      _linkOwner(_sessionOwners, id, index);
    }
  }

  void _linkOwner(Map<String, int> owners, String key, int index) {
    final previous = owners[key];
    if (previous == null) {
      owners[key] = index;
      return;
    }
    _union(previous, index);
  }

  int _rootOf(int index) {
    var root = index;
    while (_parents[root] != root) {
      root = _parents[root];
    }
    while (_parents[index] != index) {
      final next = _parents[index];
      _parents[index] = root;
      index = next;
    }
    return root;
  }

  void _union(int left, int right) {
    final leftRoot = _rootOf(left);
    final rightRoot = _rootOf(right);
    if (leftRoot != rightRoot) _parents[rightRoot] = leftRoot;
  }

  void _findOwnRoots() {
    for (var i = 0; i < entries.length; i++) {
      if (_ownMembers[i]) _ownRoots.add(_rootOf(i));
    }
  }

  void _partitionEntries() {
    for (var i = 0; i < entries.length; i++) {
      _partitionEntry(i);
    }
  }

  void _partitionEntry(int index) {
    if (_ownRoots.contains(_rootOf(index))) {
      ownMerged.add(entries[index].value);
      return;
    }
    _addRemoteIndex(index, _rootOf(index));
  }

  void _addRemoteIndex(int index, int root) {
    if (!_groupedIndexes.containsKey(root)) _order.add(root);
    (_groupedIndexes[root] ??= []).add(index);
  }

  void _buildRemoteGroups() {
    for (final root in _order) {
      _buildRemoteGroup(root);
    }
  }

  void _buildRemoteGroup(int root) {
    final indexes = _groupedIndexes[root]!;
    final ids = [for (final index in indexes) entries[index].key];
    final key = _remoteGroupKey(indexes, ids);
    groupKeys.add(key);
    remoteGroups[key] = [for (final index in indexes) entries[index].value];
    groupDevices[key] = ids;
  }

  String _remoteGroupKey(List<int> indexes, List<String> ids) {
    final identity = indexes
        .expand(
          (index) => _enrollmentMachineGroupKeys(entries[index].value.roster),
        )
        .firstOrNull;
    return identity ??
        (ids.length == 1 ? 'device:${ids.first}' : 'shared:${ids.first}');
  }
}

enum _ServerSessionAction { retain, skip, remove }

/// Presence rows without an exposure list are legacy patches: retain a known
/// persisted row even though the patch itself carries no visibility fields.
bool _legacyKnownServerSession<T>(
  Map<Object?, Object?> node,
  Map<String, T>? previous,
  NetworkEnvelopeKind kind,
  String id,
) => _legacyServerSessionPatch(node, kind) && _knownServerSession(previous, id);

bool _legacyServerSessionPatch(
  Map<Object?, Object?> node,
  NetworkEnvelopeKind kind,
) => kind == NetworkEnvelopeKind.presence && node['networks'] is! List;

bool _knownServerSession<T>(Map<String, T>? previous, String id) =>
    previous?.containsKey(id) ?? false;

/// The machine-group key for an enrollment hostname: normalized lowercase,
/// null for generic/empty names. A generic placeholder alone is NOT proof
/// that two machines match; shared sessions or a friendly identity must also
/// link them (see the rail's grouping pass).
String? machineGroupKey(String? name) {
  if (isGenericDeviceName(name)) return null;
  var normalized = name!.trim().toLowerCase();
  // The same Mac can enroll as `mymac`, `mymac.local`, or `My Mac` from
  // different clients. Treat those as host aliases, not new machines.
  normalized = normalized.replaceFirst(RegExp(r'\.(local|lan|home)$'), '');
  normalized = normalized.replaceAll(RegExp(r'[\s_]+'), '-');
  return isGenericDeviceName(normalized) || normalized.isEmpty
      ? null
      : normalized;
}

/// Hostname AND owner-friendly identity are independent aliases. App and CLI
/// enrollments often have different platform names but share `mymac` as the
/// friendly name; indexing only `name ?? friendlyName` leaves duplicate tiles.
Set<String> _enrollmentMachineGroupKeys(DeviceInfo? device) => {
  ?machineGroupKey(device?.name),
  ?machineGroupKey(device?.friendlyName),
};

String _deviceDisplayLabel(String id, String? candidate) {
  final label = candidate?.trim() ?? '';
  return label.isEmpty || label == id ? shortDeviceId(id) : label;
}

/// Repeated integration-test enrollments have no useful identity, presence,
/// or children. Hide those dead account rows instead of letting dozens of
/// `device` phantoms dominate the rail. A live row, a named/friendly row, or
/// any exposed child remains visible; presence-only legacy rows are retained.
bool _hiddenRemoteEnrollment(_RemoteDeviceNode node) {
  final roster = node.roster;
  if (roster == null) return false;
  if (roster.revokedAt != null) return true;
  if (_enrollmentMachineGroupKeys(roster).isNotEmpty) return false;
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
    required this.machine,
    this.isOwn = false,
    this.isOffline = false,
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

  /// Last-known machine presence forces every child row offline, even when
  /// its last session heartbeat was wake-on-DM before an unclean disconnect.
  final bool isOffline;
  final Color dotColor;
  final MachinePresence machine;
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

/// The selected device's pane: agents in the roster-row form and session
/// cards. The glass appbar owns the device identity; it is not repeated here.
/// (local ones tappable through the shell's open flow, remote exposed
/// ones read-only) — or the muted no-sessions hint.
class _DevicePane extends StatelessWidget {
  const _DevicePane({
    required this.device,
    required this.now,
    this.onOpenSession,
    this.selectedSessionId,
    this.selectedRemoteSessionId,
    this.onOpenConversation,
  });

  final _DeviceEntry device;
  final DateTime Function() now;

  /// Opens the DM conversation for (deviceId, full agent address, sessionId?).
  final void Function(
    String deviceId,
    String agentAddress,
    String? sessionId,
    String? sessionTitle,
  )?
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
    // The glass appbar already names the drilled-in device. Repeating that
    // identity here made every pane read "mymac / mymac"; keep the content
    // area exclusively for its agents and sessions.
    return Column(
      key: ValueKey('devicePane:${device.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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

  /// The children: agents first (using the same rich session-row form), then
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
    // Match Networks' channel adapter: every device uses one flat session
    // list. cwd stays visible as row metadata; missing remote cwd can no
    // longer silently disable grouping or change the navigation shape.
    // Hairlines are EXPLICIT positions, never a shared counter (review
    // #2196 round 1): folder sections build their cards in their own
    // setState passes, so a captured `sessionIndex++` drifted on every
    // toggle — dangling separators / vanishing hairlines. Each card now
    // gets `hairline: <more visible rows follow>`.
    Widget remoteCard(
      MapEntry<String, ConnectorSessionPresence> entry, {
      required bool hairline,
    }) {
      final metadata = device.sessionMetadata[entry.key];
      final state = device.isOffline
          ? ConnectorSessionPresence.offline
          : entry.value;
      final cwd = metadata?.path ?? metadata?.cwd ?? '';
      return DeviceSessionCard(
        key: ValueKey('sessionRow:${entry.key}'),
        dotKey: ValueKey('sessionDot:${entry.key}'),
        dotColor: deviceSessionDotColor(colors, state),
        title: _sessionTitle(
          entry.key,
          metadata?.title,
          path: metadata?.path ?? metadata?.cwd,
          preview: metadata?.snippet,
          cliFallback: true,
        ),
        subtitle: cwd,
        timestamp: chatListRelativeTime(
          context,
          metadata?.lastActivity,
          now: now(),
        ),
        stateLabel: deviceSessionLabel(context, state),
        stateColor: deviceSessionDotColor(colors, state),
        showPresenceDot: true,
        hairline: hairline,
        selected: entry.key == selectedRemoteSessionId,
        onTap: _sessionConversation(entry.key),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      children: [
        for (final entry in device.agents.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: _agentSessionCard(context, colors, entry),
          ),
        for (final (index, entry) in device.localSessions.indexed)
          _localSessionCard(
            context,
            colors,
            entry,
            hairline:
                index < device.localSessions.length - 1 || remote.isNotEmpty,
          ),
        for (final (index, entry) in remote.indexed)
          remoteCard(entry, hairline: index < remote.length - 1),
      ],
    );
  }

  /// An exposed agent uses the session registry's friendly name whenever its
  /// mailbox name is also a session id. DM still targets the original agent
  /// address (device-level conversation), so this is presentation-only.
  Widget _agentSessionCard(
    BuildContext context,
    FahColors colors,
    MapEntry<String, AgentRunState> entry,
  ) {
    final name = deviceAgentName(entry.key);
    final metadata = device.sessionMetadata[name];
    ChatListEntry? local;
    for (final candidate in device.localSessions) {
      if (candidate.id.value == name) {
        local = candidate;
        break;
      }
    }
    final path = local?.folderPath ?? metadata?.path ?? metadata?.cwd ?? '';
    final hasSession = local != null || metadata != null;
    final title = hasSession || deviceSessionIdIsUuid(name)
        ? _sessionTitle(
            name,
            local?.title ?? metadata?.title,
            path: path,
            preview: metadata?.snippet,
            cliFallback: true,
          )
        : name;
    return DeviceSessionCard(
      key: ValueKey('agentRow:${entry.key}'),
      dotKey: ValueKey('agentDot:${entry.key}'),
      dotColor: deviceAgentDotColor(colors, entry.value),
      title: title,
      subtitle: path,
      timestamp: chatListRelativeTime(
        context,
        local?.lastActivity ?? metadata?.lastActivity,
        now: now(),
      ),
      stateLabel: deviceAgentLabel(context, entry.value),
      stateColor: deviceAgentDotColor(colors, entry.value),
      showPresenceDot: true,
      onTap: onOpenConversation == null
          ? null
          : () {
              final deviceId = device.agentDeviceIds[entry.key] ?? device.id;
              onOpenConversation!(
                deviceId,
                '${entry.key}@$deviceId',
                null,
                title,
              );
            },
    );
  }

  /// The DM target for an exposed session card: its origin device (the
  /// group-merge map) plus a live agent, or a sleeping agent's roster dmPub.
  /// Null keeps the card read-only only when no DM identity was published.
  VoidCallback? _sessionConversation(String sessionId) {
    final open = onOpenConversation;
    if (open == null) return null;
    final deviceId = device.sessionDeviceIds[sessionId] ?? device.id;
    final metadata = device.sessionMetadata[sessionId];
    final title = _sessionTitle(
      sessionId,
      metadata?.title,
      path: metadata?.path ?? metadata?.cwd,
      preview: metadata?.snippet,
      cliFallback: true,
    );
    for (final name in device.agents.keys) {
      if ((device.agentDeviceIds[name] ?? device.id) == deviceId) {
        return () => open(deviceId, '$name@$deviceId', sessionId, title);
      }
    }
    for (final address in device.agentDmPubs.keys) {
      final separator = address.lastIndexOf('@');
      if (separator > 0 && address.substring(separator + 1) == deviceId) {
        return () => open(deviceId, address, sessionId, title);
      }
    }
    return null;
  }

  /// One Local-format chat row: title + host/project/activity context.
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
      title: _sessionTitle(id, entry.title, path: entry.folderPath),
      subtitle: entry.folderPath ?? '',
      timestamp: chatListRelativeTime(
        context,
        entry.lastActivity ?? entry.createdAt,
        now: now(),
      ),
      hairline: hairline,
      showPresenceDot: active,
      selected: id == selectedSessionId,
      onTap: onOpenSession == null ? null : () => onOpenSession!(entry),
    );
  }
}

String _sessionTitle(
  String id,
  String? rawTitle, {
  String? path,
  String? preview,
  bool cliFallback = false,
}) => deviceSessionDisplayTitle(
  id: id,
  title: rawTitle,
  path: path,
  preview: preview,
  cliFallback: cliFallback,
);

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
