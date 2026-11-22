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
import '../session/session_catalog.dart';

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

/// Sender-driven launch of the existing detached headless inbox wake.
/// A null return means launched; an error string means the cwd/process guard
/// refused it. The original network DM remains unacked in both cases.
typedef CliNetworkSessionWakeLauncher =
    Future<String?> Function({
      required String cwd,
      required String sessionId,
      String? sessionName,
    });

/// Optional wake capability without breaking simple [CliNetworkPresence]
/// fakes. The interactive CLI installs its gh-1744-guarded launcher here.
abstract interface class CliNetworkSessionWakeTarget {
  set wakeLauncher(CliNetworkSessionWakeLauncher? launcher);
}

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
    this.displayName,
    this.cwd,
  });

  /// Current persisted session id.
  final String sessionId;

  /// Fabric mailbox prefix. Falls back to [sessionId] when empty.
  final String? mailboxPrefix;

  /// Current mailbox write; null means no session is listening.
  final CliNetworkDmSink? dmSink;

  /// Visible rejection/diagnostic callback.
  final CliNetworkNotice? onNotice;

  /// Friendly session title (custom `--session` name or the derived one).
  /// Published as presence metadata even when the persisted catalog has no
  /// row for this session yet — otherwise the app falls back to the raw
  /// UUID row title (owner: named session showed `CLI · <uuid>`).
  final String? displayName;

  /// Live working directory for the presence metadata path/subtitle.
  final String? cwd;

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
    implements
        CliNetworkPresence,
        CliNetworkDmReplySender,
        CliNetworkSessionWakeTarget {
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
    this.catalogStore,
    this.catalogPollInterval = const Duration(seconds: 10),
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

  /// Coalescing window for REST roster and catalog changes.
  final Duration rosterDebounce;

  /// Complete persisted-session store. Null preserves the legacy live-only
  /// projection for embedders that have no local session store.
  final SessionCatalogStore? catalogStore;

  /// Best-effort filesystem rediscovery interval; zero disables polling
  /// (explicit [notifySessionCatalogChanged] remains available).
  final Duration catalogPollInterval;

  /// Installed by the interactive desktop CLI; null keeps queue-only DMs.
  @override
  CliNetworkSessionWakeLauncher? wakeLauncher;

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
  Timer? _catalogTimer;
  Timer? _catalogPollTimer;
  List<SessionCatalogEntry> _catalogEntries = const [];
  var _catalogRevision = 0;
  final _wakingSessions = <String>{};
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
    _queueLiveRoster(fullSnapshot: true);
    final interval = catalogPollInterval;
    if (catalogStore != null && interval > Duration.zero) {
      _catalogPollTimer?.cancel();
      _catalogPollTimer = Timer.periodic(
        interval,
        (_) => notifySessionCatalogChanged(),
      );
    }
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
    await refreshSessionCatalog(fullSnapshot: true);
    await start();
  }

  /// Schedules one debounced incremental catalog refresh. Repeated session
  /// writes/notifications in the window coalesce into a single store read and
  /// minimal roster PATCH; the next WS connect always sends a full snapshot.
  void notifySessionCatalogChanged() {
    if (catalogStore == null) return;
    _catalogTimer?.cancel();
    _catalogTimer = Timer(
      rosterDebounce,
      () => unawaited(refreshSessionCatalog()),
    );
  }

  /// Reloads the complete store and publishes either a full connect snapshot
  /// or a minimal delta. Store/probe failures leave the last good catalog in
  /// place and never interrupt the local CLI.
  Future<void> refreshSessionCatalog({bool fullSnapshot = false}) async {
    final store = catalogStore;
    if (store == null) return;
    final revision = ++_catalogRevision;
    final List<SessionCatalogEntry> loaded;
    try {
      loaded = await store.loadSessions(
        liveSessionIds: {if (_session case final session?) session.sessionId},
      );
    } on Object {
      onLog?.call('session catalog refresh failed');
      return;
    }
    if (revision != _catalogRevision) return;
    final projection = projectSessionCatalog(
      previous: _catalogEntries,
      current: loaded,
      fullSnapshot: fullSnapshot,
    );
    _catalogEntries = projection.entries;
    if (fullSnapshot) {
      _queueLiveRoster(fullSnapshot: true);
      // Full roster PATCHes are additive on fa_network. Explicitly retract
      // child rows left by pre-filter clients instead of merely omitting them.
      if (projection.retractedIds.isNotEmpty) {
        _queueRosterEntries(
          sessions: [
            for (final id in projection.retractedIds)
              DeviceRosterSession(id: id, state: 'offline', networks: const []),
          ],
        );
      }
    } else {
      _queueRosterEntries(
        sessions: [
          for (final row in projection.upserts) _catalogRosterRow(row),
          for (final id in projection.retractedIds)
            DeviceRosterSession(id: id, state: 'offline', networks: const []),
        ],
      );
    }
    _connector?.presence.publishNow();
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
    if (!busy) notifySessionCatalogChanged();
  }

  @override
  Future<String> sendNetworkDmReply({
    required String address,
    required String text,
  }) async {
    final route = DeviceDmReplyRoute.parse(address);
    final connector = _connector;
    if (connector == null || _agentAddress == null) {
      throw StateError(
        'network DM replies are unavailable before a CLI session starts',
      );
    }
    _validateDmReplyRoute(route);
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

  /// Authorizes one parsed reply route against THIS session: the original
  /// agent alias OR the authenticated sessionId, on our own network.
  /// Split from [sendNetworkDmReply] so each guard stays unit-testable
  /// (CRAP ratchet).
  void _validateDmReplyRoute(DeviceDmReplyRoute route) {
    final currentAddress = _agentAddress!;
    final parts = parseDeviceDmChannelId(route.channel);
    // A woken session answers through the ORIGINAL agent alias (its own
    // mailbox prefix differs from the previously exposed agent): the
    // authenticated sessionId match authorizes that route just like the
    // alias match does — otherwise the accepted receipt/answer is refused
    // and the sender's bubble stays queued forever (owner incident).
    final aliasMatch =
        route.agentAddress == currentAddress &&
        parts != null &&
        agentAddress(parts.agentName, parts.deviceId) == currentAddress;
    final sessionMatch =
        route.sessionId != null && route.sessionId == _session?.sessionId;
    if (parts == null ||
        (!aliasMatch && !sessionMatch) ||
        route.network != (device.personalNetworkId ?? 'personal')) {
      throw StateError(
        'network DM reply route does not belong to the current CLI session; '
        'use the address from a DM received by this session',
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
    _catalogRevision++;
    _catalogTimer?.cancel();
    _catalogPollTimer?.cancel();
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
    if (session != null) {
      if (catalogStore == null) {
        _queueRosterRetraction(session);
      } else {
        _queueRosterEntries(
          agents: [
            DeviceRosterAgent(
              name: session.agentName,
              state: 'offline',
              exposed: false,
              dmPub: _dmPubs[_agentAddress],
            ),
          ],
          sessions: [
            for (final row in normalizeSessionCatalog(_catalogEntries))
              _catalogRosterRow(row, state: 'offline'),
          ],
        );
      }
    }
    await _flushRoster();
  }

  /// The live session's roster row, carrying its friendly title/cwd even
  /// when the catalog has no entry yet (owner: `CLI · <uuid>` fallback).
  DeviceRosterSession _liveRosterRow() {
    final session = _session!;
    return DeviceRosterSession(
      id: session.sessionId,
      state: 'live',
      networks: _sessionNetworks,
      title: session.displayName,
      path: session.cwd,
    );
  }

  void _queueLiveRoster({bool fullSnapshot = false}) {
    final session = _session;
    if (!_rosterActive ||
        _phase != ConnectorLinkState.connected ||
        session == null) {
      return;
    }
    final catalog = normalizeSessionCatalog(_catalogEntries);
    final current = catalog
        .where((row) => row.id == session.sessionId)
        .firstOrNull;
    _queueRosterEntries(
      agents: [
        DeviceRosterAgent(
          name: session.agentName,
          state: _busy ? 'busy' : 'live',
          exposed: true,
          dmPub: _dmPubs[_agentAddress],
        ),
      ],
      sessions: catalogStore == null
          ? [_liveRosterRow()]
          : fullSnapshot
          ? [
              for (final row in catalog) _catalogRosterRow(row),
              if (current == null) _liveRosterRow(),
            ]
          : [
              if (current != null)
                _catalogRosterRow(current)
              else
                _liveRosterRow(),
            ],
    );
  }

  DeviceRosterSession _catalogRosterRow(
    SessionCatalogEntry row, {
    String? state,
    bool expose = true,
  }) {
    final normalized = normalizeSessionCatalog([row]).single;
    final metadata = normalized.toRosterMetadata();
    return DeviceRosterSession(
      id: normalized.id,
      state:
          state ??
          (normalized.id == _session?.sessionId ? 'live' : 'wake_on_dm'),
      networks: expose ? _sessionNetworks : const [],
      // fa_network already persists title/path/lastActivity. Fold the cwd
      // fallback into title so current servers render the project name;
      // additive snippet/cwd keys preserve the structured form for peers.
      title: normalized.displayName,
      snippet: metadata['snippet'] as String?,
      path: metadata['path'] as String?,
      cwd: metadata['cwd'] as String?,
      lastActivity: metadata['lastActivity'] as String?,
    );
  }

  void _queueRosterRetraction(CliNetworkSession session) {
    final catalogRow = normalizeSessionCatalog(
      _catalogEntries,
    ).where((row) => row.id == session.sessionId).firstOrNull;
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
        if (catalogStore != null && catalogRow != null)
          _catalogRosterRow(catalogRow, state: 'wake_on_dm')
        else
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
      if (sessions.isEmpty) {
        await client.patchRoster(
          baseUrl: baseUrl,
          deviceId: device.deviceId,
          deviceToken: device.deviceToken,
          agents: agents,
          sessions: const [],
        );
        return;
      }
      for (
        var start = 0;
        start < sessions.length;
        start += sessionCatalogRosterPageSize
      ) {
        final end = (start + sessionCatalogRosterPageSize).clamp(
          0,
          sessions.length,
        );
        await client.patchRoster(
          baseUrl: baseUrl,
          deviceId: device.deviceId,
          deviceToken: device.deviceToken,
          agents: start == 0 ? agents : const [],
          sessions: sessions.sublist(start, end),
        );
      }
    } on Object {
      // Presence is strictly best-effort and must never break the local CLI.
      onLog?.call('device roster patch failed');
    }
  }

  void _handleUpstreamState(ConnectorLinkState state) {
    _setPhase(state);
    if (state == ConnectorLinkState.connected) {
      _queueLiveRoster(fullSnapshot: true);
    }
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
    // Presence metadata is published even WITHOUT a catalog store: the
    // live overlay below is the only title source for unlisted sessions.
    connector.presence.sessionMetadata = _presenceSessionMetadata;
    if (catalogStore != null) {
      // REST patches and heartbeat presence share the SAME complete catalog;
      // a heartbeat can therefore never clobber sleepers back to live-only.
      connector.presence.exposedSessions = () => <String>{
        for (final row in _catalogEntries) row.id,
        if (_session case final session?) session.sessionId,
      };
      connector.presence.liveLeases = () => <String>{
        if (_session case final session?) session.sessionId,
      };
    }
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
    // The empty DecodedMail carries the own-echo SHAPE flag so the
    // connector belt can split true echoes (frame id we minted → quiet
    // ack/drop) from rewritten-sender frames (foreign id → loud 'non-echo
    // frame with rewritten sender' warning, still acked — incident
    // 8ff48b96 was a user DM lost through exactly this shape).
    if (envelope.from == addressedAgent && envelope.to != addressedAgent) {
      return const DecodedMail(payload: '', ownEcho: true);
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
    final sink = _session?.dmSink;
    if (!_isCurrentDmSession(mail, envelope)) {
      if (await _wakeCatalogSession(mail, route)) {
        throw StateError('network DM wake requested; original left unacked');
      }
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

    await sink!(
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

  /// Catalog metadata plus the LIVE overlay for the current session: a
  /// new/unlisted named session still publishes its friendly title and cwd
  /// instead of degrading to the app's raw-UUID row (owner issue B).
  Map<String, ConnectorSessionMetadata> _presenceSessionMetadata() {
    final catalog = normalizeSessionCatalog(_catalogEntries);
    final session = _session;
    final current = session == null
        ? null
        : catalog.where((row) => row.id == session.sessionId).firstOrNull;
    return <String, ConnectorSessionMetadata>{
      for (final row in catalog)
        row.id: ConnectorSessionMetadata(
          title: row.displayName,
          snippet: row.snippet,
          path: row.cwd,
          cwd: row.cwdSlug,
          lastActivity: row.lastActiveAt,
        ),
      if (session != null)
        session.sessionId: ConnectorSessionMetadata(
          title: (session.displayName?.isNotEmpty ?? false)
              ? session.displayName
              : current?.displayName,
          snippet: current?.snippet,
          path: session.cwd ?? current?.cwd,
          cwd: current?.cwdSlug,
          lastActivity: current?.lastActiveAt,
        ),
    };
  }

  bool _isCurrentDmSession(InboundMail mail, NetworkEnvelope envelope) {
    final session = _session;
    // An explicitly authenticated matching sessionId is sufficient even
    // when the original was addressed to an EARLIER agent alias: a woken
    // session publishes its own prefix (S@device), while the redelivered
    // original still targets the previously exposed agent (A@device).
    // Requiring to==_agentAddress in that case made the woken CLI emit
    // another QUEUED forever and never deliver/ACCEPT (owner: bubble stuck
    // on the clock while the agent was visibly working).
    return session != null &&
        session.dmSink != null &&
        (mail.sessionId == session.sessionId ||
            (mail.sessionId == null && envelope.to == _agentAddress));
  }

  Future<bool> _wakeCatalogSession(
    InboundMail mail,
    DeviceDmReplyRoute route,
  ) async {
    final targetId = mail.sessionId;
    final launcher = wakeLauncher;
    if (targetId == null ||
        targetId == _session?.sessionId ||
        launcher == null) {
      return false;
    }
    final target = normalizeSessionCatalog(
      _catalogEntries,
    ).where((row) => row.id == targetId).firstOrNull;
    if (target == null) return false;
    String? error;
    if (_wakingSessions.add(targetId)) {
      try {
        // The production launcher is AgentCli._launchMailboxWake, which
        // delegates to launchMailboxWake: exact catalog cwd + gh-1744 guard +
        // mailboxWakeCommand targeting the stable session id. A friendly
        // name is not unique and would strand a headless wake on the CLI's
        // interactive same-name picker (or resume the wrong session).
        error = await launcher(cwd: target.cwd, sessionId: target.id);
      } on Object {
        error = 'wake launcher failed';
      } finally {
        _wakingSessions.remove(targetId);
      }
    }
    if (error != null) {
      _session?.onNotice?.call(
        'network DM wake failed for ${target.displayName}: $error',
      );
    }
    await sendDeviceDmReply(
      connector: _connector!,
      keys: _dmKeys,
      route: route,
      reply: deviceDmQueuedReceipt,
    );
    // gh-1180: queued/wake-start is NOT accepted. Only the woken target's
    // completed mailbox write produces the accepted receipt and fabric ack.
    return true;
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
      final rosterLabel = _rosterSenderLabel(sender, deviceId, agent);
      if (rosterLabel != null) return rosterLabel;
      return '$deviceId · $agent';
    }
    final userId = sender.startsWith('user:')
        ? sender.substring('user:'.length)
        : sender;
    return 'network user $userId';
  }

  String? _rosterSenderLabel(String sender, String deviceId, String agent) {
    for (final row in parseNetworkDeviceRoster(_recentRosterFrames)) {
      if (_rosterRowMatchesSender(row, deviceId, sender)) {
        return '${row.name} · $agent';
      }
    }
    return null;
  }

  static bool _rosterRowMatchesSender(
    NetworkDeviceRow row,
    String deviceId,
    String sender,
  ) => row.deviceId == deviceId && row.agentAddresses.contains(sender);

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
