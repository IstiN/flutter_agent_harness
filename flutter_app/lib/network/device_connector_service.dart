// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app-side host of the machine connector (issue #2062 chunk 14, the
/// contract's "in-process run mode"): one [DeviceConnectorService] per
/// app run, bound to the [NetworkSessionManager].
///
/// Lifecycle: on signed-in state (a live ai-native JWT) [start] enrolls
/// the device — skipping re-enroll while a valid token is persisted in
/// the same keychain storage the wallet uses — builds a fresh
/// [DeviceRegistry] (the user's personal network configured
/// [NetworkKind.personal]; local agents enumerated from the session
/// manager's live sessions), wires the upstream device WS
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
import 'package:flutter_agent_harness/io.dart';

import 'device_outbox_store.dart';
import 'network_session_manager.dart';

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
  /// injectable: [tokenStore] (default keychain), [outbox] (default a
  /// [FileOutboxStore] under the app support directory), [transport]
  /// (default the dart:io [IoConnectorTransport]), [idFactory] and
  /// [onLog] for tests.
  DeviceConnectorService({
    required this.sessionManager,
    DeviceTokenStore? tokenStore,
    OutboxStore? outbox,
    ConnectorTransport? transport,
    Future<String> Function()? supportDirProvider,
    this.idFactory = defaultIdFactory,
    this.onLog,
  }) : _tokenStore = tokenStore ?? KeychainDeviceTokenStore(),
       _outboxOverride = outbox,
       _transport = transport ?? const IoConnectorTransport(),
       _supportDirProvider =
           supportDirProvider ??
           (() async => (await getApplicationSupportDirectory()).path) {
    sessionManager.addListener(_onManagerChanged);
  }

  /// The session manager — the JWT/session integration point (fresh
  /// clients via [NetworkSessionManager.accountClient], live sessions
  /// via [NetworkSessionManager.sessions]).
  final NetworkSessionManager sessionManager;

  final DeviceTokenStore _tokenStore;
  final OutboxStore? _outboxOverride;
  final ConnectorTransport _transport;
  final Future<String> Function() _supportDirProvider;

  /// Frame id factory.
  final IdFactory idFactory;

  /// Soft diagnostics sink (null = drop). Never carries tokens.
  void Function(String message)? onLog;

  DeviceCredentials? _credentials;
  MachineConnector? _connector;
  DeviceRegistry? _registry;
  var _generation = 0;
  var _running = false;
  var _phase = DeviceConnectorPhase.signedOut;
  final _subscriptions = <StreamSubscription<Object?>>[];

  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  final _presenceFrames = StreamController<NetworkEnvelope>.broadcast();
  final _wakeHints = StreamController<NetworkEnvelope>.broadcast();
  final _phases = StreamController<DeviceConnectorPhase>.broadcast();

  /// The current lifecycle phase.
  DeviceConnectorPhase get phase => _phase;

  /// Fires on every phase transition.
  Stream<DeviceConnectorPhase> get phaseStream => _phases.stream;

  /// Roster snapshots/patches from the server (§4).
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

  /// Presence frames from the server (network-wide presence view).
  Stream<NetworkEnvelope> get presenceFrames => _presenceFrames.stream;

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

  /// Starts the connector on signed-in state. Idempotent: concurrent or
  /// repeated calls share the one in-flight start; a signed-out call is
  /// a silent no-op. Failures log, tear down and leave the service
  /// stopped (a later sign-in or [start] retries).
  Future<void> start() async {
    if (_running) return;
    final generation = ++_generation;
    _setPhase(DeviceConnectorPhase.preparing);
    try {
      await _start(generation);
    } on Object catch (error) {
      onLog?.call('device connector start failed: $error');
      if (generation != _generation) return;
      await _teardown();
      _setPhase(DeviceConnectorPhase.signedOut);
    }
  }

  /// Clean stop: tears the connector down (the server deregisters the
  /// machine on the clean close, §5). Idempotent.
  Future<void> stop() async {
    _generation++;
    await _teardown();
    _setPhase(DeviceConnectorPhase.signedOut);
  }

  /// Stops and detaches from the session manager; the streams close.
  Future<void> dispose() async {
    sessionManager.removeListener(_onManagerChanged);
    await stop();
    await _rosterFrames.close();
    await _presenceFrames.close();
    await _wakeHints.close();
    await _phases.close();
  }

  void _onManagerChanged() {
    if (sessionManager.hasJwt) {
      if (!_running) unawaited(start());
    } else if (_running || _phase != DeviceConnectorPhase.signedOut) {
      unawaited(stop());
    }
  }

  Future<void> _start(int generation) async {
    final jwt = await sessionManager.ensureFreshJwt();
    if (generation != _generation) return;
    if (jwt == null || jwt.isEmpty) {
      await _teardown();
      _setPhase(DeviceConnectorPhase.signedOut);
      return;
    }
    _credentials = await _resolveCredentials();
    if (generation != _generation) return;

    final registry = DeviceRegistry();
    final personal = _credentials!.personalNetworkId ?? 'personal';
    registry.configureNetwork(personal, NetworkKind.personal);
    final agentAddress = _localAgentAddress();
    for (final sessionId in sessionManager.sessions.keys) {
      registry.registerSession(
        SessionRegistration(id: sessionId, agentAddressOf: agentAddress),
      );
    }

    final upstream = ConnectorUpstreamClient(
      url: _deviceWsUrl(),
      transport: _transport,
      ticketProvider: () => _mintTicket(),
      deviceId: _credentials!.deviceId,
      deviceToken: _credentials!.deviceToken,
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
    _wireForwarding(connector);
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
  void _wireForwarding(MachineConnector connector) {
    _subscriptions.add(connector.rosterFrames.listen(_rosterFrames.add));
    _subscriptions.add(connector.presenceFrames.listen(_presenceFrames.add));
    _subscriptions.add(connector.wakeHints.listen(_wakeHints.add));
    _subscriptions.add(
      connector.upstream.stateChanges.listen((state) {
        switch (state) {
          case ConnectorLinkState.connected:
            _setPhase(DeviceConnectorPhase.online);
          case ConnectorLinkState.connecting:
          case ConnectorLinkState.handshaking:
            _setPhase(DeviceConnectorPhase.connecting);
          case ConnectorLinkState.disconnected:
            _setPhase(DeviceConnectorPhase.reconnecting);
        }
      }),
    );
  }

  Future<void> _teardown() async {
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
