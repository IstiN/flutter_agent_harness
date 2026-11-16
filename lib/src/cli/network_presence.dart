// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// CLI host for the pure machine connector. One process shares one device
/// socket; the current CLI session is exposed on the personal network and
/// its mailbox prefix becomes the agent name in `<mailbox>@<deviceId>`.
library;

import 'dart:async';
import 'dart:convert';

import '../network/connector/connector_mux.dart';
import '../network/connector/device_api.dart';
import '../network/connector/device_dm.dart';
import '../network/connector/device_dm_keys.dart';
import '../network/connector/device_registry.dart';
import '../network/connector/envelope.dart';
import '../network/connector/machine_connector.dart';
import '../network/connector/offline_outbox.dart';
import '../network/connector/presence_engine.dart';
import '../network/connector/upstream_client.dart';
import '../network/network_account.dart';
import '../network/network_roster.dart';

/// One authenticated network DM ready for the current CLI mailbox.
final class CliNetworkDm {
  const CliNetworkDm({
    required this.mail,
    required this.senderLabel,
    required this.replyAddress,
  });

  /// ACL-sanitized text and authenticated fanet1 metadata.
  final InboundMail mail;

  /// Human sender projection from recent roster frames (or an honest fallback).
  final String senderLabel;

  /// Durable opaque route for the existing `agent_message` reply tool.
  final String replyAddress;
}

/// Deterministic, filename-safe mailbox id ordered by server sequence.
///
/// The timestamp fallback retains wire order for servers that omit `seq`.
/// Encoding the raw msgId as base64url keeps arbitrary UUID/legacy ids out of
/// path syntax while retaining collision-free crash/redelivery idempotency.
String networkDmMailboxMessageId(NetworkEnvelope envelope) {
  final parsedTs = DateTime.tryParse(envelope.ts)?.toUtc();
  final sequence = envelope.seq;
  final order = sequence ?? parsedTs?.microsecondsSinceEpoch ?? 0;
  final prefix = sequence == null ? 't' : 's';
  final encodedId = base64UrlEncode(
    utf8.encode(envelope.msgId),
  ).replaceAll('=', '');
  return 'network-dm_$prefix${order.toString().padLeft(20, '0')}_$encodedId';
}

/// Ack-owning current-session delivery callback. A throw leaves the original
/// network mail unacked and suppresses its accepted receipt.
typedef CliNetworkDmSink = Future<void> Function(CliNetworkDm dm);

/// Safe, credential-free diagnostic notice (decode rejection/receipt failure).
typedef CliNetworkNotice = void Function(String message);

/// The live session identity projected onto the device network.
final class CliNetworkSession {
  /// Builds a session identity with optional inbound DM delivery callbacks.
  const CliNetworkSession({
    required this.sessionId,
    this.mailboxPrefix,
    this.dmSink,
    this.onNotice,
  });

  /// Current persisted session id.
  final String sessionId;

  /// Fabric mailbox prefix. Falls back to [sessionId] when empty.
  final String? mailboxPrefix;

  /// Current mailbox write; null means no session is listening.
  final CliNetworkDmSink? dmSink;

  /// Visible rejection/diagnostic callback.
  final CliNetworkNotice? onNotice;

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

/// Optional reply capability implemented by the production controller.
/// Kept separate so existing [CliNetworkPresence] fakes remain source-compatible.
abstract interface class CliNetworkDmReplySender {
  /// Sends [text] to the durable opaque [address] from an inbound DM.
  Future<String> sendNetworkDmReply({
    required String address,
    required String text,
  });
}

/// The production [CliNetworkPresence], built over [MachineConnector].
final class NetworkPresenceController
    implements CliNetworkPresence, CliNetworkDmReplySender {
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
  DeviceDmCodec? _dmCodec;
  SinkRegistration? _dmSinkRegistration;
  CliNetworkSession? _session;
  String? _agentAddress;
  ConnectorLinkState _phase = ConnectorLinkState.disconnected;
  final _phaseChanges = StreamController<ConnectorLinkState>.broadcast();
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  final _recentRosterFrames = <NetworkEnvelope>[];
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
  Future<String> sendNetworkDmReply({
    required String address,
    required String text,
  }) async {
    final route = DeviceDmReplyRoute.parse(address);
    final connector = _connector;
    final currentAddress = _agentAddress;
    if (connector == null || currentAddress == null) {
      throw StateError(
        'network DM replies are unavailable before a CLI session starts',
      );
    }
    final parts = parseDeviceDmChannelId(route.channel);
    if (route.agentAddress != currentAddress ||
        parts == null ||
        agentAddress(parts.agentName, parts.deviceId) != currentAddress ||
        route.network != (device.personalNetworkId ?? 'personal')) {
      throw StateError(
        'network DM reply route does not belong to the current CLI session; '
        'use the address from a DM received by this session',
      );
    }
    if (text.trim().isEmpty) {
      throw StateError('network DM reply text must not be empty');
    }
    try {
      return await sendDeviceDmReply(
        connector: connector,
        keys: _dmKeys,
        route: route,
        reply: text,
      );
    } on Object {
      // Host/key-store failures can contain implementation details. The tool
      // gets an actionable safe error instead of credentials or dial URLs.
      throw StateError(
        'network DM reply could not be queued; check the connection and retry',
      );
    }
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
    _dmSinkRegistration?.close();
    _dmSinkRegistration = null;
    _connector?.dispose();
    _connector?.upstream.dispose();
    _registry?.dispose();
    _connector?.presence.dispose();
    _connector = null;
    _registry = null;
    _dmCodec = null;
    _recentRosterFrames.clear();
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
    final dmCodec = DeviceDmCodec(keys: _dmKeys, deviceId: device.deviceId);
    final connector = MachineConnector(
      registry: registry,
      upstream: upstream,
      outbox: MemoryOutboxStore(),
      leases: () async => {if (_session case final session?) session.sessionId},
      decodeMail: _decodeDmMail,
      idFactory: idFactory,
      onLog: onLog,
    );
    _registry = registry;
    _connector = connector;
    _dmCodec = dmCodec;
    _dmSinkRegistration = connector.registerLocalSink(
      network: device.personalNetworkId ?? 'personal',
      channel: dmChannelPrefix,
      sink: _onDmSink,
    );
    _subscriptions.add(upstream.stateChanges.listen(_handleUpstreamState));
    _subscriptions.add(connector.rosterFrames.listen(_handleRosterFrame));
    _subscriptions.add(connector.rejections.listen(_onDmRejection));
  }

  Future<DecodedMail> _decodeDmMail(NetworkEnvelope envelope) async {
    final parts = parseDeviceDmChannelId(envelope.channel ?? '');
    if (parts == null || parts.deviceId != device.deviceId) {
      throw StateError('non-local DM route left unacked');
    }
    final addressedAgent = agentAddress(parts.agentName, parts.deviceId);
    // Own reply echoes are non-actionable and safe to ack/drop. Everything
    // else must target the agent encoded by its authenticated DM channel.
    if (envelope.from == addressedAgent && envelope.to != addressedAgent) {
      return const DecodedMail(payload: '');
    }
    if (envelope.to != addressedAgent) {
      throw StateError('DM channel/recipient mismatch left unacked');
    }
    return _dmCodec!.decode(envelope);
  }

  Future<void> _onDmSink(InboundMail mail) async {
    final connector = _connector;
    final envelope = mail.envelope;
    final parts = parseDeviceDmChannelId(envelope.channel ?? '');
    final addressedAgent = parts == null
        ? null
        : agentAddress(parts.agentName, parts.deviceId);
    if (connector == null ||
        parts == null ||
        parts.deviceId != device.deviceId ||
        envelope.to != addressedAgent) {
      throw StateError('non-local DM write refused; original left unacked');
    }
    final route = DeviceDmReplyRoute.fromMail(
      mail,
      currentAgentAddress: addressedAgent!,
    );
    final session = _session;
    final sink = session?.dmSink;
    final isCurrent =
        session != null &&
        sink != null &&
        envelope.to == _agentAddress &&
        (mail.sessionId == null || mail.sessionId == session.sessionId);
    if (!isCurrent) {
      await sendDeviceDmReply(
        connector: connector,
        keys: _dmKeys,
        route: route,
        reply: deviceDmQueuedReceipt,
      );
      // The receipt is honest about queueing; the ORIGINAL remains unacked so
      // a later live session/restart can receive it. Mux dedup prevents a
      // same-process reconnect from spamming repeated queued notices.
      throw StateError('network DM queued / not listening; left unacked');
    }

    await sink(
      CliNetworkDm(
        mail: mail,
        senderLabel: _senderLabel(envelope.from ?? ''),
        replyAddress: route.toAddress(),
      ),
    );
    // Distinct accepted-unread receipt: it is sent only after the mailbox
    // Future completed, and the connector acks only after this method returns.
    await sendDeviceDmReply(
      connector: connector,
      keys: _dmKeys,
      route: route,
      reply: deviceDmAcceptedReceipt,
    );
  }

  void _handleRosterFrame(NetworkEnvelope frame) {
    _recentRosterFrames.add(frame);
    if (_recentRosterFrames.length > 64) _recentRosterFrames.removeAt(0);
    if (!_rosterFrames.isClosed) _rosterFrames.add(frame);
  }

  void _onDmRejection(RejectedMail rejection) {
    try {
      _session?.onNotice?.call(
        'network DM ${rejection.envelope.msgId} rejected: ${rejection.reason}',
      );
    } on Object {
      // Diagnostics are best-effort and never change ack/delivery semantics.
    }
  }

  String _senderLabel(String sender) {
    final at = sender.lastIndexOf('@');
    if (at > 0 && at + 1 < sender.length) {
      final agent = sender.substring(0, at);
      final deviceId = sender.substring(at + 1);
      for (final row in parseNetworkDeviceRoster(_recentRosterFrames)) {
        if (row.deviceId == deviceId && row.agentAddresses.contains(sender)) {
          return '${row.name} · $agent';
        }
      }
      return '$deviceId · $agent';
    }
    final userId = sender.startsWith('user:')
        ? sender.substring('user:'.length)
        : sender;
    return 'network user $userId';
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
