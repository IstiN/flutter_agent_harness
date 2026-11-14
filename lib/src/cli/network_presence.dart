// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// CLI host for the pure machine connector. One process shares one device
/// socket; the current CLI session is exposed on the personal network and
/// its mailbox prefix becomes the agent name in `<mailbox>@<deviceId>`.
library;

import 'dart:async';

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
  NetworkPresenceController({
    required this.device,
    required this.baseUrl,
    required this.ticketProvider,
    this.transport,
    this.idFactory = defaultIdFactory,
    this.onLog,
  });

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

  /// Optional diagnostics. Callers must not pass secret-bearing log lines.
  final void Function(String message)? onLog;

  MachineConnector? _connector;
  DeviceRegistry? _registry;
  CliNetworkSession? _session;
  String? _agentAddress;
  ConnectorLinkState _phase = ConnectorLinkState.disconnected;
  final _phaseChanges = StreamController<ConnectorLinkState>.broadcast();
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];

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
    await _connector!.start();
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
    }
    _session = session;
    final address = agentAddress(session.agentName, device.deviceId);
    _agentAddress = address;
    registry
      ..registerAgent(session.agentName, device.deviceId)
      ..registerSession(
        SessionRegistration(id: session.sessionId, agentAddressOf: address),
      );
    final connector = _connector!;
    connector.presence.setAgentState(address, AgentRunState.live);
    await connector.start();
  }

  @override
  void setBusy(bool busy) {
    final address = _agentAddress;
    final connector = _connector;
    if (address == null || connector == null) return;
    connector.presence.setAgentState(
      address,
      busy ? AgentRunState.busy : AgentRunState.live,
    );
  }

  @override
  Future<void> stop() async {
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
    _subscriptions.add(
      upstream.stateChanges.listen((state) => _setPhase(state)),
    );
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
