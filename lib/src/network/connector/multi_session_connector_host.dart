// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pure-Dart multi-session host over ONE [MachineConnector] (contract
/// `docs/fa_network_connector.md` §3 / §10).
///
/// One [MultiSessionConnectorHost] runs inside the per-machine connector daemon
/// and multiplexes every local CLI session and desktop app process over a
/// SINGLE upstream WebSocket to `fa_network` — eliminating the per-process
/// `DeviceRegistry.Add` eviction churn that caused `presence=degraded` and
/// dropped DM replies/receipts when multiple `fa` sessions ran concurrently.
///
/// Roster PATCHes go through the shared [RosterPatchLimiter] (coalescing +
/// ≤ 1 PATCH per 2 s per device process + 429 handling), exactly like the
/// single-session CLI host — never through a bare debounce timer.
library;

import 'dart:async';

import '../../cli/network_presence.dart';
import '../../session/session_catalog.dart';
import '../network_account.dart';
import '../network_roster.dart';
import 'catalog_poller.dart';
import 'connector_mux.dart';
import 'device_api.dart';
import 'device_dm.dart';
import 'device_dm_keys.dart';
import 'device_registry.dart';
import 'envelope.dart';
import 'machine_connector.dart';
import 'offline_outbox.dart';
import 'presence_engine.dart';
import 'roster_patch_limiter.dart';
import 'upstream_client.dart';

/// One live local session registered with [MultiSessionConnectorHost].
final class HostedSessionEntry {
  HostedSessionEntry({
    required this.session,
    required this.agentAddress,
    this.busy = false,
  });

  final CliNetworkSession session;
  final String agentAddress;
  bool busy;
}

/// Multiplexes N concurrent local [CliNetworkSession]s onto ONE upstream
/// [MachineConnector] for the enrolled machine.
final class MultiSessionConnectorHost {
  MultiSessionConnectorHost({
    required this.device,
    required this.baseUrl,
    required this.ticketProvider,
    this.transport,
    this.rosterClient,
    this.rosterDebounce = rosterPatchDebounce,
    this.rosterMinInterval = rosterPatchMinInterval,
    this.catalogStore,
    this.catalogPollInterval = const Duration(seconds: 30),
    this.catalogPollTimerFactory,
    this.idFactory = defaultIdFactory,
    this.wakeLauncher,
    this.onLog,
    DeviceDmKeyStore? dmKeyStore,
    this.outbox,
  }) : _dmKeys = DeviceDmKeyProvider(dmKeyStore ?? MemoryDeviceDmKeyStore()),
       _roster = RosterPatchLimiter(
         baseUrl: baseUrl,
         deviceId: device.deviceId,
         deviceToken: device.deviceToken,
         client: rosterClient,
         debounce: rosterDebounce,
         minInterval: rosterMinInterval,
         onLog: onLog,
       );

  final NetworkDeviceCredentials device;
  final String baseUrl;
  final DeviceTicketProvider ticketProvider;
  final ConnectorTransport? transport;
  final DeviceEnrollmentClient? rosterClient;
  final Duration rosterDebounce;

  /// Minimum spacing of two roster PATCHes (the per-device budget).
  final Duration rosterMinInterval;
  final SessionCatalogStore? catalogStore;

  /// Best-effort filesystem rediscovery interval (default 30 s; was 10 s
  /// before gh-2410 — passes are single-flight and skipped while the link
  /// is down, see [CatalogPoller]). Zero disables periodic polling.
  final Duration catalogPollInterval;

  /// Timer seam of the periodic catalog poll (tests fire ticks by hand).
  final PeriodicTimerFactory? catalogPollTimerFactory;
  final IdFactory idFactory;
  CliNetworkSessionWakeLauncher? wakeLauncher;
  final void Function(String line)? onLog;
  final DeviceDmKeyProvider _dmKeys;
  final OutboxStore? outbox;

  MachineConnector? _connector;
  DeviceRegistry? _registry;
  DeviceDmCodec? _dmCodec;
  SinkRegistration? _dmSinkRegistration;
  ConnectorLinkState _phase = ConnectorLinkState.disconnected;
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  final _presenceFrames = StreamController<NetworkEnvelope>.broadcast();
  final _recentRosterFrames = <NetworkEnvelope>[];
  final _subscriptions = <StreamSubscription<Object?>>[];

  final _sessions = <String, HostedSessionEntry>{};
  final _dmPubs = <String, String>{};
  final RosterPatchLimiter _roster;
  Timer? _catalogTimer;
  CatalogPoller? _catalogPoller;
  List<SessionCatalogEntry> _catalogEntries = const [];
  var _catalogRevision = 0;
  final _wakingSessions = <String>{};
  bool _started = false;

  /// Current upstream link phase.
  ConnectorLinkState get phase => _phase;

  /// Most recent roster snapshots received from the upstream server.
  List<NetworkEnvelope> get recentRosterFrames =>
      List.unmodifiable(_recentRosterFrames);

  /// Roster frames forwarded from the upstream connector.
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

  /// Presence frames forwarded from the upstream connector.
  Stream<NetworkEnvelope> get presenceFrames => _presenceFrames.stream;

  /// Currently registered local session ids.
  Set<String> get activeSessionIds => Set.unmodifiable(_sessions.keys);

  /// The underlying single [MachineConnector] (for diagnostics/tests).
  MachineConnector? get connector => _connector;

  /// Starts the single upstream connector and catalog refresh loop. Idempotent.
  Future<void> start() async {
    _ensureBuilt();
    if (_started) return;
    _started = true;
    await refreshSessionCatalog(fullSnapshot: true);
    await _connector!.start();
    _queueLiveRoster(fullSnapshot: true);
    if (catalogStore != null) {
      (_catalogPoller ??= CatalogPoller(
        run: () => refreshSessionCatalog(),
        timerFactory: catalogPollTimerFactory,
        onError: (error, stackTrace) =>
            onLog?.call('session catalog poll failed: $error'),
      )).start(catalogPollInterval);
    }
  }

  /// Registers or updates one live local session on the shared connector.
  Future<void> registerSession(CliNetworkSession session) async {
    _ensureBuilt();
    final registry = _registry!;
    final previous = _sessions[session.sessionId];
    if (previous != null && previous.session.agentName != session.agentName) {
      _unregisterAgentFromRegistry(previous);
    }
    final address = agentAddress(session.agentName, device.deviceId);
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
    final busy = previous?.busy ?? false;
    _sessions[session.sessionId] = HostedSessionEntry(
      session: session,
      agentAddress: address,
      busy: busy,
    );
    _connector!.presence.setAgentState(
      address,
      busy ? AgentRunState.busy : AgentRunState.live,
    );
    _queueLiveRoster();
  }

  /// Unregisters one local session (e.g. client process exited / disconnected).
  Future<void> unregisterSession(String sessionId) async {
    final removed = _sessions.remove(sessionId);
    if (removed == null) return;
    _unregisterAgentFromRegistry(removed);
    _queueSessionRetraction(removed);
    await _flushRoster();
  }

  /// Updates busy/idle state for one registered session.
  void setBusy(String sessionId, bool busy) {
    final entry = _sessions[sessionId];
    final connector = _connector;
    if (entry == null || connector == null) return;
    if (entry.busy == busy) return;
    entry.busy = busy;
    connector.presence.setAgentState(
      entry.agentAddress,
      busy ? AgentRunState.busy : AgentRunState.live,
    );
    _queueLiveRoster();
    if (!busy) _scheduleCatalogRefresh();
  }

  /// Sends an encrypted DM reply through the shared upstream connector.
  Future<String> sendNetworkDmReply({
    required String address,
    required String text,
    String? callerSessionId,
  }) async {
    final route = DeviceDmReplyRoute.parse(address);
    final connector = _connector;
    if (connector == null) {
      throw StateError('shared connector is not running');
    }
    _validateDmReplyRoute(route, callerSessionId: callerSessionId);
    if (text.trim().isEmpty) {
      throw StateError('network DM reply text must not be empty');
    }
    return sendDeviceDmReply(
      connector: connector,
      keys: _dmKeys,
      route: route,
      reply: text,
    );
  }

  /// Reloads the local session catalog and publishes either a full snapshot
  /// or minimal delta to the upstream server.
  Future<void> refreshSessionCatalog({bool fullSnapshot = false}) async {
    final store = catalogStore;
    if (store == null) return;
    final revision = ++_catalogRevision;
    final loaded = await _loadCatalogSafe(store);
    if (loaded == null || revision != _catalogRevision) return;
    final projection = projectSessionCatalog(
      previous: _catalogEntries,
      current: loaded,
      fullSnapshot: fullSnapshot,
    );
    _catalogEntries = projection.entries;
    _applyCatalogProjection(projection, fullSnapshot: fullSnapshot);
    _connector?.presence.publishNow();
  }

  Future<List<SessionCatalogEntry>?> _loadCatalogSafe(
    SessionCatalogStore store,
  ) async {
    try {
      return await store.loadSessions(liveSessionIds: _sessions.keys.toSet());
    } on Object {
      onLog?.call('session catalog refresh failed');
      return null;
    }
  }

  void _applyCatalogProjection(
    SessionCatalogProjection projection, {
    required bool fullSnapshot,
  }) {
    final retractions = [
      for (final id in projection.retractedIds)
        DeviceRosterSession(id: id, state: 'offline', networks: const []),
    ];
    if (fullSnapshot) {
      _queueLiveRoster(fullSnapshot: true);
      if (retractions.isNotEmpty) _queueRosterEntries(sessions: retractions);
      return;
    }
    if (projection.upserts.isEmpty && retractions.isEmpty) return;
    _queueRosterEntries(
      sessions: [
        for (final row in projection.upserts) _catalogRosterRow(row),
        ...retractions,
      ],
    );
  }

  /// Stops the shared connector cleanly, retracting live agents.
  Future<void> stop() async {
    _started = false;
    _catalogTimer?.cancel();
    _catalogPoller?.stop();
    _catalogPoller?.setActive(false);
    if (_sessions.isNotEmpty) {
      _queueRosterEntries(
        agents: [
          for (final entry in _sessions.values)
            DeviceRosterAgent(
              name: entry.session.agentName,
              state: 'offline',
              exposed: false,
              dmPub: _dmPubs[entry.agentAddress],
            ),
        ],
        sessions: [
          for (final row in normalizeSessionCatalog(_catalogEntries))
            _catalogRosterRow(row, state: 'offline'),
        ],
      );
      await _flushRoster();
    }
    await _connector?.stop();
    _phase = ConnectorLinkState.disconnected;
  }

  /// Disposes all streams and resources.
  Future<void> dispose() async {
    _catalogRevision++;
    await stop();
    _roster.close();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _dmSinkRegistration?.close();
    _dmSinkRegistration = null;
    _connector?.dispose();
    _registry?.dispose();
    if (!_rosterFrames.isClosed) await _rosterFrames.close();
    if (!_presenceFrames.isClosed) await _presenceFrames.close();
  }

  void _scheduleCatalogRefresh() {
    if (catalogStore == null) return;
    _catalogTimer?.cancel();
    _catalogTimer = Timer(
      rosterDebounce,
      () => unawaited(refreshSessionCatalog()),
    );
  }

  void _unregisterAgentFromRegistry(HostedSessionEntry entry) {
    final registry = _registry;
    if (registry == null) return;
    registry.unregisterSession(entry.session.sessionId);
    final stillUsed = _sessions.values.any(
      (other) => other.agentAddress == entry.agentAddress,
    );
    if (!stillUsed) {
      registry.unregisterAgent(entry.session.agentName, device.deviceId);
      _connector?.presence.setAgentState(
        entry.agentAddress,
        AgentRunState.offline,
      );
    }
  }

  void _validateDmReplyRoute(
    DeviceDmReplyRoute route, {
    String? callerSessionId,
  }) {
    final parts = parseDeviceDmChannelId(route.channel);
    final expectedNetwork = device.personalNetworkId ?? 'personal';
    if (parts == null ||
        parts.deviceId != device.deviceId ||
        route.network != expectedNetwork) {
      throw StateError(
        'network DM reply route does not belong to this device/network',
      );
    }
    _validateCallerOwnership(route, callerSessionId);
  }

  void _validateCallerOwnership(
    DeviceDmReplyRoute route,
    String? callerSessionId,
  ) {
    if (callerSessionId == null ||
        route.sessionId == null ||
        route.sessionId == callerSessionId) {
      return;
    }
    final caller = _sessions[callerSessionId];
    if (caller == null || route.agentAddress != caller.agentAddress) {
      throw StateError(
        'network DM reply route does not belong to session $callerSessionId',
      );
    }
  }

  List<String> get _sessionNetworks => [?device.personalNetworkId];

  void _queueLiveRoster({bool fullSnapshot = false}) {
    if (!_started || _phase != ConnectorLinkState.connected) return;
    final catalog = normalizeSessionCatalog(_catalogEntries);
    final catalogById = {for (final row in catalog) row.id: row};
    final agents = <DeviceRosterAgent>[
      for (final entry in _sessions.values)
        DeviceRosterAgent(
          name: entry.session.agentName,
          state: entry.busy ? 'busy' : 'live',
          exposed: true,
          dmPub: _dmPubs[entry.agentAddress],
        ),
    ];
    final sessions = <DeviceRosterSession>[
      if (fullSnapshot)
        for (final row in catalog) _catalogRosterRow(row),
      for (final entry in _sessions.values)
        if (!fullSnapshot || !catalogById.containsKey(entry.session.sessionId))
          catalogById[entry.session.sessionId] != null
              ? _catalogRosterRow(catalogById[entry.session.sessionId]!)
              : _liveRosterRow(entry.session),
    ];
    _queueRosterEntries(agents: agents, sessions: sessions);
  }

  DeviceRosterSession _liveRosterRow(CliNetworkSession session) =>
      DeviceRosterSession(
        id: session.sessionId,
        state: 'live',
        networks: _sessionNetworks,
        title: session.displayName,
        path: session.cwd,
      );

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
          (_sessions.containsKey(normalized.id) ? 'live' : 'wake_on_dm'),
      networks: expose ? _sessionNetworks : const [],
      title: normalized.displayName,
      snippet: metadata['snippet'] as String?,
      path: metadata['path'] as String?,
      cwd: metadata['cwd'] as String?,
      lastActivity: metadata['lastActivity'] as String?,
    );
  }

  void _queueSessionRetraction(HostedSessionEntry entry) {
    final catalogRow = normalizeSessionCatalog(
      _catalogEntries,
    ).where((row) => row.id == entry.session.sessionId).firstOrNull;
    final stillUsed = _sessions.values.any(
      (other) => other.agentAddress == entry.agentAddress,
    );
    _queueRosterEntries(
      agents: [
        if (!stillUsed)
          DeviceRosterAgent(
            name: entry.session.agentName,
            state: 'offline',
            exposed: false,
            dmPub: _dmPubs[entry.agentAddress],
          ),
      ],
      sessions: [
        if (catalogStore != null && catalogRow != null)
          _catalogRosterRow(catalogRow, state: 'wake_on_dm')
        else
          DeviceRosterSession(
            id: entry.session.sessionId,
            state: 'offline',
            networks: _sessionNetworks,
          ),
      ],
    );
  }

  /// Queues roster rows for the shared limiter: merged by key, flushed
  /// after the debounce window inside the per-device PATCH budget.
  void _queueRosterEntries({
    List<DeviceRosterAgent> agents = const [],
    List<DeviceRosterSession> sessions = const [],
  }) {
    _roster.enqueue(agents: agents, sessions: sessions);
  }

  /// Sends the pending roster rows as soon as the budget allows (session
  /// unregister / stop seam) — never waits out a throttle cooldown.
  Future<void> _flushRoster() => _roster.flush();

  void _ensureBuilt() {
    if (_connector != null) return;
    final transport = this.transport;
    if (transport == null) {
      throw StateError('a ConnectorTransport is required');
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
      outbox: outbox ?? MemoryOutboxStore(),
      decodeMail: _decodeDmMail,
      idFactory: idFactory,
      onLog: onLog,
    );
    connector.presence.sessionMetadata = _presenceSessionMetadata;
    connector.presence.exposedSessions = () => <String>{
      for (final row in _catalogEntries) row.id,
      ..._sessions.keys,
    };
    connector.presence.liveLeases = () => _sessions.keys.toSet();
    _registry = registry;
    _connector = connector;
    _dmCodec = dmCodec;
    _dmSinkRegistration = connector.registerLocalSink(
      network: device.personalNetworkId ?? 'personal',
      channel: dmChannelPrefix,
      sink: _onDmSink,
    );
    _subscriptions
      ..add(upstream.stateChanges.listen(_handleUpstreamState))
      ..add(connector.rosterFrames.listen(_handleRosterFrame))
      ..add(connector.presenceFrames.listen(_handlePresenceFrame));
  }

  void _handleUpstreamState(ConnectorLinkState state) {
    _phase = state;
    _catalogPoller?.setActive(state == ConnectorLinkState.connected);
    if (state == ConnectorLinkState.connected) {
      _queueLiveRoster(fullSnapshot: true);
    }
  }

  void _handleRosterFrame(NetworkEnvelope frame) {
    _recentRosterFrames.add(frame);
    if (_recentRosterFrames.length > 64) _recentRosterFrames.removeAt(0);
    if (!_rosterFrames.isClosed) _rosterFrames.add(frame);
  }

  void _handlePresenceFrame(NetworkEnvelope frame) {
    if (!_presenceFrames.isClosed) _presenceFrames.add(frame);
  }

  Future<DecodedMail> _decodeDmMail(NetworkEnvelope envelope) async {
    final parts = parseDeviceDmChannelId(envelope.channel ?? '');
    if (parts == null || parts.deviceId != device.deviceId) {
      throw StateError('non-local DM route left unacked');
    }
    final addressedAgent = agentAddress(parts.agentName, parts.deviceId);
    if (envelope.from == addressedAgent && envelope.to != addressedAgent) {
      return const DecodedMail(payload: '', ownEcho: true);
    }
    if (envelope.to != addressedAgent) {
      throw StateError('DM channel/recipient mismatch left unacked');
    }
    return _dmCodec!.decode(envelope);
  }

  HostedSessionEntry? _resolveTargetSession(
    InboundMail mail,
    NetworkEnvelope envelope,
  ) {
    if (mail.sessionId != null) {
      final byId = _sessions[mail.sessionId!];
      return byId?.session.dmSink != null ? byId : null;
    }
    for (final entry in _sessions.values) {
      if (entry.agentAddress == envelope.to && entry.session.dmSink != null) {
        return entry;
      }
    }
    return null;
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
    final target = _resolveTargetSession(mail, envelope);
    if (target == null) {
      if (await _wakeCatalogSession(mail, route)) {
        throw StateError('network DM wake requested; original left unacked');
      }
      await sendDeviceDmReply(
        connector: connector,
        keys: _dmKeys,
        route: route,
        reply: deviceDmQueuedReceipt,
      );
      throw StateError('network DM queued / not listening; left unacked');
    }
    await target.session.dmSink!(
      CliNetworkDm(
        mail: mail,
        senderLabel: _senderLabel(envelope.from ?? ''),
        replyAddress: route.toAddress(),
      ),
    );
    await sendDeviceDmReply(
      connector: connector,
      keys: _dmKeys,
      route: route,
      reply: deviceDmAcceptedReceipt,
    );
  }

  Future<bool> _wakeCatalogSession(
    InboundMail mail,
    DeviceDmReplyRoute route,
  ) async {
    final target = _findWakeableCatalogRow(mail.sessionId);
    final launcher = wakeLauncher;
    if (target == null || launcher == null) return false;
    await _launchWakeOnce(launcher, target);
    await sendDeviceDmReply(
      connector: _connector!,
      keys: _dmKeys,
      route: route,
      reply: deviceDmQueuedReceipt,
    );
    return true;
  }

  SessionCatalogEntry? _findWakeableCatalogRow(String? targetId) {
    if (targetId == null || _sessions.containsKey(targetId)) return null;
    return normalizeSessionCatalog(
      _catalogEntries,
    ).where((row) => row.id == targetId).firstOrNull;
  }

  Future<void> _launchWakeOnce(
    CliNetworkSessionWakeLauncher launcher,
    SessionCatalogEntry target,
  ) async {
    if (!_wakingSessions.add(target.id)) return;
    try {
      await launcher(cwd: target.cwd, sessionId: target.id);
    } on Object {
      onLog?.call('shared connector wake launcher failed for ${target.id}');
    } finally {
      _wakingSessions.remove(target.id);
    }
  }

  Map<String, ConnectorSessionMetadata> _presenceSessionMetadata() {
    final catalog = normalizeSessionCatalog(_catalogEntries);
    final catalogById = {for (final row in catalog) row.id: row};
    return <String, ConnectorSessionMetadata>{
      for (final row in catalog)
        row.id: ConnectorSessionMetadata(
          title: row.displayName,
          snippet: row.snippet,
          path: row.cwd,
          cwd: row.cwdSlug,
          lastActivity: row.lastActiveAt,
        ),
      for (final entry in _sessions.values)
        entry.session.sessionId: ConnectorSessionMetadata(
          title: (entry.session.displayName?.isNotEmpty ?? false)
              ? entry.session.displayName
              : catalogById[entry.session.sessionId]?.displayName,
          snippet: catalogById[entry.session.sessionId]?.snippet,
          path: entry.session.cwd ?? catalogById[entry.session.sessionId]?.cwd,
          cwd: catalogById[entry.session.sessionId]?.cwdSlug,
          lastActivity: catalogById[entry.session.sessionId]?.lastActiveAt,
        ),
    };
  }

  String _senderLabel(String sender) {
    final at = sender.lastIndexOf('@');
    if (at > 0 && at + 1 < sender.length) {
      return _agentSenderLabel(
        sender,
        sender.substring(0, at),
        sender.substring(at + 1),
      );
    }
    final userId = sender.startsWith('user:')
        ? sender.substring('user:'.length)
        : sender;
    return 'network user $userId';
  }

  String _agentSenderLabel(String sender, String agent, String deviceId) {
    for (final row in parseNetworkDeviceRoster(_recentRosterFrames)) {
      if (row.deviceId == deviceId || row.agentAddresses.contains(sender)) {
        return '${row.name} · $agent';
      }
    }
    return '$deviceId · $agent';
  }
}
