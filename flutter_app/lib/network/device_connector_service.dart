// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app-side host of the machine connector (issue #2062 chunk 14, the
/// contract's "in-process run mode"): one [DeviceConnectorService] per
/// app run, using [NetworkSessionManager] for account/auth state and an
/// injectable [DeviceChatSessionSource] for the local chat roster.
///
/// Lifecycle: on signed-in state (a live ai-native JWT) [start] enrolls
/// the device — skipping re-enroll while a valid token is persisted in
/// the same keychain storage the wallet uses — builds a fresh
/// [DeviceRegistry] (the user's personal network configured
/// [NetworkKind.personal]; loaded chat sessions enumerated from the chat
/// source), wires the upstream device WS
/// ([IoConnectorTransport] + a wsTicket minted per dial from the REST
/// client) and starts the [MachineConnector]. [stop] (sign-out) tears it
/// all down; a later sign-in restarts cleanly.
///
/// The UI binds to the passthrough streams ([rosterFrames],
/// [presenceFrames], [wakeHints], [phaseStream]) — they exist before the
/// first start and survive restarts, so a widget never re-subscribes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_ui/fa_ui.dart' show KeychainStore;
import 'package:flutter/foundation.dart' show Listenable;
// The machine-connector core is pure Dart; the src imports follow the
// lib/network implementation-import convention (key_wallet.dart).
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/device_registry.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/machine_connector.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/offline_outbox.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:path_provider/path_provider.dart';

// ignore: implementation_imports
import 'package:flutter_agent_harness/io.dart'
    hide DeviceRosterAgent, DeviceRosterSession;

import 'device_outbox_store.dart';
import 'fa_network_client.dart';
import 'network_session_manager.dart';

typedef _RosterProjection = ({
  List<DeviceRosterAgent> agents,
  List<DeviceRosterSession> sessions,
});

/// One chat session in the device roster: [live] means its agent is loaded
/// in this process; persisted-but-closed sessions remain visible offline.
typedef DeviceChatSession = ({String id, bool live});

/// The device's chat-session authority for the roster projection.
///
/// Implementations return ALL persisted chat sessions, including offline
/// ones, and notify through [changes] after create/open/close/delete. The
/// legacy default instead exposes network memberships as live sessions so
/// older hosts and tests retain their original behavior.
abstract interface class DeviceChatSessionSource {
  /// Re-emits whenever the session ids or their live states may have changed.
  Listenable get changes;

  /// Loads the current complete projection (never just the live subset).
  Future<List<DeviceChatSession>> load();
}

/// A [DeviceChatSessionSource] backed by host callbacks.
final class CallbackDeviceChatSessionSource implements DeviceChatSessionSource {
  /// Creates a source from a change listenable and a complete-snapshot loader.
  const CallbackDeviceChatSessionSource({
    required this.changes,
    required this.loader,
  });

  /// Loads the source's complete current snapshot.
  final Future<List<DeviceChatSession>> Function() loader;

  @override
  final Listenable changes;

  @override
  Future<List<DeviceChatSession>> load() => loader();
}

/// Back-compat projection used when no chat-session source is injected.
final class _NetworkMembershipSessionSource implements DeviceChatSessionSource {
  const _NetworkMembershipSessionSource(this.manager);

  final NetworkSessionManager manager;

  @override
  Listenable get changes => manager;

  @override
  Future<List<DeviceChatSession>> load() async => [
    for (final id in manager.sessions.keys) (id: id, live: true),
  ];
}

/// The service-level lifecycle state the UI renders.
enum DeviceConnectorPhase {
  /// Not running: signed out (or never started).
  signedOut,

  /// Enrolling / building the connector.
  preparing,

  /// Upstream dial or handshake in flight.
  connecting,

  /// Handshake complete — sends deliver live.
  online,

  /// Was running, link lost — the client is backing off and retrying.
  reconnecting,
}

/// The persisted device identity (contract §1): the stable pair the
/// enrollment returned, kept across restarts so a re-run resumes by the
/// same (deviceId, deviceToken) instead of re-enrolling (§4).
class DeviceCredentials {
  const DeviceCredentials({
    required this.deviceId,
    required this.deviceToken,
    this.personalNetworkId,
  });

  /// Stable device id minted at enroll.
  final String deviceId;

  /// Opaque bearer bound to (userId, deviceId) — never logged.
  final String deviceToken;

  /// The personal network id the server provisioned, when known.
  final String? personalNetworkId;

  /// Parses stored JSON; null on garbage (the caller re-enrolls).
  static DeviceCredentials? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final deviceId = json['deviceId'];
    final deviceToken = json['deviceToken'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceToken is! String ||
        deviceToken.isEmpty) {
      return null;
    }
    final personal = json['personalNetworkId'];
    return DeviceCredentials(
      deviceId: deviceId,
      deviceToken: deviceToken,
      personalNetworkId: personal is String && personal.isNotEmpty
          ? personal
          : null,
    );
  }

  /// Serializes to JSON.
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'deviceToken': deviceToken,
    if (personalNetworkId != null) 'personalNetworkId': personalNetworkId,
  };
}

/// Persistence seam for [DeviceCredentials]. Production backs it with
/// the platform keychain — the same fa_ui [KeychainStore] storage the
/// wallet uses ([KeychainDeviceTokenStore]); tests inject an in-memory
/// fake.
abstract interface class DeviceTokenStore {
  /// The stored credentials, or null when none (or garbage) is stored.
  Future<DeviceCredentials?> read();

  /// Persists [credentials], replacing any previous content.
  Future<void> write(DeviceCredentials credentials);

  /// Removes the stored credentials.
  Future<void> clear();
}

/// The keychain-backed [DeviceTokenStore] — one JSON document under the
/// SAME [KeychainStore] entry space the wallet uses (its own name, so a
/// wallet import/reset never clobbers the device identity). The closure
/// pattern mirrors [KeychainWalletBackend] (fa_ui's KeychainStore has no
/// interface).
class KeychainDeviceTokenStore implements DeviceTokenStore {
  /// Creates the store; with no closures injected a real [KeychainStore]
  /// is used.
  KeychainDeviceTokenStore({
    Future<Map<String, String>> Function()? readAll,
    Future<bool> Function(String name, String value)? setValue,
  }) : _readAll = readAll ?? const KeychainStore().readAll,
       _setValue = setValue ?? const KeychainStore().set;

  /// The keychain entry the device credentials JSON is stored under.
  static const storageName = 'fa_network_device';

  final Future<Map<String, String>> Function() _readAll;
  final Future<bool> Function(String name, String value) _setValue;

  @override
  Future<DeviceCredentials?> read() async {
    final stored = (await _readAll())[storageName];
    if (stored == null || stored.isEmpty) return null;
    try {
      return DeviceCredentials.tryFromJson(jsonDecode(stored));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(DeviceCredentials credentials) =>
      _setValue(storageName, jsonEncode(credentials.toJson()));

  @override
  Future<void> clear() =>
      _setValue(storageName, jsonEncode(const <String, Object?>{}));
}

/// Hosts the machine connector inside the app (see the library docs).
class DeviceConnectorService {
  /// Builds the service over [sessionManager]. Every dependency is
  /// injectable: [chatSessionSource] (default legacy network memberships),
  /// [tokenStore] (default keychain), [outbox] (default a [FileOutboxStore]
  /// under the app support directory), [transport] (default the dart:io
  /// [IoConnectorTransport]), [idFactory] and [onLog] for tests.
  DeviceConnectorService({
    required this.sessionManager,
    DeviceChatSessionSource? chatSessionSource,
    DeviceTokenStore? tokenStore,
    OutboxStore? outbox,
    ConnectorTransport? transport,
    Future<String> Function()? supportDirProvider,
    this.idFactory = defaultIdFactory,
    this.onLog,
    this.rosterDebounce = const Duration(milliseconds: 500),
  }) : _tokenStore = tokenStore ?? KeychainDeviceTokenStore(),
       _outboxOverride = outbox,
       _transport = transport ?? const IoConnectorTransport(),
       _supportDirProvider =
           supportDirProvider ??
           (() async => (await getApplicationSupportDirectory()).path) {
    _chatSessionSource =
        chatSessionSource ?? _NetworkMembershipSessionSource(sessionManager);
    sessionManager.addListener(_onManagerChanged);
    _chatSessionSource.changes.addListener(_onChatSessionsChanged);
  }

  /// The session manager — the JWT/session integration point (fresh
  /// clients via [NetworkSessionManager.accountClient], live sessions
  /// via [NetworkSessionManager.sessions]).
  final NetworkSessionManager sessionManager;

  late final DeviceChatSessionSource _chatSessionSource;
  final DeviceTokenStore _tokenStore;
  final OutboxStore? _outboxOverride;
  final ConnectorTransport _transport;
  final Future<String> Function() _supportDirProvider;

  /// Delay used to coalesce rapid REST roster changes (test-adjustable).
  final Duration rosterDebounce;

  /// Frame id factory.
  final IdFactory idFactory;

  /// Soft diagnostics sink (null = drop). Never carries tokens.
  void Function(String message)? onLog;

  DeviceCredentials? _credentials;
  DeviceInfo? _ownDevice;
  MachineConnector? _connector;
  DeviceRegistry? _registry;
  var _generation = 0;
  var _running = false;
  var _phase = DeviceConnectorPhase.signedOut;
  String? _lastStartError;
  final _subscriptions = <StreamSubscription<Object?>>[];

  // REST roster projection state. The server merges by agent name/session
  // id, so deltas are accumulated by the same keys during the debounce.
  Timer? _rosterTimer;
  final _pendingRosterAgents = <String, DeviceRosterAgent>{};
  final _pendingRosterSessions = <String, DeviceRosterSession>{};
  var _observedSessions = <String, DeviceChatSession>{};
  final _knownAgentNames = <String>{};
  var _rosterActive = false;
  var _sessionProjectionRevision = 0;
  Future<void> _rosterWrites = Future<void>.value();

  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();

  /// Latest roster frame per network. The server pushes roster frames ONCE
  /// per (re)connect, but the Devices page subscribes long after the
  /// handshake — and REST /api/devices carries NO session projections — so
  /// without this replay a late-opening page would never see any sessions.
  final _lastRosterByNetwork = <String, NetworkEnvelope>{};

  /// The most recent roster frame per network, for late subscribers.
  List<NetworkEnvelope> get currentRosterFrames =>
      List.unmodifiable(_lastRosterByNetwork.values);
  final _presenceFrames = StreamController<NetworkEnvelope>.broadcast();
  final _presence = StreamController<PresenceFrame>.broadcast();
  final _wakeHints = StreamController<NetworkEnvelope>.broadcast();
  final _phases = StreamController<DeviceConnectorPhase>.broadcast();
  final _ownDeviceChanges = StreamController<DeviceInfo?>.broadcast();

  /// The current lifecycle phase.
  DeviceConnectorPhase get phase => _phase;

  /// The last failed [start]'s error text (null after a clean start or a
  /// fresh attempt) — the DEVICES surface renders it so enrollment/
  /// keychain/WS failures are visible instead of a blank panel.
  String? get lastStartError => _lastStartError;

  /// Fires on every phase transition.
  Stream<DeviceConnectorPhase> get phaseStream => _phases.stream;

  /// Roster snapshots/patches from the server (§4).
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

  /// Presence frames from the server (network-wide presence view).
  Stream<NetworkEnvelope> get presenceFrames => _presenceFrames.stream;

  /// Presence frames PARSED to their payload model (§5) — the stable
  /// stream the roster UI binds (a StreamBuilder over a per-build
  /// `.map()` would resubscribe on every rebuild and drop state).
  Stream<PresenceFrame> get presence => _presence.stream;

  /// Wake hints (§8).
  Stream<NetworkEnvelope> get wakeHints => _wakeHints.stream;

  /// The most recent roster snapshot envelope, or null before one
  /// arrives (the UI's "roster snapshot getter").
  NetworkEnvelope? get rosterSnapshot => _connector?.upstream.lastRoster;

  /// The live connector while running, null otherwise (test seam).
  MachineConnector? get connector => _connector;

  /// Whether [start] is active.
  bool get isRunning => _running;

  /// The enrolled device id while running (or persisted), null before.
  String? get deviceId => _credentials?.deviceId;

  /// The personal network provisioned at enrollment, when the server sent it.
  String? get personalNetworkId => _credentials?.personalNetworkId;

  /// The latest account-roster information for this machine. In particular,
  /// [DeviceInfo.friendlyName] is the local label source after a rename.
  DeviceInfo? get ownDevice => _ownDevice;

  /// Convenience accessor for the own rail's friendly label (null = default).
  String? get ownFriendlyName => _ownDevice?.friendlyName;

  /// Re-emits this machine's account-roster state after refresh/rename.
  Stream<DeviceInfo?> get ownDeviceStream => _ownDeviceChanges.stream;

  /// Reloads this machine's friendly/enrollment name from `GET /api/devices`.
  /// Returns null before enrollment or when the id is absent from the roster.
  Future<DeviceInfo?> refreshOwnDevice() async {
    final id = deviceId;
    if (id == null || id.isEmpty) return null;
    final client = await sessionManager.accountClient();
    if (client == null) {
      throw StateError('not signed in — cannot load the device roster');
    }
    final devices = await client.listDevices();
    DeviceInfo? own;
    for (final device in devices) {
      if (device.deviceId == id) {
        own = device;
        break;
      }
    }
    _setOwnDevice(own);
    return own;
  }

  /// Sets or clears this machine's friendly name through the account JWT.
  /// Returns the normalized local label (null after clearing). The local
  /// update happens only after the server accepts the PATCH.
  Future<String?> renameOwnDevice(String name) async {
    if (name.runes.length > 64) {
      throw ArgumentError.value(
        name,
        'name',
        'Device friendly names are limited to 64 runes',
      );
    }
    final id = deviceId;
    if (id == null || id.isEmpty) {
      throw StateError('device not enrolled — cannot rename it');
    }
    final client = await sessionManager.accountClient();
    if (client == null) {
      throw StateError('not signed in — cannot rename the device');
    }
    final result = await client.renameDevice(id, name);
    final friendly = result.friendlyName.isEmpty ? null : result.friendlyName;
    final current = _ownDevice;
    _setOwnDevice(
      DeviceInfo(
        deviceId: id,
        name: current?.name ?? id,
        friendlyName: friendly,
        createdAt: current?.createdAt,
        revokedAt: current?.revokedAt,
        presence: current?.presence,
        userId: current?.userId,
      ),
    );
    return friendly;
  }

  /// Fetches the personal network's authoritative machine roster. Older
  /// enrollments without a personal network id have no REST roster to fetch.
  Future<List<DeviceInfo>> listNetworkDevices() async {
    final networkId = personalNetworkId;
    if (networkId == null || networkId.isEmpty) return const [];
    final client = await sessionManager.accountClient();
    if (client == null) {
      throw StateError('not signed in — cannot load network devices');
    }
    return client.listNetworkDevices(networkId);
  }

  void _setOwnDevice(DeviceInfo? device) {
    _ownDevice = device;
    if (!_ownDeviceChanges.isClosed) _ownDeviceChanges.add(device);
  }

  /// Starts the connector on signed-in state. Idempotent: concurrent or
  /// repeated calls share the one in-flight start; a signed-out call is
  /// a silent no-op. Failures log, tear down and leave the service
  /// stopped (a later sign-in or [start] retries).
  Future<void> start() async {
    if (_running) return;
    final generation = ++_generation;
    _lastStartError = null;
    _setPhase(DeviceConnectorPhase.preparing);
    try {
      await _start(generation);
    } on Object catch (error) {
      onLog?.call('device connector start failed: $error');
      _lastStartError = error.toString();
      if (generation != _generation) return;
      await _teardown();
      _setPhase(DeviceConnectorPhase.signedOut);
    }
  }

  /// Clean stop: tears the connector down (the server deregisters the
  /// machine on the clean close, §5). Idempotent.
  Future<void> stop() async {
    _generation++;
    await _retractRoster();
    await _teardown();
    _setPhase(DeviceConnectorPhase.signedOut);
  }

  /// Stops and detaches from the session manager; the streams close.
  Future<void> dispose() async {
    sessionManager.removeListener(_onManagerChanged);
    _chatSessionSource.changes.removeListener(_onChatSessionsChanged);
    await stop();
    await _rosterFrames.close();
    await _presenceFrames.close();
    await _presence.close();
    await _wakeHints.close();
    await _phases.close();
    await _ownDeviceChanges.close();
  }

  void _onManagerChanged() {
    if (sessionManager.hasJwt) {
      if (!_running) unawaited(start());
    } else if (_running || _phase != DeviceConnectorPhase.signedOut) {
      unawaited(stop());
    }
  }

  void _onChatSessionsChanged() {
    if (_rosterActive) unawaited(_syncRosterSessions());
  }

  Future<void> _start(int generation) async {
    final jwt = await sessionManager.ensureFreshJwt();
    if (generation != _generation) return;
    if (jwt == null || jwt.isEmpty) {
      await _teardown();
      _setPhase(DeviceConnectorPhase.signedOut);
      return;
    }
    final credentials = await _resolveCredentials();
    _credentials = credentials;
    if (generation != _generation) return;

    final registry = DeviceRegistry();
    final personal = credentials.personalNetworkId ?? 'personal';
    registry.configureNetwork(personal, NetworkKind.personal);
    final sessions = await _currentChatSessions();
    if (generation != _generation) {
      registry.dispose();
      return;
    }
    for (final session in sessions.values) {
      if (session.live) registry.registerSession(_registrationFor(session));
    }
    _observedSessions = sessions;

    final upstream = ConnectorUpstreamClient(
      url: _deviceWsUrl(),
      transport: _transport,
      ticketProvider: () => _mintTicket(),
      deviceId: credentials.deviceId,
      deviceToken: credentials.deviceToken,
      idFactory: idFactory,
      onLog: onLog,
    );
    final connector = MachineConnector(
      registry: registry,
      upstream: upstream,
      outbox: _outboxOverride ?? await _defaultOutbox(),
      presence: PresenceEngine(
        clock: const SystemClock(),
        timers: const SystemTimers(),
        idFactory: idFactory,
      ),
      leases: () async => sessionManager.sessions.keys.toSet(),
      idFactory: idFactory,
      onLog: onLog,
    );
    if (generation != _generation) {
      unawaited(connector.stop());
      connector.dispose();
      registry.dispose();
      return;
    }
    _registry = registry;
    _connector = connector;
    _wireForwarding(connector, generation);
    await connector.start();
    if (generation != _generation) return;
    _running = true;
  }

  /// Loads the persisted device credentials, enrolling (and persisting)
  /// only when none are stored.
  Future<DeviceCredentials> _resolveCredentials() async {
    final stored = await _tokenStore.read();
    if (stored != null) {
      onLog?.call('device credentials restored (${stored.deviceId})');
      return stored;
    }
    final client = await sessionManager.accountClient();
    if (client == null) {
      throw StateError('not signed in — cannot enroll the device');
    }
    final enrollment = await client.enrollDevice();
    final credentials = DeviceCredentials(
      deviceId: enrollment.deviceId,
      deviceToken: enrollment.deviceToken,
      personalNetworkId: enrollment.personalNetworkId,
    );
    await _tokenStore.write(credentials);
    onLog?.call('device enrolled (${credentials.deviceId})');
    return credentials;
  }

  /// Mints one single-use device WS ticket per dial (§4, TTL 60 s).
  Future<String> _mintTicket() async {
    final token = _credentials?.deviceToken;
    if (token == null) throw StateError('device not enrolled');
    final client = await sessionManager.accountClient();
    if (client == null) throw StateError('not signed in — no ticket');
    return client.wsTicket(deviceToken: token);
  }

  /// The device WS URL from the REST base (https→wss), path `/ws`.
  Uri _deviceWsUrl() {
    final base = sessionManager.baseUrl;
    final scheme = base.scheme == 'http' ? 'ws' : 'wss';
    return base.replace(scheme: scheme, path: '/ws');
  }

  /// The local agent identity: `<name>@<deviceId>` from the account
  /// display name (fallback login, fallback `fa`).
  String _localAgentAddress() {
    final raw =
        sessionManager.accountDisplayName ?? sessionManager.accountLogin ?? '';
    final name = raw.trim().replaceAll(RegExp(r'\s+'), '-').toLowerCase();
    final deviceId = _credentials?.deviceId ?? 'local';
    return '${name.isEmpty ? 'fa' : name}@$deviceId';
  }

  /// The default outbox: one JSONL file under the app support directory.
  Future<OutboxStore> _defaultOutbox() async {
    final dir = await _supportDirProvider();
    return FileOutboxStore(File('$dir/device_outbox.jsonl'));
  }

  /// Forwards the connector's surface onto the service's long-lived
  /// streams and maps link states to UI phases.
  void _wireForwarding(MachineConnector connector, int generation) {
    _subscriptions.add(
      connector.rosterFrames.listen((envelope) {
        _lastRosterByNetwork[envelope.network ?? ''] = envelope;
        _rosterFrames.add(envelope);
      }),
    );
    _subscriptions.add(
      connector.presenceFrames.listen((envelope) {
        _presenceFrames.add(envelope);
        final frame = PresenceFrame.fromEnvelope(envelope);
        if (frame != null) _presence.add(frame);
      }),
    );
    _subscriptions.add(connector.wakeHints.listen(_wakeHints.add));
    _subscriptions.add(
      connector.upstream.stateChanges.listen((state) {
        if (generation != _generation) return;
        switch (state) {
          case ConnectorLinkState.connected:
            _setPhase(DeviceConnectorPhase.online);
            unawaited(_publishRoster(generation));
          case ConnectorLinkState.connecting:
          case ConnectorLinkState.handshaking:
            _setPhase(DeviceConnectorPhase.connecting);
          case ConnectorLinkState.disconnected:
            _setPhase(DeviceConnectorPhase.reconnecting);
        }
      }),
    );
  }

  Future<Map<String, DeviceChatSession>> _currentChatSessions() async {
    try {
      final sessions = await _chatSessionSource.load();
      return {for (final session in sessions) session.id: session};
    } on Object catch (error) {
      onLog?.call('device chat-session projection failed: $error');
      return _observedSessions;
    }
  }

  SessionRegistration _registrationFor(DeviceChatSession session) =>
      SessionRegistration(id: session.id, agentAddressOf: _localAgentAddress());

  /// Publishes every persisted session and its actual state after every WS
  /// handshake. This is deliberately a full merge: the server may hold rows
  /// from an earlier connection or a PATCH that did not arrive.
  Future<void> _publishRoster(int generation) async {
    final revision = ++_sessionProjectionRevision;
    final current = await _currentChatSessions();
    if (generation != _generation || revision != _sessionProjectionRevision) {
      return;
    }
    _syncRegistrySessions(_observedSessions, current);
    _observedSessions = current;
    _rosterActive = true;
    _queueRoster(
      _buildRosterProjection(sessions: current.values, agentState: 'live'),
    );
  }

  /// Turns source notifications into minimal merge patches. A live→offline
  /// transition keeps the persisted row; a deleted id is projected from the
  /// previous snapshot so its retraction is explicit.
  Future<void> _syncRosterSessions() async {
    if (!_rosterActive) return;
    final revision = ++_sessionProjectionRevision;
    final previous = _observedSessions;
    final current = await _currentChatSessions();
    if (!_rosterActive || revision != _sessionProjectionRevision) return;
    if (_sameChatSessions(previous, current)) return;
    _syncRegistrySessions(previous, current);
    _observedSessions = current;
    _queueChangedRosterSessions(previous, current);
    _queueClosedRosterSessions(previous, current);
  }

  void _queueChangedRosterSessions(
    Map<String, DeviceChatSession> previous,
    Map<String, DeviceChatSession> current,
  ) {
    final changed = [
      for (final entry in current.entries)
        if (previous[entry.key] != entry.value) entry.value,
    ];
    if (changed.isEmpty) return;
    _queueRoster(
      _buildRosterProjection(
        sessions: changed,
        agentState: 'live',
        includeAgents: changed.any((session) => session.live),
      ),
    );
  }

  void _queueClosedRosterSessions(
    Map<String, DeviceChatSession> previous,
    Map<String, DeviceChatSession> current,
  ) {
    final closed = [
      for (final entry in previous.entries)
        if (!current.containsKey(entry.key)) entry.value,
    ];
    if (closed.isEmpty) return;
    _queueRoster(
      _buildRosterProjection(
        sessions: closed,
        sessionState: 'offline',
        agentState: 'offline',
        includeAgents: false,
      ),
    );
  }

  bool _sameChatSessions(
    Map<String, DeviceChatSession> left,
    Map<String, DeviceChatSession> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _syncRegistrySessions(
    Map<String, DeviceChatSession> previous,
    Map<String, DeviceChatSession> current,
  ) {
    for (final entry in previous.entries) {
      if (entry.value.live && current[entry.key]?.live != true) {
        _registry?.unregisterSession(entry.key);
      }
    }
    for (final entry in current.entries) {
      if (entry.value.live && previous[entry.key]?.live != true) {
        _registry?.registerSession(_registrationFor(entry.value));
      }
    }
  }

  Set<String> _registeredAgentNames(Iterable<DeviceChatSession> sessions) => {
    if (sessions.isNotEmpty) _agentNameFromAddress(_localAgentAddress()),
  };

  String _agentNameFromAddress(String address) {
    final separator = address.lastIndexOf('@');
    return separator < 1 ? address : address.substring(0, separator);
  }

  /// The single builder used by connect, deltas, and final retraction.
  _RosterProjection _buildRosterProjection({
    required Iterable<DeviceChatSession> sessions,
    String? sessionState,
    required String agentState,
    bool includeAgents = true,
    Iterable<String> extraAgentNames = const [],
  }) {
    final projected = sessions.toList(growable: false);
    final agentNames = includeAgents
        ? <String>{...extraAgentNames, ..._registeredAgentNames(projected)}
        : <String>{};
    final networkId = personalNetworkId;
    final networks = [if (networkId != null && networkId.isNotEmpty) networkId];
    return (
      agents: [
        for (final name in agentNames)
          DeviceRosterAgent(
            name: name,
            state: agentState,
            exposed: agentState != 'offline',
          ),
      ],
      sessions: [
        for (final session in projected)
          DeviceRosterSession(
            id: session.id,
            state: sessionState ?? (session.live ? 'live' : 'offline'),
            networks: networks,
          ),
      ],
    );
  }

  void _queueRoster(_RosterProjection projection) {
    for (final agent in projection.agents) {
      _pendingRosterAgents[agent.name] = agent;
      _knownAgentNames.add(agent.name);
    }
    for (final session in projection.sessions) {
      _pendingRosterSessions[session.id] = session;
    }
    if (_pendingRosterAgents.isEmpty && _pendingRosterSessions.isEmpty) return;
    _rosterTimer?.cancel();
    _rosterTimer = Timer(rosterDebounce, _flushRoster);
  }

  void _flushRoster() {
    _rosterTimer?.cancel();
    _rosterTimer = null;
    if (_pendingRosterAgents.isEmpty && _pendingRosterSessions.isEmpty) return;
    final deviceId = _credentials?.deviceId;
    if (deviceId == null) {
      _pendingRosterAgents.clear();
      _pendingRosterSessions.clear();
      return;
    }
    final agents = List<DeviceRosterAgent>.of(_pendingRosterAgents.values);
    final sessions = List<DeviceRosterSession>.of(
      _pendingRosterSessions.values,
    );
    agents.sort((left, right) => left.name.compareTo(right.name));
    sessions.sort((left, right) => left.id.compareTo(right.id));
    _pendingRosterAgents.clear();
    _pendingRosterSessions.clear();
    _rosterWrites = _rosterWrites.then(
      (_) => _writeRoster(deviceId, agents, sessions),
    );
  }

  Future<void> _writeRoster(
    String deviceId,
    List<DeviceRosterAgent> agents,
    List<DeviceRosterSession> sessions,
  ) async {
    try {
      final client = await sessionManager.accountClient();
      if (client == null) {
        onLog?.call('device roster publish skipped: no account client');
        return;
      }
      await client.patchDeviceRoster(
        deviceId,
        agents: agents,
        sessions: sessions,
      );
      onLog?.call('device roster published: ${sessions.length} sessions');
    } on Object catch (error) {
      onLog?.call('device roster publish skipped: $error');
    }
  }

  /// Best-effort final retraction, serialized after any live write already
  /// in flight so a slower live response cannot leave the roster online.
  Future<void> _retractRoster() async {
    _rosterTimer?.cancel();
    _rosterTimer = null;
    _pendingRosterAgents.clear();
    _pendingRosterSessions.clear();
    if (!_rosterActive) return;
    _rosterActive = false;
    _queueRoster(
      _buildRosterProjection(
        sessions: _observedSessions.values,
        sessionState: 'offline',
        agentState: 'offline',
        extraAgentNames: _knownAgentNames,
      ),
    );
    _flushRoster();
    await _rosterWrites;
  }

  Future<void> _teardown() async {
    _lastRosterByNetwork.clear();
    _sessionProjectionRevision++;
    _rosterTimer?.cancel();
    _rosterTimer = null;
    _pendingRosterAgents.clear();
    _pendingRosterSessions.clear();
    _observedSessions = {};
    _knownAgentNames.clear();
    _rosterActive = false;
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    final connector = _connector;
    final registry = _registry;
    _connector = null;
    _registry = null;
    _running = false;
    if (connector != null) {
      await connector.stop();
      connector.dispose();
    }
    registry?.dispose();
  }

  void _setPhase(DeviceConnectorPhase next) {
    if (_phase == next) return;
    _phase = next;
    _phases.add(next);
  }
}
