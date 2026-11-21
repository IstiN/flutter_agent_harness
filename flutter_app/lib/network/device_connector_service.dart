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

import 'package:cryptography/cryptography.dart';
import 'package:fa_ui/fa_ui.dart' show KeychainStore;
import 'package:flutter/foundation.dart'
    show Listenable, debugPrint, kDebugMode, kIsWeb;
// The machine-connector core is pure Dart; the src imports follow the
// lib/network implementation-import convention (key_wallet.dart).
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/connector_mux.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/device_dm.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/device_dm_keys.dart';
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
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/session/session_catalog.dart';
import 'package:path_provider/path_provider.dart';

// ignore: implementation_imports
import 'package:flutter_agent_harness/io.dart'
    hide DeviceRosterAgent, DeviceRosterSession;

import 'device_dm_session_host.dart';
import 'device_name.dart';
import 'device_outbox_store.dart';
import 'fa_network_client.dart';
import 'network_session_manager.dart';

typedef _RosterProjection = ({
  List<DeviceRosterAgent> agents,
  List<DeviceRosterSession> sessions,
});

typedef _ChatSessionSnapshot = ({
  Map<String, DeviceChatSession> sessions,
  Map<String, DeviceChatSessionMetadata> metadata,
  Map<String, DeviceChatSessionActivity> activity,
  Set<String> retractedSessionIds,
});

/// One chat session in the device roster: [live] means its agent is loaded
/// in this process; persisted-but-closed sessions remain visible wake-on-DM.
typedef DeviceChatSession = ({String id, bool live});

/// Additive display metadata for a chat session. This is deliberately a
/// separate record so existing [DeviceChatSession] record literals and simple
/// sources remain source-compatible while newer hosts publish rich rows.
typedef DeviceChatSessionMetadata = ({
  String id,
  String? title,
  String? snippet,
  String? path,
  DateTime? lastActivity,
});

/// Optional extension implemented by sources that can supply row metadata.
/// Sources without it continue to publish legacy id/state-only rosters.
abstract interface class DeviceChatSessionMetadataSource {
  /// Loads display metadata for the current session projection.
  Future<List<DeviceChatSessionMetadata>> loadMetadata();
}

/// Additive per-session run state. A separate source keeps legacy
/// [DeviceChatSession] literals and metadata-only hosts source-compatible.
typedef DeviceChatSessionActivity = ({String id, bool busy});

/// Optional extension implemented by hosts that know the real agent run
/// state. Busy always implies a live session; persisted sleepers stay idle.
abstract interface class DeviceChatSessionActivitySource {
  /// Loads the current per-session busy/idle projection.
  Future<List<DeviceChatSessionActivity>> loadActivity();
}

/// Optional legacy-row cleanup source. Ids are sent as offline/no-network
/// retractions and are never exposed as sessions or DM targets themselves.
abstract interface class DeviceChatSessionRetractionSource {
  /// Loads hidden sub-agent ids that older clients may have published.
  Future<Set<String>> loadRetractedSessionIds();
}

ConnectorSessionMetadata _presenceMetadata(DeviceChatSessionMetadata row) =>
    ConnectorSessionMetadata(
      title: row.title ?? row.snippet,
      snippet: row.snippet,
      path: row.path,
      cwd: sessionCatalogCwdSlug(row.path ?? ''),
      lastActivity: row.lastActivity,
    );

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
final class CallbackDeviceChatSessionSource
    implements
        DeviceChatSessionSource,
        DeviceChatSessionMetadataSource,
        DeviceChatSessionActivitySource,
        DeviceChatSessionRetractionSource {
  /// Creates a source from a change listenable and a complete-snapshot loader.
  /// Optional metadata/activity loaders preserve legacy id-only projections.
  const CallbackDeviceChatSessionSource({
    required this.changes,
    required this.loader,
    this.metadataLoader,
    this.activityLoader,
    this.retractedSessionIdsLoader,
  });

  /// Loads the source's complete current snapshot.
  final Future<List<DeviceChatSession>> Function() loader;

  /// Loads the canonical Local-panel title/path/activity projection.
  final Future<List<DeviceChatSessionMetadata>> Function()? metadataLoader;

  /// Loads the real per-session agent run state.
  final Future<List<DeviceChatSessionActivity>> Function()? activityLoader;

  /// Loads hidden legacy child ids for explicit server-side retraction.
  final Future<Set<String>> Function()? retractedSessionIdsLoader;

  @override
  final Listenable changes;

  @override
  Future<List<DeviceChatSession>> load() => loader();

  @override
  Future<List<DeviceChatSessionMetadata>> loadMetadata() async =>
      await metadataLoader?.call() ?? const [];

  @override
  Future<List<DeviceChatSessionActivity>> loadActivity() async =>
      await activityLoader?.call() ?? const [];

  @override
  Future<Set<String>> loadRetractedSessionIds() async =>
      await retractedSessionIdsLoader?.call() ?? const {};
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
    this.dmPrivateKeys = const {},
    this.deviceNameRepaired = true,
  });

  /// Stable device id minted at enroll.
  final String deviceId;

  /// Opaque bearer bound to (userId, deviceId) — never logged.
  final String deviceToken;

  /// The personal network id the server provisioned, when known.
  final String? personalNetworkId;

  /// Base64 X25519 DM private seeds keyed by full agent address. Secret:
  /// this map is serialized only to the platform keychain, never logged.
  final Map<String, String> dmPrivateKeys;

  /// Whether legacy enrollment-name repair has run (or was unnecessary).
  /// Programmatically created credentials are already current; deserialized
  /// legacy JSON explicitly defaults this to false so repair runs once.
  final bool deviceNameRepaired;

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
      dmPrivateKeys: _parseDmPrivateKeys(json['dmPrivateKeys']),
      deviceNameRepaired: json['deviceNameRepaired'] == true,
    );
  }

  /// Serializes to JSON.
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'deviceToken': deviceToken,
    if (personalNetworkId != null) 'personalNetworkId': personalNetworkId,
    if (dmPrivateKeys.isNotEmpty) 'dmPrivateKeys': dmPrivateKeys,
    if (deviceNameRepaired) 'deviceNameRepaired': true,
  };

  /// Returns the same enrollment record with updated DM private keys.
  DeviceCredentials withDmPrivateKeys(Map<String, String> keys) =>
      DeviceCredentials(
        deviceId: deviceId,
        deviceToken: deviceToken,
        personalNetworkId: personalNetworkId,
        dmPrivateKeys: Map.unmodifiable(keys),
        deviceNameRepaired: deviceNameRepaired,
      );

  /// Marks the one-shot legacy name repair complete without rotating keys.
  DeviceCredentials withDeviceNameRepaired() => DeviceCredentials(
    deviceId: deviceId,
    deviceToken: deviceToken,
    personalNetworkId: personalNetworkId,
    dmPrivateKeys: dmPrivateKeys,
    deviceNameRepaired: true,
  );
}

Map<String, String> _parseDmPrivateKeys(Object? value) {
  if (value is! Map) return const {};
  return Map.unmodifiable({
    for (final entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  });
}

/// Persistence seam for [DeviceCredentials]. Production backs it with
/// the platform keychain — the same fa_ui [KeychainStore] storage the
/// wallet uses ([KeychainDeviceTokenStore]); tests inject an in-memory
/// fake.
abstract interface class DeviceTokenStore implements DeviceDmKeyStore {
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
  Future<Map<String, String>> readDmPrivateKeys() async =>
      Map.of((await read())?.dmPrivateKeys ?? const {});

  @override
  Future<void> writeDmPrivateKeys(Map<String, String> keys) async {
    final current = await read();
    if (current == null) throw StateError('device not enrolled');
    await write(current.withDmPrivateKeys(keys));
  }

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
    this.dmSessionHost,
    DeviceTokenStore? tokenStore,
    this.userIdProvider,
    OutboxStore? outbox,
    ConnectorTransport? transport,
    Future<String> Function()? supportDirProvider,
    Future<String> Function()? deviceNameProvider,
    this.deviceNamePrompt,
    this.idFactory = defaultIdFactory,
    this.onLog,
    this.rosterDebounce = const Duration(milliseconds: 500),
    bool? mobileQueueOnly,
  }) : _mobileQueueOnly =
           mobileQueueOnly ??
           (!kIsWeb && (Platform.isAndroid || Platform.isIOS)),
       _tokenStore = tokenStore ?? KeychainDeviceTokenStore(),
       _outboxOverride = outbox,
       _transport = transport ?? const IoConnectorTransport(),
       _deviceNameProvider = deviceNameProvider ?? platformEnrollmentDeviceName,
       _supportDirProvider =
           supportDirProvider ??
           (() async => (await getApplicationSupportDirectory()).path) {
    _chatSessionSource =
        chatSessionSource ?? _NetworkMembershipSessionSource(sessionManager);
    _dmKeys = DeviceDmKeyProvider(_tokenStore);
    sessionManager.addListener(_onManagerChanged);
    _chatSessionSource.changes.addListener(_onChatSessionsChanged);
  }

  /// The session manager — the JWT/session integration point (fresh
  /// clients via [NetworkSessionManager.accountClient], live sessions
  /// via [NetworkSessionManager.sessions]).
  final NetworkSessionManager sessionManager;

  late final DeviceChatSessionSource _chatSessionSource;

  /// Routes inbound viewer turns into the app's real session owner.
  final DeviceDmSessionHost? dmSessionHost;

  /// Supplies the signed-in ai-native user id (test/alternate-auth seam).
  final Future<String> Function()? userIdProvider;
  final DeviceTokenStore _tokenStore;
  late final DeviceDmKeyProvider _dmKeys;
  final _dmPubs = <String, String>{};
  final _remoteDmPubs = <String, ({String network, String dmPub})>{};
  Future<SimpleKeyPair>? _userDmKeyPair;
  String? _accountUserId;
  SinkRegistration? _dmSink;
  final OutboxStore? _outboxOverride;
  final ConnectorTransport _transport;
  final Future<String> Function() _supportDirProvider;
  final Future<String> Function() _deviceNameProvider;

  /// First-enrollment-only friendly-name question. Null keeps non-UI hosts
  /// automatic; a null/blank answer retains the computed hostname default.
  final Future<String?> Function(String defaultName)? deviceNamePrompt;

  /// Delay used to coalesce rapid REST roster changes (test-adjustable).
  final Duration rosterDebounce;

  /// Mobile has no sender-driven headless CLI wake: sleepers stay queue-only
  /// and receive the honest queued receipt instead of a false live delivery.
  final bool _mobileQueueOnly;

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
  var _observedSessionMetadata = <String, DeviceChatSessionMetadata>{};
  var _observedSessionActivity = <String, DeviceChatSessionActivity>{};
  var _observedRetractedSessionIds = <String>{};
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

  /// The current roster run state for [agentAddress] (`name@deviceId`)
  /// in [networkId]'s roster frame, or null when that agent is not
  /// published there. Drives the DM conversation's 'agent is working'
  /// indicator: the owner can see the remote agent pick their message
  /// up (owner feedback). Scoped to the DM channel's network (review
  /// #2197): the same `name@deviceId` can be published in two networks,
  /// and a first-match scan over every cached roster reported the
  /// wrong one.
  AgentRunState? agentRunState(
    String agentAddress, {
    required String networkId,
  }) {
    final separator = agentAddress.lastIndexOf('@');
    if (separator < 1) return null;
    final envelope = _lastRosterByNetwork[networkId];
    if (envelope == null) return null;
    return _rosterAgentState(
      envelope.payload,
      agentAddress.substring(separator + 1),
      agentAddress.substring(0, separator),
    );
  }

  /// One roster envelope's device list → the named agent's run state.
  /// Decomposed from [agentRunState] for the CRAP 12 ratchet (each level
  /// of the nested payload walk is its own small pure function).
  static AgentRunState? _rosterAgentState(
    Map<String, Object?> payload,
    String deviceId,
    String name,
  ) {
    final devices = payload['devices'];
    if (devices is! List) return null;
    for (final device in devices) {
      final state = _deviceAgentState(device, deviceId, name);
      if (state != null) return state;
    }
    return null;
  }

  static AgentRunState? _deviceAgentState(
    Object? device,
    String deviceId,
    String name,
  ) {
    if (device is! Map || device['deviceId'] != deviceId) return null;
    final agents = device['agents'];
    if (agents is! List) return null;
    for (final agent in agents) {
      final state = _exposedAgentState(agent, name);
      if (state != null) return state;
    }
    return null;
  }

  static AgentRunState? _exposedAgentState(Object? agent, String name) {
    if (agent is! Map || agent['exposed'] != true) return null;
    if (agent['name'] != name) return null;
    return AgentRunState.tryParse('${agent['state'] ?? ''}');
  }

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

  /// Sends an already-sealed connector envelope, or seals through
  /// [ciphertextFor] with the exact msgId minted by [MachineConnector].
  /// Outbox retries retain that id and ciphertext byte-for-byte.
  Future<String> sendMail({
    required String network,
    required String channel,
    required String from,
    String? to,
    String? ciphertext,
    FutureOr<String> Function(String frameId)? ciphertextFor,
  }) {
    final connector = _connector;
    if (connector == null) throw StateError('device connector is not running');
    return connector.sendMail(
      network: network,
      channel: channel,
      from: from,
      to: to,
      ciphertext: ciphertext,
      ciphertextFor: ciphertextFor,
    );
  }

  /// Resolves the stable virtual channel for history and send UIs.
  Future<String> dmChannelForAgent({
    required String deviceId,
    required String agentName,
  }) async => dmChannelId(
    await _resolveAccountUserId(),
    agentAddress(agentName, deviceId),
  );

  /// The signed-in account user id (DM sender identity), cached after the
  /// first resolution. Public for the Devices conversation pane.
  Future<String> accountUserId() => _resolveAccountUserId();

  /// The roster-published DM public key for `agentName@deviceId`, or null
  /// when the device has not published one yet. The conversation pane
  /// recomputes the shared key for the USER's OWN history rows with it.
  String? agentDmPub({required String deviceId, required String agentName}) {
    try {
      return _findDmTarget(deviceId, agentName).dmPub;
    } on Object {
      return null;
    }
  }

  /// Sends one E2E user DM to a roster agent. The recipient key is resolved
  /// from the latest cached WS roster by full `agentName@deviceId` address;
  /// [sessionId] rides inside the ciphertext, never in relay-visible fields.
  Future<String> sendDmToAgent({
    required String deviceId,
    required String agentName,
    String? sessionId,
    required String text,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    final target = _findDmTarget(deviceId, agentName);
    final userId = await _resolveAccountUserId();
    final userKeyPair = await _userIdentity();
    final address = agentAddress(agentName, deviceId);
    final channel = dmChannelId(userId, address);
    final plaintext = jsonEncode({
      'text': text,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      // Per-session reply envelopes are opt-in per request: older viewers
      // keep receiving the legacy raw assistant plaintext they understand.
      'threading': 1,
    });
    return sendMail(
      // DM always rides the account-personal network: every device of
      // the account registers its dm-prefix sink there; a shared-network
      // id from the roster frame would demux as unrouted on the target.
      network: _credentials?.personalNetworkId ?? target.network,
      channel: channel,
      from: 'user:$userId',
      to: address,
      ciphertextFor: (frameId) => hubSealFanet1(
        senderDhKeyPair: userKeyPair,
        recipientDhPubkey: SimplePublicKey(
          base64Decode(target.dmPub),
          type: KeyPairType.x25519,
        ),
        frameId: frameId,
        aadTarget: channel,
        plaintext: plaintext,
      ),
    );
  }

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
    try {
      await _markDeviceNameRepaired();
    } on Object catch (error) {
      // The owner rename already succeeded; a keychain flag failure may only
      // cause a later no-op probe, never turn that rename into a UI failure.
      onLog?.call('device name-repair flag was not persisted: $error');
    }
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

  ({String network, String dmPub}) _findDmTarget(
    String deviceId,
    String agentName,
  ) {
    final address = agentAddress(agentName, deviceId);
    final target = _remoteDmPubs[address];
    if (target != null) return target;
    throw StateError(
      'no roster dmPub for $address; wait for the device roster and try again',
    );
  }

  void _cacheRosterDmPubs(NetworkEnvelope envelope) {
    final network = envelope.network;
    final devices = envelope.payload['devices'];
    if (network == null || devices is! List) return;
    for (final rawDevice in devices) {
      if (rawDevice is! Map) continue;
      final device = DeviceInfo.fromJson(rawDevice.cast<String, Object?>());
      for (final entry in device.agentDmPubs.entries) {
        _remoteDmPubs[entry.key] = (network: network, dmPub: entry.value);
      }
    }
  }

  Future<String> _resolveAccountUserId() async {
    final cached = _accountUserId;
    if (cached != null) return cached;
    final provider = userIdProvider;
    late final String userId;
    if (provider != null) {
      userId = await provider();
    } else {
      final jwt = await sessionManager.ensureFreshJwt();
      final client = await sessionManager.accountClient();
      if (jwt == null || client == null) throw StateError('not signed in');
      userId = (await client.authUser(jwt)).id;
    }
    if (userId.isEmpty) throw StateError('signed-in account has no user id');
    _accountUserId = userId;
    return userId;
  }

  Future<SimpleKeyPair> _userIdentity() async {
    final pending = _userDmKeyPair ??= () async {
      final wallet = sessionManager.wallet;
      if (!wallet.hasIdentity) await wallet.createIfMissing();
      return wallet.identityKeyPair();
    }();
    try {
      return await pending;
    } on Object {
      if (identical(_userDmKeyPair, pending)) _userDmKeyPair = null;
      rethrow;
    }
  }

  /// True only for DM mail addressed TO this device's agent by someone
  /// else — the one shape that may wake a session and auto-reply. Own
  /// reply echoes and other agents' mail are acked and dropped.
  bool _isActionableDm(NetworkEnvelope envelope) {
    final local = _localAgentAddress();
    return envelope.to == local && envelope.from != local;
  }

  /// Live user-side DM mail from the device WS (own agent-echo excluded):
  /// the personal-network [NetworkSession] folds these into its open DM
  /// channel stores so NetworkChatPage updates in place.
  Stream<NetworkEnvelope> get dmMail => _dmMailController.stream;
  final _dmMailController = StreamController<NetworkEnvelope>.broadcast();

  /// Decodes agent-bound writes with the enrolled agent key, and user-bound
  /// replies with the account wallet. The backend rewrites a CLI reply's
  /// sender to the same account uid as its recipient; direction (`to`) is
  /// therefore the reliable distinction, not `from == to` or the sender id.
  Future<DecodedMail> _decodeDmMail(
    DeviceDmCodec agentCodec,
    NetworkEnvelope envelope,
  ) async {
    final parts = parseDeviceDmChannelId(envelope.channel ?? '');
    final recipient = envelope.to ?? '';
    final userRecipient = parts == null ? '' : 'user:${parts.userId}';
    if (parts == null ||
        (recipient != parts.userId && recipient != userRecipient)) {
      return agentCodec.decode(envelope);
    }

    final ciphertext = envelope.ciphertext ?? '';
    final frame = hubTryOpenFanet1(ciphertext);
    if (frame == null) {
      throw const MailDecodeException('DM payload is not valid fanet1');
    }
    // Wallet/keychain failures are transient: propagate them so the original
    // frame remains unacked, matching DeviceDmCodec's key-provider contract.
    final userKeyPair = await _userIdentity();
    try {
      final plaintext = await hubDecryptPayloadWithKeyPair(
        recipientDhKeyPair: userKeyPair,
        senderDhPubkey: frame.senderPubkey,
        frameId: envelope.msgId,
        aadTarget: envelope.channel!,
        ciphertextB64: frame.ciphertextB64,
      );
      final unwrapped = unwrapDeviceDmText(plaintext);
      return DecodedMail(
        payload: plaintext,
        sessionId: unwrapped.sessionId,
        senderPubkey: base64Encode(frame.senderPubkey.bytes),
        threaded: unwrapped.threaded,
      );
    } on Object {
      throw const MailDecodeException(
        'DM fanet1 authentication/decryption failed',
      );
    }
  }

  Future<void> _onDmSink(InboundMail mail) async {
    final envelope = mail.envelope;
    if (envelope.from != _localAgentAddress()) {
      _dmMailController.add(envelope);
    }
    await _receiveDm(mail);
  }

  Future<void> _receiveDm(InboundMail mail) async {
    if (!_isActionableDm(mail.envelope)) return;
    final targetLive = mail.sessionId == null
        ? _observedSessions.values.any((session) => session.live)
        : _observedSessions[mail.sessionId]?.live == true;
    if (_mobileQueueOnly && !targetLive) {
      await _replyToDm(mail, deviceDmQueuedReceipt);
      throw StateError('mobile DM queued for a non-live session; left unacked');
    }
    final host = dmSessionHost;
    if (host == null) throw StateError('no DM session host configured');
    final envelope = mail.envelope;
    final reply = await host.deliverUserText(
      sessionId: mail.sessionId,
      text: mail.text,
    );
    // e2e diagnostics (issue #2062): the reply path is otherwise silent.
    if (kDebugMode) {
      debugPrint('[dm] inbound ${envelope.msgId} reply=${reply?.length}');
    }
    if (reply == null || reply.trim().isEmpty) return;
    await _replyToDm(mail, reply);
  }

  Future<void> _replyToDm(InboundMail mail, String reply) async {
    final connector = _connector;
    if (connector == null) throw StateError('device connector is not running');
    final route = DeviceDmReplyRoute.fromMail(
      mail,
      currentAgentAddress: _localAgentAddress(),
    );
    try {
      await sendDeviceDmReply(
        connector: connector,
        keys: _dmKeys,
        route: route,
        reply: reply,
      );
      if (kDebugMode) {
        debugPrint(
          '[dm] reply sent network=${route.network} channel=${route.channel} '
          'to=${route.replyRecipient}',
        );
      }
    } on Object catch (error) {
      debugPrint('[dm] reply send failed: $error');
      rethrow;
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
    final credentials = await _resolveCredentials();
    _credentials = credentials;
    if (generation != _generation) return;
    await _repairLegacyDeviceName(generation);
    if (generation != _generation) return;
    final localAddress = _localAgentAddress();
    final dmKey = await _dmKeys.loadOrCreate(localAddress);
    if (generation != _generation) return;
    _dmPubs[localAddress] = dmKey.publicKey;

    final registry = DeviceRegistry();
    final personal = credentials.personalNetworkId ?? 'personal';
    registry.configureNetwork(personal, NetworkKind.personal);
    final snapshot = await _currentChatSessions();
    if (generation != _generation) {
      registry.dispose();
      return;
    }
    _observedSessionMetadata = snapshot.metadata;
    _observedSessionActivity = snapshot.activity;
    _observedRetractedSessionIds = snapshot.retractedSessionIds;
    _registerLiveSessions(registry, snapshot.sessions);
    _observedSessions = snapshot.sessions;

    final upstream = ConnectorUpstreamClient(
      url: _deviceWsUrl(),
      transport: _transport,
      ticketProvider: () => _mintTicket(),
      deviceId: credentials.deviceId,
      deviceToken: credentials.deviceToken,
      idFactory: idFactory,
      onLog: onLog,
    );
    final presence = PresenceEngine(
      clock: const SystemClock(),
      timers: const SystemTimers(),
      idFactory: idFactory,
    );
    presence.sessionMetadata = () => {
      for (final entry in _observedSessions.entries)
        if (_observedSessionMetadata[entry.key] != null)
          entry.key: _presenceMetadata(_observedSessionMetadata[entry.key]!),
    };
    presence.setAgentState(
      localAddress,
      _agentPresenceState(snapshot.sessions, snapshot.activity),
    );
    final dmCodec = DeviceDmCodec(
      keys: _dmKeys,
      deviceId: credentials.deviceId,
    );
    final connector = MachineConnector(
      registry: registry,
      upstream: upstream,
      outbox: _outboxOverride ?? await _defaultOutbox(),
      presence: presence,
      leases: () async => sessionManager.sessions.keys.toSet(),
      decodeMail: (envelope) => _decodeDmMail(dmCodec, envelope),
      idFactory: idFactory,
      onLog: onLog,
    );
    // Presence heartbeats and REST patches share the complete persisted
    // catalog. Registry membership still identifies loaded sessions for DM
    // routing, while these delegates expose every row and mark only loaded
    // ones live (never clobbering sleepers with a live-only heartbeat).
    connector.presence.exposedSessions = () => _observedSessions.keys.toSet();
    connector.presence.liveLeases = () => {
      for (final entry in _observedSessions.entries)
        if (entry.value.live) entry.key,
    };
    final dmSink = connector.registerLocalSink(
      network: personal,
      // Catch-all dm-prefix route: actionable mail is filtered inside
      // the sink (to == local agent, from != local agent); user-side
      // echoes and other agents' traffic are acked and dropped so the
      // server never redelivers them.
      channel: dmChannelPrefix,
      sink: _onDmSink,
    );
    if (generation != _generation) {
      unawaited(connector.stop());
      connector.dispose();
      registry.dispose();
      return;
    }
    _registry = registry;
    _connector = connector;
    _dmSink = dmSink;
    _wireForwarding(connector, generation);
    await connector.start();
    if (generation != _generation) return;
    _running = true;
  }

  void _registerLiveSessions(
    DeviceRegistry registry,
    Map<String, DeviceChatSession> sessions,
  ) {
    for (final session in sessions.values) {
      if (session.live) registry.registerSession(_registrationFor(session));
    }
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
    final computedName = await _computedDeviceName();
    var enrollmentName = computedName;
    final prompted = await deviceNamePrompt?.call(computedName);
    if (prompted != null && prompted.trim().isNotEmpty) {
      enrollmentName = prompted.trim();
    }
    if (enrollmentName.runes.length > 64) {
      throw StateError('device name must contain at most 64 characters');
    }
    final enrollment = await client.enrollDevice(
      name: enrollmentName,
      platform: Platform.operatingSystem,
    );
    final credentials = DeviceCredentials(
      deviceId: enrollment.deviceId,
      deviceToken: enrollment.deviceToken,
      personalNetworkId: enrollment.personalNetworkId,
    );
    await _tokenStore.write(credentials);
    onLog?.call('device enrolled (${credentials.deviceId})');
    return credentials;
  }

  Future<String> _computedDeviceName() async {
    String? name;
    try {
      name = (await _deviceNameProvider()).trim();
    } on Object catch (error) {
      onLog?.call('device name probe failed: $error');
    }
    if (!isGenericDeviceName(name)) return name!;
    // Even a broken host/provider must never put an empty/localhost label on
    // a new enrollment. This last pure fallback is always non-generic.
    return enrollmentDeviceName(
      operatingSystem: Platform.operatingSystem,
      user: Platform.environment['USER'] ?? Platform.environment['USERNAME'],
    );
  }

  /// One-shot migration for enrollments created before name validation.
  /// The server's device-name PATCH stores a friendly label; that label is
  /// also the physical-machine grouping key, so the repaired app enrollment
  /// unions with a same-host CLI enrollment instead of duplicating the card.
  Future<void> _repairLegacyDeviceName(int generation) async {
    final credentials = _credentials;
    if (credentials == null || credentials.deviceNameRepaired) return;
    try {
      final client = await sessionManager.accountClient();
      if (client == null) return;
      final devices = await client.listDevices();
      if (generation != _generation) return;
      final own = _findOwnDevice(devices, credentials.deviceId);
      if (own == null) return;
      _setOwnDevice(own);
      if (_hasUsableDeviceName(own)) {
        await _markDeviceNameRepaired();
        return;
      }
      final computed = await _computedDeviceName();
      if (generation != _generation || isGenericDeviceName(computed)) return;
      final renamed = await client.renameDevice(own.deviceId, computed);
      if (generation != _generation) return;
      _setOwnDevice(_renamedOwnDevice(own, renamed));
      await _markDeviceNameRepaired();
      onLog?.call('legacy device name repaired (${own.deviceId})');
    } on Object catch (error) {
      // Repair is additive and best-effort: connectivity/keychain failures
      // leave the flag clear for the next start and never block the connector.
      onLog?.call('legacy device name repair skipped: $error');
    }
  }

  DeviceInfo? _findOwnDevice(List<DeviceInfo> devices, String deviceId) {
    for (final device in devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  bool _hasUsableDeviceName(DeviceInfo device) {
    final hasOwnerLabel = device.friendlyName?.trim().isNotEmpty == true;
    return hasOwnerLabel || !isGenericDeviceName(device.name);
  }

  DeviceInfo _renamedOwnDevice(DeviceInfo device, DeviceRenameResult renamed) =>
      DeviceInfo(
        deviceId: device.deviceId,
        name: device.name,
        friendlyName: renamed.friendlyName.isEmpty
            ? null
            : renamed.friendlyName,
        createdAt: device.createdAt,
        revokedAt: device.revokedAt,
        presence: device.presence,
        userId: device.userId,
        agentDmPubs: device.agentDmPubs,
      );

  Future<void> _markDeviceNameRepaired() async {
    final credentials = _credentials;
    if (credentials == null || credentials.deviceNameRepaired) return;
    final repaired = credentials.withDeviceNameRepaired();
    await _tokenStore.write(repaired);
    _credentials = repaired;
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
        _cacheRosterDmPubs(envelope);
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

  Future<_ChatSessionSnapshot> _currentChatSessions() async {
    try {
      final sessions = await _chatSessionSource.load();
      var metadata = _observedSessionMetadata;
      var activity = _observedSessionActivity;
      var retractedSessionIds = _observedRetractedSessionIds;
      final source = _chatSessionSource;
      if (source is DeviceChatSessionRetractionSource) {
        try {
          retractedSessionIds =
              await (source as DeviceChatSessionRetractionSource)
                  .loadRetractedSessionIds();
        } on Object catch (error) {
          // Cleanup is additive; a failed legacy scan cannot hide parent rows.
          onLog?.call('device chat-session retraction scan failed: $error');
        }
      }
      if (source is DeviceChatSessionMetadataSource) {
        try {
          final rows = await (source as DeviceChatSessionMetadataSource)
              .loadMetadata();
          metadata = {for (final row in rows) row.id: row};
        } on Object catch (error) {
          // Metadata is additive: a title/path probe must never take the
          // underlying persisted session ids out of the roster.
          onLog?.call('device chat-session metadata failed: $error');
        }
      }
      if (source is DeviceChatSessionActivitySource) {
        try {
          final rows = await (source as DeviceChatSessionActivitySource)
              .loadActivity();
          activity = {for (final row in rows) row.id: row};
        } on Object catch (error) {
          // Run state is additive too: an activity probe cannot retract chats.
          onLog?.call('device chat-session activity failed: $error');
        }
      }
      return (
        sessions: {for (final session in sessions) session.id: session},
        metadata: metadata,
        activity: activity,
        retractedSessionIds: retractedSessionIds.difference(
          sessions.map((session) => session.id).toSet(),
        ),
      );
    } on Object catch (error) {
      onLog?.call('device chat-session projection failed: $error');
      return (
        sessions: _observedSessions,
        metadata: _observedSessionMetadata,
        activity: _observedSessionActivity,
        retractedSessionIds: _observedRetractedSessionIds,
      );
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
    _observedSessionMetadata = current.metadata;
    _observedSessionActivity = current.activity;
    _observedRetractedSessionIds = current.retractedSessionIds;
    _syncRegistrySessions(_observedSessions, current.sessions);
    _observedSessions = current.sessions;
    _connector?.presence.setAgentState(
      _localAgentAddress(),
      _agentPresenceState(current.sessions, current.activity),
    );
    _connector?.presence.publishNow();
    _rosterActive = true;
    _queueRoster(
      _buildRosterProjection(
        sessions: current.sessions.values,
        metadata: current.metadata,
        retractedSessionIds: current.retractedSessionIds,
        agentState: _agentRosterState(current.sessions, current.activity),
      ),
    );
  }

  /// Turns source notifications into minimal merge patches. A live→asleep
  /// transition keeps the persisted row wake-on-DM; a deleted id is projected
  /// from the previous snapshot with an empty exposure list for retraction.
  Future<void> _syncRosterSessions() async {
    if (!_rosterActive) return;
    final revision = ++_sessionProjectionRevision;
    final previous = _observedSessions;
    final previousMetadata = _observedSessionMetadata;
    final previousActivity = _observedSessionActivity;
    final previousRetractedIds = _observedRetractedSessionIds;
    final current = await _currentChatSessions();
    if (!_rosterActive || revision != _sessionProjectionRevision) return;
    if (_sameChatSessions(previous, current.sessions) &&
        _sameSessionMetadata(previousMetadata, current.metadata) &&
        _sameSessionActivity(previousActivity, current.activity) &&
        _sameStringSets(previousRetractedIds, current.retractedSessionIds)) {
      return;
    }
    _observedSessionMetadata = current.metadata;
    _observedSessionActivity = current.activity;
    _observedRetractedSessionIds = current.retractedSessionIds;
    _syncRegistrySessions(previous, current.sessions);
    _observedSessions = current.sessions;
    _connector?.presence.setAgentState(
      _localAgentAddress(),
      _agentPresenceState(current.sessions, current.activity),
    );
    _connector?.presence.publishNow();
    _queueChangedRosterSessions(
      previous,
      previousMetadata,
      previousActivity,
      current.sessions,
      current.metadata,
      current.activity,
    );
    _queueClosedRosterSessions(
      previous,
      previousMetadata,
      previousActivity,
      current.sessions,
      current.activity,
    );
    final newRetractions = current.retractedSessionIds.difference(
      previousRetractedIds,
    );
    if (newRetractions.isNotEmpty) {
      _queueRoster((
        agents: const [],
        sessions: [
          for (final id in newRetractions)
            DeviceRosterSession(id: id, state: 'offline', networks: const []),
        ],
      ));
    }
  }

  void _queueChangedRosterSessions(
    Map<String, DeviceChatSession> previous,
    Map<String, DeviceChatSessionMetadata> previousMetadata,
    Map<String, DeviceChatSessionActivity> previousActivity,
    Map<String, DeviceChatSession> current,
    Map<String, DeviceChatSessionMetadata> currentMetadata,
    Map<String, DeviceChatSessionActivity> currentActivity,
  ) {
    final changed = [
      for (final entry in current.entries)
        if (previous[entry.key] != entry.value ||
            previousMetadata[entry.key] != currentMetadata[entry.key] ||
            previousActivity[entry.key] != currentActivity[entry.key])
          entry.value,
    ];
    if (changed.isEmpty) return;
    final liveStateChanged = changed.any(
      (session) => previous[session.id]?.live != session.live,
    );
    final hasLive = current.values.any((session) => session.live);
    final activityChanged = changed.any(
      (session) => previousActivity[session.id] != currentActivity[session.id],
    );
    _queueRoster(
      _buildRosterProjection(
        sessions: changed,
        metadata: currentMetadata,
        agentState: _agentRosterState(current, currentActivity),
        includeAgents:
            changed.any((session) => session.live) ||
            activityChanged ||
            (liveStateChanged && !hasLive),
      ),
    );
  }

  void _queueClosedRosterSessions(
    Map<String, DeviceChatSession> previous,
    Map<String, DeviceChatSessionMetadata> previousMetadata,
    Map<String, DeviceChatSessionActivity> previousActivity,
    Map<String, DeviceChatSession> current,
    Map<String, DeviceChatSessionActivity> currentActivity,
  ) {
    final closed = [
      for (final entry in previous.entries)
        if (!current.containsKey(entry.key)) entry.value,
    ];
    if (closed.isEmpty) return;
    final currentAgentState = _agentRosterState(current, currentActivity);
    final busyChanged =
        _hasBusySession(previous, previousActivity) !=
        _hasBusySession(current, currentActivity);
    _queueRoster(
      _buildRosterProjection(
        sessions: closed,
        metadata: previousMetadata,
        sessionState: 'offline',
        agentState: currentAgentState,
        includeAgents: busyChanged,
        exposeSessions: false,
      ),
    );
  }

  bool _sameStringSets(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

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

  bool _sameSessionMetadata(
    Map<String, DeviceChatSessionMetadata> left,
    Map<String, DeviceChatSessionMetadata> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool _sameSessionActivity(
    Map<String, DeviceChatSessionActivity> left,
    Map<String, DeviceChatSessionActivity> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool _hasBusySession(
    Map<String, DeviceChatSession> sessions,
    Map<String, DeviceChatSessionActivity> activity,
  ) => sessions.values.any(
    (session) => session.live && activity[session.id]?.busy == true,
  );

  String _agentRosterState(
    Map<String, DeviceChatSession> sessions,
    Map<String, DeviceChatSessionActivity> activity,
  ) {
    if (_hasBusySession(sessions, activity)) return 'busy';
    return sessions.values.any((session) => session.live)
        ? 'live'
        : 'wake_on_dm';
  }

  AgentRunState _agentPresenceState(
    Map<String, DeviceChatSession> sessions,
    Map<String, DeviceChatSessionActivity> activity,
  ) {
    if (_hasBusySession(sessions, activity)) return AgentRunState.busy;
    // The connector's DM host remains reachable even with no chat rows;
    // empty/wake-on-DM is still an idle live agent, never device-offline.
    return AgentRunState.live;
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
    Map<String, DeviceChatSessionMetadata> metadata = const {},
    Set<String> retractedSessionIds = const {},
    String? sessionState,
    required String agentState,
    bool includeAgents = true,
    bool exposeSessions = true,
    Iterable<String> extraAgentNames = const [],
  }) {
    final projected = sessions.toList(growable: false);
    final catalog = normalizeSessionCatalog([
      for (final session in projected)
        SessionCatalogEntry(
          id: session.id,
          live: session.live,
          title: metadata[session.id]?.title,
          snippet: metadata[session.id]?.snippet,
          cwd: metadata[session.id]?.path ?? '',
          lastActiveAt:
              metadata[session.id]?.lastActivity ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
    ]);
    final projectedIds = projected.map((session) => session.id).toSet();
    final retracted =
        retractedSessionIds
            .where((id) => id.trim().isNotEmpty && !projectedIds.contains(id))
            .toList()
          ..sort();
    final agentNames = includeAgents
        ? <String>{...extraAgentNames, ..._registeredAgentNames(projected)}
        : <String>{};
    final networkId = personalNetworkId;
    final deviceId = _credentials?.deviceId ?? 'local';
    final networks = [
      if (exposeSessions && networkId != null && networkId.isNotEmpty)
        networkId,
    ];
    return (
      agents: [
        for (final name in agentNames)
          DeviceRosterAgent(
            name: name,
            state: agentState,
            exposed: agentState != 'offline',
            dmPub: _dmPubs[agentAddress(name, deviceId)],
          ),
      ],
      sessions: [
        for (final session in catalog)
          DeviceRosterSession(
            id: session.id,
            state: sessionState ?? (session.live ? 'live' : 'wake_on_dm'),
            networks: networks,
            title: metadata.containsKey(session.id)
                ? session.displayName
                : null,
            snippet: session.snippet,
            path: session.cwd.isEmpty ? null : session.cwd,
            cwd: session.cwdSlug,
            // Preserve legacy id-only rows: the epoch is a sorting sentinel,
            // not a fabricated activity timestamp to put on the wire.
            lastActivity: metadata[session.id]?.lastActivity
                ?.toUtc()
                .toIso8601String(),
          ),
        for (final id in retracted)
          DeviceRosterSession(id: id, state: 'offline', networks: const []),
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
    // Hundreds of persisted chats (plus title/path metadata) exceed the
    // deployed roster-patch limit. Publish the COMPLETE projection in small
    // sequential merge patches rather than truncating it to a live/recent
    // subset; agents ride only the first request.
    const batchSize = sessionCatalogRosterPageSize;
    if (sessions.isEmpty) {
      _rosterWrites = _rosterWrites.then(
        (_) => _writeRoster(deviceId, agents, const []),
      );
      return;
    }
    for (var start = 0; start < sessions.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, sessions.length);
      final batch = sessions.sublist(start, end);
      _rosterWrites = _rosterWrites.then(
        (_) => _writeRoster(deviceId, start == 0 ? agents : const [], batch),
      );
    }
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
        metadata: _observedSessionMetadata,
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
    _remoteDmPubs.clear();
    _accountUserId = null;
    _userDmKeyPair = null;
    _dmSink?.close();
    _dmSink = null;
    _sessionProjectionRevision++;
    _rosterTimer?.cancel();
    _rosterTimer = null;
    _pendingRosterAgents.clear();
    _pendingRosterSessions.clear();
    _observedSessions = {};
    _observedSessionMetadata = {};
    _observedSessionActivity = {};
    _observedRetractedSessionIds = {};
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
