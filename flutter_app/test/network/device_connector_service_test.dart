// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// DeviceConnectorService lifecycle tests (issue #2062 chunk 14): fakes
/// for the transport and the REST client — NO real sockets, NO
/// path_provider (the outbox is injected). Covers start/stop/restart
/// idempotence, enrollment persistence (skip re-enroll), the WS ticket
/// wiring, the roster/presence/wake passthrough streams, the phase
/// mapping and the sign-out auto-stop.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/device_dm_session_host.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_agent_harness/src/network/connector/device_registry.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/offline_outbox.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _enrollBody =
    '{"deviceId":"dev-1","deviceToken":"dt-secret",'
    '"personalNetwork":{"id":"net-personal"}}';

/// The in-memory device token store (test stand-in for the keychain).
final class MemoryDeviceTokenStore implements DeviceTokenStore {
  DeviceCredentials? stored;
  var writes = 0;

  @override
  Future<DeviceCredentials?> read() async => stored;

  @override
  Future<void> write(DeviceCredentials credentials) async {
    stored = credentials;
    writes++;
  }

  @override
  Future<Map<String, String>> readDmPrivateKeys() async =>
      Map.of(stored?.dmPrivateKeys ?? const {});

  @override
  Future<void> writeDmPrivateKeys(Map<String, String> keys) async {
    final current = stored;
    if (current == null) throw StateError('device not enrolled');
    await write(current.withDmPrivateKeys(keys));
  }

  @override
  Future<void> clear() async {
    stored = null;
  }
}

/// A fake upstream socket: auto-answers hello_ok for the handshake,
/// hands the test [serverSends] for passthrough assertions.
final class FakeUpstreamSocket implements ConnectorSocket {
  final _frames = StreamController<NetworkEnvelope>.broadcast();
  final sent = <NetworkEnvelope>[];
  var closed = false;

  @override
  Stream<NetworkEnvelope> get frames => _frames.stream;

  @override
  bool get isOpen => !closed;

  @override
  Future<void> send(NetworkEnvelope envelope) async {
    if (closed) throw StateError('socket closed');
    sent.add(envelope);
    if (envelope.kind == NetworkEnvelopeKind.hello) {
      _frames.add(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.helloOk,
          msgId: 'ok-${sent.length}',
          refId: envelope.msgId,
          ts: rfc3339Timestamp(DateTime.now().toUtc()),
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _frames.close();
  }

  void serverSends(NetworkEnvelope envelope) => _frames.add(envelope);
}

/// The fake transport: records dials and hands back fresh sockets.
final class FakeTransport implements ConnectorTransport {
  final dials = <({Uri url, String ticket})>[];
  final sockets = <FakeUpstreamSocket>[];

  @override
  Future<ConnectorSocket> dial(Uri url, String ticket) async {
    final socket = FakeUpstreamSocket();
    dials.add((url: url, ticket: ticket));
    sockets.add(socket);
    return socket;
  }
}

Future<NetworkSessionManager> _manager({
  required FakeHttpClient httpClient,
  String? jwt,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: await KeyWallet.load(MemoryWalletBackend()),
  httpClient: httpClient,
  jwtToken: jwt,
);

/// Builds the service with every seam faked (the outbox is always
/// injected — the default would touch path_provider).
Future<
  (
    DeviceConnectorService,
    NetworkSessionManager,
    FakeHttpClient,
    FakeTransport,
    MemoryDeviceTokenStore,
  )
>
buildService({
  String? jwt = 'jwt-1',
  required FakeHttpClient httpClient,
  FakeTransport? transport,
  MemoryDeviceTokenStore? tokenStore,
  OutboxStore? outbox,
  DeviceChatSessionSource? chatSessionSource,
  DeviceDmSessionHost? dmSessionHost,
  Future<String> Function()? userIdProvider,
  IdFactory idFactory = defaultIdFactory,
  Duration rosterDebounce = const Duration(milliseconds: 500),
}) async {
  final manager = await _manager(httpClient: httpClient, jwt: jwt);
  final usedTransport = transport ?? FakeTransport();
  final usedTokens = tokenStore ?? MemoryDeviceTokenStore();
  final service = DeviceConnectorService(
    sessionManager: manager,
    tokenStore: usedTokens,
    transport: usedTransport,
    outbox: outbox ?? MemoryOutboxStore(),
    chatSessionSource: chatSessionSource,
    dmSessionHost: dmSessionHost,
    userIdProvider: userIdProvider,
    idFactory: idFactory,
    rosterDebounce: rosterDebounce,
  );
  return (service, manager, httpClient, usedTransport, usedTokens);
}

Future<void> pumpUntilOnline(DeviceConnectorService service) => service
    .phaseStream
    .firstWhere((phase) => phase == DeviceConnectorPhase.online)
    .timeout(const Duration(seconds: 5));

MemoryDeviceTokenStore enrolledTokens() => MemoryDeviceTokenStore()
  ..stored = const DeviceCredentials(
    deviceId: 'dev-1',
    deviceToken: 'dt-secret',
    personalNetworkId: 'net-personal',
  );

void putSession(
  NetworkSessionManager manager,
  FakeHttpClient httpClient,
  String id, {
  bool notify = true,
}) {
  manager.sessions[id] = buildSession(
    httpClient: httpClient,
    connector: FakeWsConnector(),
    wallet: manager.wallet,
  );
  if (notify) manager.notifyListeners();
}

final class FakeChatSessionSource extends ChangeNotifier
    implements DeviceChatSessionSource, DeviceChatSessionMetadataSource {
  FakeChatSessionSource([Iterable<DeviceChatSession> initial = const []])
    : snapshot = List.of(initial);

  List<DeviceChatSession> snapshot;
  List<DeviceChatSessionMetadata> metadata = const [];
  var loads = 0;

  @override
  Listenable get changes => this;

  @override
  Future<List<DeviceChatSession>> load() async {
    loads++;
    return List.of(snapshot);
  }

  @override
  Future<List<DeviceChatSessionMetadata>> loadMetadata() async =>
      List.of(metadata);

  void replaceMetadata(Iterable<DeviceChatSessionMetadata> rows) {
    metadata = List.of(rows);
    notifyListeners();
  }

  void replace(Iterable<DeviceChatSession> sessions) {
    snapshot = List.of(sessions);
    notifyListeners();
  }
}

List<Map<String, Object?>> rosterPatches(FakeHttpClient httpClient) =>
    httpClient.requests
        .where((request) => request.url.path == '/api/devices/dev-1/roster')
        .map(
          (request) =>
              (jsonDecode(request.body) as Map).cast<String, Object?>(),
        )
        .toList();

Map<String, Object?> agentPatch(String state, bool exposed) => {
  'name': 'fa',
  'state': state,
  'exposed': exposed,
  'dmPub': isA<String>(),
};

void main() {
  late FakeHttpClient httpClient;
  setUp(() {
    httpClient = FakeHttpClient()
      ..respond(200, body: _enrollBody)
      ..respond(200, body: '{"ticket":"tk-1"}')
      ..respond(200, body: '{"ticket":"tk-2"}');
  });

  test('signed-out start is a silent no-op', () async {
    final (service, _, http, transport, _) = await buildService(
      jwt: null,
      httpClient: httpClient,
    );
    addTearDown(service.dispose);

    await service.start();

    expect(service.phase, DeviceConnectorPhase.signedOut);
    expect(service.isRunning, isFalse);
    expect(service.connector, isNull);
    expect(transport.dials, isEmpty);
    expect(
      http.requests.where((r) => r.url.path == '/api/devices/enroll'),
      isEmpty,
    );
  });

  test('start enrolls, persists credentials, dials with the ticket and '
      'reaches online', () async {
    final (service, manager, http, transport, tokens) = await buildService(
      httpClient: httpClient,
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);

    // Enrollment: management route with the JWT bearer.
    final enroll = http.requests.singleWhere(
      (r) => r.url.path == '/api/devices/enroll',
    );
    expect(enroll.method, 'POST');
    expect(enroll.headers['authorization'], 'Bearer jwt-1');
    final enrollmentBody = jsonDecode(enroll.body) as Map<String, Object?>;
    expect(enrollmentBody['name'], isNotEmpty);
    expect(enrollmentBody['platform'], isNotEmpty);

    // Credentials persisted from the response.
    expect(tokens.stored?.deviceId, 'dev-1');
    expect(tokens.stored?.deviceToken, 'dt-secret');
    expect(tokens.stored?.personalNetworkId, 'net-personal');

    // One dial: /ws with the minted single-use ticket.
    expect(transport.dials, hasLength(1));
    expect(
      transport.dials.first.url.scheme,
      testBase.scheme == 'http' ? 'ws' : 'wss',
    );
    expect(transport.dials.first.url.path, '/ws');
    expect(transport.dials.first.url.queryParameters['ticket'], 'tk-1');
    expect(transport.dials.first.ticket, 'tk-1');

    // The hello carried the enrolled deviceId.
    final hello = transport.sockets.first.sent.firstWhere(
      (e) => e.kind == NetworkEnvelopeKind.hello,
    );
    expect(hello.payload['deviceId'], 'dev-1');

    expect(service.phase, DeviceConnectorPhase.online);
    expect(service.isRunning, isTrue);
    expect(service.connector, isNotNull);
    expect(service.deviceId, 'dev-1');
    // The personal network is registered personal (exposure opt-out).
    expect(
      service.connector!.registry.kindOf('net-personal'),
      NetworkKind.personal,
    );
    // The manager is untouched as the integration point.
    expect(manager.hasJwt, isTrue);
  });

  test('roster/presence/wake_hint frames pass through to the service '
      'streams', () async {
    final (service, _, _, transport, _) = await buildService(
      httpClient: httpClient,
    );
    addTearDown(service.dispose);

    final rosters = <NetworkEnvelope>[];
    final presences = <NetworkEnvelope>[];
    final wakes = <NetworkEnvelope>[];
    service.rosterFrames.listen(rosters.add);
    service.presenceFrames.listen(presences.add);
    service.wakeHints.listen(wakes.add);

    await service.start();
    await pumpUntilOnline(service);

    transport.sockets.first
      ..serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.roster,
          msgId: 'r-1',
          ts: rfc3339Timestamp(DateTime.now().toUtc()),
          payload: {'networks': const <Object?>[]},
        ),
      )
      ..serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.presence,
          msgId: 'p-1',
          ts: rfc3339Timestamp(DateTime.now().toUtc()),
          payload: {'machine': 'online'},
        ),
      )
      ..serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.wakeHint,
          msgId: 'w-1',
          ts: rfc3339Timestamp(DateTime.now().toUtc()),
          payload: {'type': 'extension'},
        ),
      );
    await Future<void>.delayed(Duration.zero);

    expect(rosters.map((e) => e.msgId), ['r-1']);
    expect(presences.map((e) => e.msgId), ['p-1']);
    expect(wakes.map((e) => e.msgId), ['w-1']);
  });

  test(
    'start is idempotent: two calls share one enrollment and one dial',
    () async {
      final (service, _, http, transport, _) = await buildService(
        httpClient: httpClient,
      );
      addTearDown(service.dispose);

      await Future.wait([service.start(), service.start()]);
      await pumpUntilOnline(service);

      expect(
        http.requests.where((r) => r.url.path == '/api/devices/enroll'),
        hasLength(1),
      );
      expect(transport.dials, hasLength(1));
    },
  );

  test('stop then restart skips re-enroll (valid token exists) and dials '
      'fresh', () async {
    final (service, _, http, transport, tokens) = await buildService(
      httpClient: httpClient,
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);
    await service.stop();

    expect(service.isRunning, isFalse);
    expect(service.connector, isNull);
    expect(service.phase, DeviceConnectorPhase.signedOut);

    await service.start();
    await pumpUntilOnline(service);

    expect(
      http.requests.where((r) => r.url.path == '/api/devices/enroll'),
      hasLength(1),
      reason: 'the persisted credentials skip a second enrollment',
    );
    expect(tokens.writes, 2); // enrollment + first DM key provisioning
    expect(transport.dials, hasLength(2));
    expect(transport.dials.last.url.queryParameters['ticket'], 'tk-2');
    expect(service.phase, DeviceConnectorPhase.online);
  });

  test('sign-out stops the service', () async {
    final (service, manager, _, transport, _) = await buildService(
      httpClient: httpClient,
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);
    expect(service.isRunning, isTrue);

    await manager.signOut();
    await Future<void>.delayed(Duration.zero);

    expect(service.isRunning, isFalse);
    expect(service.phase, DeviceConnectorPhase.signedOut);
    expect(transport.sockets.first.closed, isTrue);
  });

  test('renameOwnDevice updates the label, empty clears it, and refresh '
      'restores the account roster name', () async {
    final http = FakeHttpClient()
      ..respond(200, body: _enrollBody)
      ..respond(200, body: '{"ticket":"tk-rename"}');
    final (service, _, _, _, _) = await buildService(httpClient: http);
    addTearDown(service.dispose);
    await service.start();
    await pumpUntilOnline(service);
    final labels = <String?>[];
    final subscription = service.ownDeviceStream.listen(
      (device) => labels.add(device?.friendlyName),
    );
    addTearDown(subscription.cancel);

    http.respond(200, body: '{"deviceId":"dev-1","friendlyName":"Studio"}');
    expect(await service.renameOwnDevice('Studio'), 'Studio');
    expect(service.ownFriendlyName, 'Studio');
    expect(service.ownDevice?.deviceId, 'dev-1');
    final rename = http.requests.last;
    expect(rename.method, 'PATCH');
    expect(rename.url.path, '/api/devices/dev-1/name');
    expect(rename.headers['authorization'], 'Bearer jwt-1');
    expect(jsonDecode(rename.body), {'name': 'Studio'});

    http.respond(200, body: '{"deviceId":"dev-1","friendlyName":""}');
    expect(await service.renameOwnDevice(''), isNull);
    expect(service.ownFriendlyName, isNull);
    expect(jsonDecode(http.requests.last.body), {'name': ''});

    http.respond(
      200,
      body:
          '{"devices":[{"deviceId":"dev-1","name":"MacBook",'
          '"friendlyName":"Restored",'
          '"createdAt":"2026-01-02T03:04:05Z"}]}',
    );
    final refreshed = await service.refreshOwnDevice();
    expect(refreshed?.name, 'MacBook');
    expect(service.ownFriendlyName, 'Restored');
    expect(http.requests.last.method, 'GET');
    expect(http.requests.last.url.path, '/api/devices');
    await Future<void>.delayed(Duration.zero);
    expect(labels, ['Studio', null, 'Restored']);
  });

  test('listNetworkDevices fetches the enrolled personal network with the '
      'account JWT', () async {
    final http = FakeHttpClient()
      ..respond(200, body: _enrollBody)
      ..respond(200, body: '{"ticket":"tk-roster"}');
    final (service, _, _, _, _) = await buildService(httpClient: http);
    addTearDown(service.dispose);
    await service.start();
    await pumpUntilOnline(service);
    http.respond(
      200,
      body:
          '{"devices":[{"deviceId":"dev-remote","name":"thinkpad",'
          '"friendlyName":"Desk","presence":"offline"}]}',
    );

    final devices = await service.listNetworkDevices();

    expect(devices.single.displayName, 'Desk');
    expect(devices.single.presence, 'offline');
    final request = http.requests.last;
    expect(request.method, 'GET');
    expect(request.url.path, '/api/networks/net-personal/devices');
    expect(request.headers['authorization'], 'Bearer jwt-1');
  });

  test(
    'keychain token store persists DM keys beside device credentials',
    () async {
      final values = <String, String>{};
      final store = KeychainDeviceTokenStore(
        readAll: () async => values,
        setValue: (name, value) async {
          values[name] = value;
          return true;
        },
      );
      await store.write(
        const DeviceCredentials(
          deviceId: 'dev-1',
          deviceToken: 'dt-secret',
          personalNetworkId: 'net-personal',
        ),
      );

      await store.writeDmPrivateKeys(const {'fa@dev-1': 'private-seed'});

      final restored = await store.read();
      expect(restored?.deviceToken, 'dt-secret');
      expect(restored?.personalNetworkId, 'net-personal');
      expect(restored?.dmPrivateKeys, {'fa@dev-1': 'private-seed'});
      expect(await store.readDmPrivateKeys(), {'fa@dev-1': 'private-seed'});
      expect(values, hasLength(1));
    },
  );

  test(
    'DM public key is stable across service instances and stored once',
    () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-dm-1"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"ticket":"tk-dm-2"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final tokens = enrolledTokens();
      const sourceRows = <DeviceChatSession>[(id: 'chat-1', live: true)];
      final (first, _, _, _, _) = await buildService(
        httpClient: http,
        tokenStore: tokens,
        chatSessionSource: FakeChatSessionSource(sourceRows),
        rosterDebounce: Duration.zero,
      );
      addTearDown(first.dispose);

      await first.start();
      await pumpUntilOnline(first);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final firstLive = rosterPatches(http).firstWhere(
        (patch) => (patch['agents'] as List).single['state'] == 'live',
      );
      final firstPub = (firstLive['agents'] as List).single['dmPub'] as String;
      final privateKeys = tokens.stored?.dmPrivateKeys;
      expect(base64Decode(firstPub), hasLength(32));
      expect(privateKeys?.keys, {'fa@dev-1'});
      expect(tokens.writes, 1);
      await first.stop();

      final (second, _, _, _, _) = await buildService(
        httpClient: http,
        tokenStore: tokens,
        chatSessionSource: FakeChatSessionSource(sourceRows),
        rosterDebounce: Duration.zero,
      );
      addTearDown(second.dispose);
      await second.start();
      await pumpUntilOnline(second);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final secondLive = rosterPatches(http).lastWhere(
        (patch) => (patch['agents'] as List).single['state'] == 'live',
      );
      expect((secondLive['agents'] as List).single['dmPub'], firstPub);
      expect(tokens.stored?.dmPrivateKeys, privateKeys);
      expect(tokens.writes, 1, reason: 'a restored key must not be rotated');
      expect(
        http.requests.where(
          (request) => request.url.path == '/api/devices/enroll',
        ),
        isEmpty,
      );
    },
  );

  group('REST roster projection', () {
    const debounce = Duration(milliseconds: 40);
    const settle = Duration(milliseconds: 100);

    test('connect publishes unique live agents and every session with the '
        'personal network exposure', () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-roster"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final (service, manager, _, _, _) = await buildService(
        httpClient: http,
        tokenStore: enrolledTokens(),
        rosterDebounce: debounce,
      );
      addTearDown(service.dispose);
      putSession(manager, http, 'session-1', notify: false);
      putSession(manager, http, 'session-2', notify: false);

      await service.start();
      await pumpUntilOnline(service);
      await Future<void>.delayed(settle);

      final patches = rosterPatches(http);
      expect(patches, hasLength(1));
      expect(patches.single, {
        'agents': [agentPatch('live', true)],
        'sessions': [
          {
            'id': 'session-1',
            'state': 'live',
            'networks': ['net-personal'],
          },
          {
            'id': 'session-2',
            'state': 'live',
            'networks': ['net-personal'],
          },
        ],
      });
    });

    test(
      'session open publishes only the new session as a live merge',
      () async {
        final http = FakeHttpClient()
          ..respond(200, body: '{"ticket":"tk-open"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}');
        final (service, manager, _, _, _) = await buildService(
          httpClient: http,
          tokenStore: enrolledTokens(),
          rosterDebounce: debounce,
        );
        addTearDown(service.dispose);
        putSession(manager, http, 'session-1', notify: false);
        await service.start();
        await pumpUntilOnline(service);
        await Future<void>.delayed(settle);

        putSession(manager, http, 'session-2');
        await Future<void>.delayed(settle);

        final patches = rosterPatches(http);
        expect(patches, hasLength(2));
        expect(patches.last['sessions'], [
          {
            'id': 'session-2',
            'state': 'live',
            'networks': ['net-personal'],
          },
        ]);
        expect(patches.last['agents'], [agentPatch('live', true)]);
        expect(
          service.connector!.registry.sessions.map((session) => session.id),
          containsAll(['session-1', 'session-2']),
        );
      },
    );

    test(
      'session close retracts only that session with explicit offline',
      () async {
        final http = FakeHttpClient()
          ..respond(200, body: '{"ticket":"tk-close"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}');
        final (service, manager, _, _, _) = await buildService(
          httpClient: http,
          tokenStore: enrolledTokens(),
          rosterDebounce: debounce,
        );
        addTearDown(service.dispose);
        putSession(manager, http, 'session-1', notify: false);
        putSession(manager, http, 'session-2', notify: false);
        await service.start();
        await pumpUntilOnline(service);
        await Future<void>.delayed(settle);

        manager.sessions.remove('session-2');
        manager.notifyListeners();
        await Future<void>.delayed(settle);

        final patches = rosterPatches(http);
        expect(patches, hasLength(2));
        expect(patches.last, {
          'agents': <Object?>[],
          'sessions': [
            {'id': 'session-2', 'state': 'offline', 'networks': <Object?>[]},
          ],
        });
        expect(
          service.connector!.registry.sessions.map((session) => session.id),
          ['session-1'],
        );

        manager.sessions.remove('session-1');
        manager.notifyListeners();
        await Future<void>.delayed(settle);

        final lastClosePatches = rosterPatches(http);
        expect(lastClosePatches, hasLength(3));
        expect(lastClosePatches.last, {
          'agents': <Object?>[],
          'sessions': [
            {'id': 'session-1', 'state': 'offline', 'networks': <Object?>[]},
          ],
        });
        expect(service.connector!.registry.sessions, isEmpty);
      },
    );

    test('injected chat source publishes persisted live/offline sessions, '
        'not network memberships', () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-chat-projection"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final source = FakeChatSessionSource(const [
        (id: 'chat-live', live: true),
        (id: 'chat-offline', live: false),
      ]);
      final (service, manager, _, _, _) = await buildService(
        httpClient: http,
        tokenStore: enrolledTokens(),
        chatSessionSource: source,
        rosterDebounce: debounce,
      );
      addTearDown(service.dispose);
      putSession(manager, http, 'network-membership', notify: false);

      await service.start();
      await pumpUntilOnline(service);
      await Future<void>.delayed(settle);

      expect(rosterPatches(http), [
        {
          'agents': [agentPatch('live', true)],
          'sessions': [
            {
              'id': 'chat-live',
              'state': 'live',
              'networks': ['net-personal'],
            },
            {
              'id': 'chat-offline',
              'state': 'wake_on_dm',
              'networks': ['net-personal'],
            },
          ],
        },
      ]);
      expect(
        service.connector!.registry.sessions.map((session) => session.id),
        ['chat-live'],
        reason: 'only loaded chat sessions are live in the connector registry',
      );
    });

    test(
      'metadata rides persisted rows and rename-only changes publish',
      () async {
        final http = FakeHttpClient()
          ..respond(200, body: '{"ticket":"tk-chat-metadata"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}');
        final source =
            FakeChatSessionSource(const [(id: 'chat-rich', live: false)])
              ..metadata = [
                (
                  id: 'chat-rich',
                  title: 'Release plan',
                  path: '/work/flutter_agent',
                  lastActivity: DateTime.utc(2026, 11, 12, 9),
                ),
              ];
        final (service, _, _, _, _) = await buildService(
          httpClient: http,
          tokenStore: enrolledTokens(),
          chatSessionSource: source,
          rosterDebounce: debounce,
        );
        addTearDown(service.dispose);
        await service.start();
        await pumpUntilOnline(service);
        await Future<void>.delayed(settle);

        expect(rosterPatches(http).single['sessions'], [
          {
            'id': 'chat-rich',
            'state': 'wake_on_dm',
            'networks': ['net-personal'],
            'title': 'Release plan',
            'path': '/work/flutter_agent',
            'lastActivity': '2026-11-12T09:00:00.000Z',
          },
        ]);

        source.replaceMetadata([
          (
            id: 'chat-rich',
            title: 'Renamed release plan',
            path: '/work/flutter_agent',
            lastActivity: DateTime.utc(2026, 11, 12, 9),
          ),
        ]);
        await Future<void>.delayed(settle);
        expect(rosterPatches(http), hasLength(2));
        expect(rosterPatches(http).last['sessions'], [
          {
            'id': 'chat-rich',
            'state': 'wake_on_dm',
            'networks': ['net-personal'],
            'title': 'Renamed release plan',
            'path': '/work/flutter_agent',
            'lastActivity': '2026-11-12T09:00:00.000Z',
          },
        ]);
      },
    );

    test(
      'complete large persisted projections publish in bounded patches',
      () async {
        final http = FakeHttpClient()
          ..respond(200, body: '{"ticket":"tk-chat-large"}');
        for (var i = 0; i < 6; i++) {
          http.respond(200, body: '{"patched":"dev-1"}');
        }
        final source = FakeChatSessionSource([
          for (var i = 0; i < 85; i++) (id: 'chat-$i', live: false),
        ]);
        final (service, _, _, _, _) = await buildService(
          httpClient: http,
          tokenStore: enrolledTokens(),
          chatSessionSource: source,
          rosterDebounce: debounce,
        );
        addTearDown(service.dispose);
        await service.start();
        await pumpUntilOnline(service);
        await Future<void>.delayed(settle);

        final patches = rosterPatches(http);
        expect(patches, hasLength(3));
        expect(patches.map((patch) => (patch['sessions'] as List).length), [
          40,
          40,
          5,
        ]);
        expect(
          patches
              .expand((patch) => patch['sessions'] as List)
              .map((row) => row['id']),
          containsAll([for (var i = 0; i < 85; i++) 'chat-$i']),
        );
      },
    );

    test('chat-session create publishes only the new live merge', () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-chat-create"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final source = FakeChatSessionSource(const [
        (id: 'chat-persisted', live: false),
      ]);
      final (service, _, _, _, _) = await buildService(
        httpClient: http,
        tokenStore: enrolledTokens(),
        chatSessionSource: source,
        rosterDebounce: debounce,
      );
      addTearDown(service.dispose);
      await service.start();
      await pumpUntilOnline(service);
      await Future<void>.delayed(settle);

      source.replace(const [
        (id: 'chat-persisted', live: false),
        (id: 'chat-created', live: true),
      ]);
      await Future<void>.delayed(settle);

      final patches = rosterPatches(http);
      expect(patches, hasLength(2));
      expect(patches.last['sessions'], [
        {
          'id': 'chat-created',
          'state': 'live',
          'networks': ['net-personal'],
        },
      ]);
      expect(patches.last['agents'], [agentPatch('live', true)]);
      expect(
        service.connector!.registry.sessions.map((session) => session.id),
        ['chat-created'],
      );
    });

    test(
      'chat close keeps its persisted row wake-on-DM and delete retracts it',
      () async {
        final http = FakeHttpClient()
          ..respond(200, body: '{"ticket":"tk-chat-close-delete"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}');
        final source = FakeChatSessionSource(const [
          (id: 'chat-retained', live: true),
          (id: 'chat-victim', live: true),
        ]);
        final (service, _, _, _, _) = await buildService(
          httpClient: http,
          tokenStore: enrolledTokens(),
          chatSessionSource: source,
          rosterDebounce: debounce,
        );
        addTearDown(service.dispose);
        await service.start();
        await pumpUntilOnline(service);
        await Future<void>.delayed(settle);

        // Close: the persisted id remains, only its live state changes.
        source.replace(const [
          (id: 'chat-retained', live: true),
          (id: 'chat-victim', live: false),
        ]);
        await Future<void>.delayed(settle);

        var patches = rosterPatches(http);
        expect(patches, hasLength(2));
        expect(patches.last, {
          'agents': <Object?>[],
          'sessions': [
            {
              'id': 'chat-victim',
              'state': 'wake_on_dm',
              'networks': ['net-personal'],
            },
          ],
        });
        expect(
          service.connector!.registry.sessions.map((session) => session.id),
          ['chat-retained'],
        );

        // Delete: the id disappears, so the previous snapshot drives retraction.
        source.replace(const [(id: 'chat-retained', live: true)]);
        await Future<void>.delayed(settle);

        patches = rosterPatches(http);
        expect(patches, hasLength(3));
        expect(patches.last, {
          'agents': <Object?>[],
          'sessions': [
            {'id': 'chat-victim', 'state': 'offline', 'networks': <Object?>[]},
          ],
        });
      },
    );

    test('online reconnect republishes the full chat projection', () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-chat-reconnect-1"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"ticket":"tk-chat-reconnect-2"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final source = FakeChatSessionSource(const [
        (id: 'chat-live', live: true),
        (id: 'chat-offline', live: false),
      ]);
      final (service, _, _, transport, _) = await buildService(
        httpClient: http,
        tokenStore: enrolledTokens(),
        chatSessionSource: source,
        rosterDebounce: debounce,
      );
      addTearDown(service.dispose);
      await service.start();
      await pumpUntilOnline(service);
      await Future<void>.delayed(settle);
      expect(rosterPatches(http), hasLength(1));

      final reconnected = service.phaseStream.firstWhere(
        (phase) => phase == DeviceConnectorPhase.online,
      );
      await transport.sockets.first.close();
      await reconnected.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(settle);

      final patches = rosterPatches(http);
      expect(transport.dials, hasLength(2));
      expect(patches, hasLength(2));
      expect(patches.last, patches.first);
      expect(patches.last['sessions'], [
        {
          'id': 'chat-live',
          'state': 'live',
          'networks': ['net-personal'],
        },
        {
          'id': 'chat-offline',
          'state': 'wake_on_dm',
          'networks': ['net-personal'],
        },
      ]);
    });

    test(
      'stop retracts every current session and known agent offline',
      () async {
        final http = FakeHttpClient()
          ..respond(200, body: '{"ticket":"tk-stop"}')
          ..respond(200, body: '{"patched":"dev-1"}')
          ..respond(200, body: '{"patched":"dev-1"}');
        final (service, manager, _, _, _) = await buildService(
          httpClient: http,
          tokenStore: enrolledTokens(),
          rosterDebounce: debounce,
        );
        addTearDown(service.dispose);
        putSession(manager, http, 'session-1', notify: false);
        putSession(manager, http, 'session-2', notify: false);
        await service.start();
        await pumpUntilOnline(service);
        await Future<void>.delayed(settle);

        await service.stop();

        final patches = rosterPatches(http);
        expect(patches, hasLength(2));
        expect(patches.last, {
          'agents': [agentPatch('offline', false)],
          'sessions': [
            {
              'id': 'session-1',
              'state': 'offline',
              'networks': ['net-personal'],
            },
            {
              'id': 'session-2',
              'state': 'offline',
              'networks': ['net-personal'],
            },
          ],
        });
      },
    );

    test('rapid opens and closes coalesce into one debounced merge', () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-debounce"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final (service, manager, _, _, _) = await buildService(
        httpClient: http,
        tokenStore: enrolledTokens(),
        rosterDebounce: debounce,
      );
      addTearDown(service.dispose);
      putSession(manager, http, 'session-1', notify: false);
      await service.start();
      await pumpUntilOnline(service);
      await Future<void>.delayed(settle);

      putSession(manager, http, 'session-2');
      manager.sessions.remove('session-1');
      manager.notifyListeners();
      putSession(manager, http, 'session-3');

      expect(rosterPatches(http), hasLength(1));
      await Future<void>.delayed(settle);
      final patches = rosterPatches(http);
      expect(patches, hasLength(2));
      expect(patches.last['agents'], hasLength(1));
      expect(patches.last['sessions'], [
        {'id': 'session-1', 'state': 'offline', 'networks': <Object?>[]},
        {
          'id': 'session-2',
          'state': 'live',
          'networks': ['net-personal'],
        },
        {
          'id': 'session-3',
          'state': 'live',
          'networks': ['net-personal'],
        },
      ]);
    });
  });

  test('an enrollment failure leaves the service stopped with a logged '
      'reason', () async {
    final failing = FakeHttpClient()..respond(401, body: 'unauthorized');
    final logs = <String>[];
    final (service, _, _, transport, tokens) = await buildService(
      httpClient: failing,
    );
    addTearDown(service.dispose);
    service.onLog = logs.add;

    await service.start();

    expect(service.isRunning, isFalse);
    expect(service.phase, DeviceConnectorPhase.signedOut);
    expect(tokens.stored, isNull);
    expect(transport.dials, isEmpty);
    expect(logs, isNotEmpty);
  });
}
