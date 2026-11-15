// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/network/device_conversation_entry.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show NetworkEnvelope;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _channelId = 'dm:user:u-1:goal_builder@dev-1';

final class _FakeConnector implements DeviceConnectorService {
  _FakeConnector(this.personalNetworkId);

  @override
  final String? personalNetworkId;

  final _dmMail = StreamController<NetworkEnvelope>.broadcast(sync: true);
  final dmCalls = <({String deviceId, String agentName})>[];
  void Function()? onResolve;

  @override
  Stream<NetworkEnvelope> get dmMail => _dmMail.stream;

  bool get hasDmListener => _dmMail.hasListener;

  @override
  Future<String> dmChannelForAgent({
    required String deviceId,
    required String agentName,
  }) async {
    dmCalls.add((deviceId: deviceId, agentName: agentName));
    onResolve?.call();
    return _channelId;
  }

  Future<void> close() => _dmMail.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Rig {
  _Rig({
    required this.wallet,
    required this.httpClient,
    required this.manager,
    required this.mode,
    required this.connector,
  });

  final KeyWallet wallet;
  final FakeHttpClient httpClient;
  final NetworkSessionManager manager;
  final NetworkModeController mode;
  final _FakeConnector connector;
  final errors = <String>[];
  bool mounted = true;
}

Future<_Rig> _createRig({String? personalNetworkId = 'net1'}) async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  final httpClient = FakeHttpClient();
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: httpClient,
    wsConnector: FakeWsConnector(),
    jwtToken: 'jwt-account',
  );
  final connector = _FakeConnector(personalNetworkId);
  addTearDown(() async {
    await manager.disconnectAll();
    await connector.close();
  });
  return _Rig(
    wallet: wallet,
    httpClient: httpClient,
    manager: manager,
    mode: NetworkModeController.inMemory(),
    connector: connector,
  );
}

Future<DeviceConversationEntry?> _prepare(
  _Rig rig, {
  bool nullManager = false,
  bool nullMode = false,
  bool Function()? isMounted,
}) => prepareDeviceConversation(
  manager: nullManager ? null : rig.manager,
  mode: nullMode ? null : rig.mode,
  connector: rig.connector,
  deviceId: 'dev-1',
  deviceLabel: 'Duo',
  agentAddress: 'goal_builder@dev-1',
  sessionId: 'session-1',
  sessionTitle: 'Session title',
  onError: rig.errors.add,
  isMounted: isMounted ?? () => rig.mounted,
);

void _queueJoin(FakeHttpClient httpClient) {
  httpClient
    ..respond(200, body: joinBodyOk)
    ..respond(200, body: channelsBody)
    ..respond(200, body: membersBody);
}

void main() {
  test('null manager aborts before resolving the device channel', () async {
    final rig = await _createRig();

    final entry = await _prepare(rig, nullManager: true);

    expect(entry, isNull);
    expect(rig.errors, isEmpty);
    expect(rig.connector.dmCalls, isEmpty);
  });

  test('null mode aborts before resolving the device channel', () async {
    final rig = await _createRig();

    final entry = await _prepare(rig, nullMode: true);

    expect(entry, isNull);
    expect(rig.errors, isEmpty);
    expect(rig.connector.dmCalls, isEmpty);
  });

  test('missing personal network reports the enrollment error', () async {
    final rig = await _createRig(personalNetworkId: null);

    final entry = await _prepare(rig);

    expect(entry, isNull);
    expect(rig.errors, ['device not enrolled yet']);
    expect(rig.connector.dmCalls, isEmpty);
  });

  test(
    'join failure reports the error and does not enter the network',
    () async {
      final rig = await _createRig();
      rig.httpClient.respond(
        500,
        body: '{"error":{"code":"http_5xx","message":"join rejected"}}',
      );

      final entry = await _prepare(rig);

      expect(entry, isNull);
      expect(rig.errors.single, contains('join rejected'));
      expect(rig.manager.sessions, isEmpty);
      expect(rig.mode.mode, AppMode.local);
      expect(rig.mode.networkId, isNull);
      expect(rig.connector.hasDmListener, isFalse);
    },
  );

  test(
    'success joins an absent personal network and prepares the DM',
    () async {
      final rig = await _createRig();
      _queueJoin(rig.httpClient);

      final entry = await _prepare(rig);

      expect(entry, isNotNull);
      expect(identical(entry!.manager, rig.manager), isTrue);
      expect(identical(entry.mode, rig.mode), isTrue);
      expect(entry.networkId, 'net1');
      expect(entry.channel.id, _channelId);
      expect(entry.channel.networkId, 'net1');
      expect(entry.channel.name, 'Duo · goal_builder');
      expect(rig.connector.dmCalls.single, (
        deviceId: 'dev-1',
        agentName: 'goal_builder',
      ));

      final join = rig.httpClient.requests.firstWhere(
        (request) => request.url.path == '/api/networks/net1/join',
      );
      expect((jsonDecode(join.body) as Map<String, dynamic>)['password'], '');
      final session = rig.manager.sessions['net1'];
      expect(session, isNotNull);
      expect(rig.mode.mode, AppMode.network);
      expect(rig.mode.networkId, 'net1');
      expect(rig.mode.channelId, isNull);
      expect(rig.connector.hasDmListener, isTrue);
      expect(
        session!.channels
            .singleWhere((channel) => channel.id == _channelId)
            .name,
        'Duo · goal_builder',
      );
      expect(session.dmSessionTargets[_channelId], 'session-1');
      expect(session.dmSessionTitle(_channelId), 'Session title');
      expect(rig.errors, isEmpty);
    },
  );

  test(
    'an existing personal session skips join and reuses the session',
    () async {
      final rig = await _createRig();
      final session = buildSession(
        httpClient: FakeHttpClient(),
        connector: FakeWsConnector(),
        wallet: rig.wallet,
        jwtToken: 'jwt-account',
      );
      rig.manager.sessions['net1'] = session;

      final entry = await _prepare(rig);

      expect(entry, isNotNull);
      expect(identical(rig.manager.sessions['net1'], session), isTrue);
      expect(rig.httpClient.requests, isEmpty);
      expect(rig.connector.hasDmListener, isTrue);
      expect(session.dmSessionTargets[_channelId], 'session-1');
    },
  );

  test(
    'unmount during channel resolution aborts before membership work',
    () async {
      final rig = await _createRig();
      rig.connector.onResolve = () => rig.mounted = false;

      final entry = await _prepare(rig);

      expect(entry, isNull);
      expect(rig.httpClient.requests, isEmpty);
      expect(rig.mode.networkId, isNull);
    },
  );

  test('unmount during join aborts before entering the network', () async {
    final rig = await _createRig();
    _queueJoin(rig.httpClient);
    var mountChecks = 0;

    final entry = await _prepare(rig, isMounted: () => ++mountChecks < 2);

    expect(entry, isNull);
    expect(rig.manager.sessions['net1'], isNotNull);
    expect(rig.mode.networkId, isNull);
    expect(rig.connector.hasDmListener, isFalse);
  });

  test(
    'unmount during network entry aborts before mutating DM state',
    () async {
      final rig = await _createRig();
      final session = buildSession(
        httpClient: FakeHttpClient(),
        connector: FakeWsConnector(),
        wallet: rig.wallet,
        jwtToken: 'jwt-account',
      );
      rig.manager.sessions['net1'] = session;
      var mountChecks = 0;

      final entry = await _prepare(rig, isMounted: () => ++mountChecks < 3);

      expect(entry, isNull);
      expect(rig.mode.networkId, 'net1');
      expect(rig.connector.hasDmListener, isFalse);
      expect(session.channels, isEmpty);
      expect(session.dmSessionTargets, isEmpty);
    },
  );
}
