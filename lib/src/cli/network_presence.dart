// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// CLI host for the pure machine connector. One process shares one device
/// socket; the current CLI session is exposed on the personal network and
/// its mailbox prefix becomes the agent name in `<mailbox>@<deviceId>`.
library;

import 'dart:async';

import '../network/connector/device_api.dart';
import '../network/connector/device_dm_keys.dart';
import '../network/connector/device_registry.dart';
import '../network/connector/envelope.dart';
import '../network/connector/machine_connector.dart';
import '../network/connector/offline_outbox.dart';
import '../network/connector/presence_engine.dart';
import '../network/connector/upstream_client.dart';
import '../network/network_account.dart';
import '../network/network_roster.dart';

/// The live session identity projected onto the device network.
final class CliNetworkSession {
  /// Builds a session identity.
  const CliNetworkSession({required this.sessionId, this.mailboxPrefix});

  /// Current persisted session id.
  final String sessionId;

  /// Fabric mailbox prefix. Falls back to [sessionId] when empty.
  final String? mailboxPrefix;

  /// Agent name used in the contract address.
  String get agentName {
    final prefix = mailboxPrefix?.trim();
    return prefix == null || prefix.isEmpty ? sessionId : prefix;
  }
}

/// Host seam consumed by `AgentCli` without coupling the REPL to transport
/// or credential storage. Implementations must be best-effort: a network
/// outage must never prevent a local agent run.
abstract interface class CliNetworkPresence {
  /// Starts (or switches to) the current session's presence rows.
  Future<void> startSession(CliNetworkSession session);

  /// Publishes busy/live for the current agent when the host knows it.
  void setBusy(bool busy);

  /// Stops the upstream connector. Idempotent.
  Future<void> stop();
}

/// The production [CliNetworkPresence], built over [MachineConnector].
final class NetworkPresenceController implements CliNetworkPresence {
  /// Builds a controller. [ticketProvider] must mint a fresh single-use
  /// device ticket for every dial; [transport] is fakeable in unit tests.
  /// Production passes its credential store as [dmKeyStore] so agent DM keys
  /// survive restarts; omitting it gives an ephemeral in-memory key store.
  NetworkPresenceController({
    required this.device,
    required this.baseUrl,
    required this.ticketProvider,
    this.transport,
    this.rosterClient,
    this.rosterDebounce = const Duration(milliseconds: 500),
    this.idFactory = defaultIdFactory,
    this.onLog,
    DeviceDmKeyStore? dmKeyStore,
  }) : _dmKeys = DeviceDmKeyProvider(dmKeyStore ?? MemoryDeviceDmKeyStore());

  /// Enrolled device identity.
  final NetworkDeviceCredentials device;

  /// fa_network REST root (`https://network.fa1.dev` in production).
  final String baseUrl;

  /// Fresh WS-ticket provider.
  final DeviceTicketProvider ticketProvider;

  /// Injectable frame ids for tests.
  final IdFactory idFactory;

  /// IO transport, or a hermetic fake in tests.
  final ConnectorTransport? transport;

  /// REST client for the fa_network roster projection. Nullable so embedders
  /// that only want the legacy socket can retain the original behaviour.
  final DeviceEnrollmentClient? rosterClient;

  /// Coalescing window for REST roster changes.
  final Duration rosterDebounce;

  /// Optional diagnostics. Callers must not pass secret-bearing log lines.
  final void Function(String message)? onLog;

  final DeviceDmKeyProvider _dmKeys;
  final _dmPubs = <String, String>{};
  MachineConnector? _connector;
  DeviceRegistry? _registry;
  CliNetworkSession? _session;
  String? _agentAddress;
  ConnectorLinkState _phase = ConnectorLinkState.disconnected;
  final _phaseChanges = StreamController<ConnectorLinkState>.broadcast();
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _pendingRosterAgents = <String, DeviceRosterAgent>{};
  final _pendingRosterSessions = <String, DeviceRosterSession>{};
  Timer? _rosterTimer;
  Future<void> _rosterWrites = Future<void>.value();
  bool _rosterActive = false;
  bool _busy = false;

  /// Current upstream phase (disconnected before [start]).
  ConnectorLinkState get phase => _phase;

  /// Phase changes for command/debug hosts.
  Stream<ConnectorLinkState> get phaseChanges => _phaseChanges.stream;

  /// Roster frames forwarded by the connector.
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

  /// The composed connector, exposed for hermetic tests and diagnostics.
  MachineConnector? get connector => _connector;

  /// Starts a socket without a local session (used by `network devices`).
  Future<void> start() async {
    _ensureBuilt();
    _rosterActive = _session != null;
    await _connector!.start();
    _queueLiveRoster();
  }

  @override
  Future<void> startSession(CliNetworkSession session) async {
    _ensureBuilt();
    final registry = _registry!;
    final previous = _session;
    final previousAddress = _agentAddress;
    if (previous != null && previousAddress != null) {
      registry.unregisterSession(previous.sessionId);
      registry.unregisterAgent(previous.agentName, device.deviceId);
      _connector!.presence.setAgentState(
        previousAddress,
        AgentRunState.offline,
      );
      _queueRosterRetraction(previous);
    }
    _session = session;
    _busy = false;
    final address = agentAddress(session.agentName, device.deviceId);
    _agentAddress = address;
    final dmKey = await _dmKeys.loadOrCreate(address);
    _dmPubs[address] = dmKey.publicKey;
    registry
      ..registerAgent(
        session.agentName,
        device.deviceId,
        dmPub: dmKey.publicKey,
      )
      ..registerSession(
        SessionRegistration(id: session.sessionId, agentAddressOf: address),
      );
    _connector!.presence.setAgentState(address, AgentRunState.live);
    await start();
  }

  @override
  void setBusy(bool busy) {
    _busy = busy;
    final address = _agentAddress;
    final connector = _connector;
    if (address == null || connector == null) return;
    connector.presence.setAgentState(
      address,
      busy ? AgentRunState.busy : AgentRunState.live,
    );
    _queueLiveRoster();
  }

  @override
  Future<void> stop() async {
    await _retractRoster();
    await _connector?.stop();
    _setPhase(ConnectorLinkState.disconnected);
  }

  /// Stops and closes all long-lived streams. The controller is not
  /// restartable afterwards.
  Future<void> dispose() async {
    await stop();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _connector?.dispose();
    _connector?.upstream.dispose();
    _registry?.dispose();
    _connector?.presence.dispose();
    _connector = null;
    _registry = null;
    await _phaseChanges.close();
    await _rosterFrames.close();
  }

  Future<void> _retractRoster() async {
    if (!_rosterActive) {
      await _flushRoster();
      return;
    }
    _rosterActive = false;
    final session = _session;
    if (session != null) _queueRosterRetraction(session);
    await _flushRoster();
  }

  void _queueLiveRoster() {
    final session = _session;
    if (!_rosterActive ||
        _phase != ConnectorLinkState.connected ||
        session == null) {
      return;
    }
    _queueRosterEntries(
      agents: [
        DeviceRosterAgent(
          name: session.agentName,
          state: _busy ? 'busy' : 'live',
          exposed: true,
          dmPub: _dmPubs[_agentAddress],
        ),
      ],
      sessions: [
        DeviceRosterSession(
          id: session.sessionId,
          state: 'live',
          networks: _sessionNetworks,
        ),
      ],
    );
  }

  void _queueRosterRetraction(CliNetworkSession session) {
    _queueRosterEntries(
      agents: [
        DeviceRosterAgent(
          name: session.agentName,
          state: 'offline',
          exposed: false,
          dmPub: _dmPubs[agentAddress(session.agentName, device.deviceId)],
        ),
      ],
      sessions: [
        DeviceRosterSession(
          id: session.sessionId,
          state: 'offline',
          networks: _sessionNetworks,
        ),
      ],
    );
  }

  List<String> get _sessionNetworks => [?device.personalNetworkId];

  void _queueRosterEntries({
    List<DeviceRosterAgent> agents = const [],
    List<DeviceRosterSession> sessions = const [],
  }) {
    if (rosterClient == null) return;
    for (final agent in agents) {
      _pendingRosterAgents[agent.name] = agent;
    }
    for (final session in sessions) {
      _pendingRosterSessions[session.id] = session;
    }
    _rosterTimer?.cancel();
    _rosterTimer = Timer(rosterDebounce, () => unawaited(_flushRoster()));
  }

  Future<void> _flushRoster() {
    _rosterTimer?.cancel();
    _rosterTimer = null;
    final write = _rosterWrites.then((_) => _writePendingRoster());
    _rosterWrites = write;
    return write;
  }

  Future<void> _writePendingRoster() async {
    final client = rosterClient;
    if (client == null ||
        (_pendingRosterAgents.isEmpty && _pendingRosterSessions.isEmpty)) {
      return;
    }
    final agents = _pendingRosterAgents.values.toList(growable: false);
    final sessions = _pendingRosterSessions.values.toList(growable: false);
    _pendingRosterAgents.clear();
    _pendingRosterSessions.clear();
    try {
      await client.patchRoster(
        baseUrl: baseUrl,
        deviceId: device.deviceId,
        deviceToken: device.deviceToken,
        agents: agents,
        sessions: sessions,
      );
    } on Object {
      // Presence is strictly best-effort and must never break the local CLI.
      onLog?.call('device roster patch failed');
    }
  }

  void _handleUpstreamState(ConnectorLinkState state) {
    _setPhase(state);
    if (state == ConnectorLinkState.connected) _queueLiveRoster();
  }

  void _ensureBuilt() {
    if (_connector != null) return;
    final transport = this.transport;
    if (transport == null) {
      throw StateError(
        'a ConnectorTransport is required (production installs it in bin/)',
      );
    }
    final registry = DeviceRegistry()
      ..configureNetwork(
        device.personalNetworkId ?? 'personal',
        NetworkKind.personal,
      );
    final upstream = ConnectorUpstreamClient(
      url: deviceWebSocketUrl(baseUrl),
      transport: transport,
      ticketProvider: ticketProvider,
      deviceId: device.deviceId,
      deviceToken: device.deviceToken,
      idFactory: idFactory,
      onLog: onLog,
    );
    final connector = MachineConnector(
      registry: registry,
      upstream: upstream,
      outbox: MemoryOutboxStore(),
      leases: () async => {if (_session case final session?) session.sessionId},
      idFactory: idFactory,
      onLog: onLog,
    );
    _registry = registry;
    _connector = connector;
    _subscriptions.add(upstream.stateChanges.listen(_handleUpstreamState));
    _subscriptions.add(connector.rosterFrames.listen(_rosterFrames.add));
  }

  void _setPhase(ConnectorLinkState next) {
    if (_phase == next) return;
    _phase = next;
    if (!_phaseChanges.isClosed) _phaseChanges.add(next);
  }
}

/// Converts the REST root into the verified device-socket URL. Device auth
/// uses the single-use ticket added by [ConnectorUpstreamClient], never a
/// long-lived token in the URL.
Uri deviceWebSocketUrl(String baseUrl) {
  final base = Uri.parse(baseUrl);
  return base.replace(
    scheme: base.scheme == 'http' ? 'ws' : 'wss',
    path: '/ws',
    queryParameters: const {},
  );
}

/// Connects [controller], collects the initial roster burst, and parses its
/// device rows. Always stops/disposes the temporary debug connection.
Future<List<NetworkDeviceRow>> readNetworkDeviceRoster(
  NetworkPresenceController controller, {
  Duration timeout = const Duration(seconds: 8),
  Duration settleTime = const Duration(milliseconds: 60),
}) async {
  final frames = <NetworkEnvelope>[];
  final firstRoster = Completer<void>();
  final subscription = controller.rosterFrames.listen((frame) {
    frames.add(frame);
    if (!firstRoster.isCompleted) firstRoster.complete();
  });
  try {
    await controller.start();
    await firstRoster.future.timeout(timeout);
    if (settleTime > Duration.zero) await Future<void>.delayed(settleTime);
    return parseNetworkDeviceRoster(frames);
  } finally {
    await subscription.cancel();
    await controller.dispose();
  }
}
