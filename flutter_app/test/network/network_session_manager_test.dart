// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

NetworkSessionManager _manager({
  required KeyWallet wallet,
  required FakeHttpClient httpClient,
  String? jwt,
}) => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: httpClient,
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
);

void main() {
  group('NetworkSessionManager create/delete', () {
    test('createNetwork with isPublic PATCHes the directory listing flag '
        'before joining', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        // POST /api/networks → 201 network + join credentials
        ..respond(
          201,
          body:
              '{"network":{"id":"net1","name":"fa-team","ownerId":"u1",'
              '"publicChannels":[]},"joinCredentials":{"networkId":"net1","password":null}}',
        )
        // PATCH /api/networks/net1 → 200 network
        ..respond(
          200,
          body:
              '{"id":"net1","name":"fa-team","ownerId":"u1",'
              '"public":true,"publicChannels":[]}',
        )
        // POST join
        ..respond(200, body: joinBodyOk)
        // session start: channels + members
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final manager = _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      final session = await manager.createNetwork(
        name: 'fa-team',
        password: 'supersecret1',
        isPublic: true,
      );
      addTearDown(manager.disconnectAll);

      expect(session.networkId, 'net1');
      final patch = httpClient.requests.firstWhere(
        (r) => r.method == 'PATCH' && r.url.path == '/api/networks/net1',
      );
      expect(patch.headers['authorization'], 'Bearer jwt-1');
      expect(jsonDecode(patch.body), {'public': true});
      expect(wallet.networks['net1'], isNotNull);
    });

    test('createNetwork without isPublic never PATCHes', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        ..respond(
          201,
          body:
              '{"network":{"id":"net1","name":"fa-team","ownerId":"u1",'
              '"publicChannels":[]},"joinCredentials":{"networkId":"net1","password":null}}',
        )
        ..respond(200, body: joinBodyOk)
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final manager = _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      await manager.createNetwork(name: 'fa-team', password: 'supersecret1');
      addTearDown(manager.disconnectAll);

      expect(httpClient.requests.where((r) => r.method == 'PATCH'), isEmpty);
    });

    test('deleteNetwork DELETEs on the relay and drops the wallet '
        'membership', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        memberClass: 'owner',
      );
      final httpClient = FakeHttpClient()..respond(204);
      final manager = _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      await manager.deleteNetwork('net1');

      final delete = httpClient.requests.single;
      expect(delete.method, 'DELETE');
      expect(delete.url.path, '/api/networks/net1');
      expect(delete.headers['authorization'], 'Bearer jwt-1');
      expect(wallet.networks['net1'], isNull);
    });

    test('deleteNetwork 403 surfaces and keeps the local membership', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final httpClient = FakeHttpClient()
        ..respond(
          403,
          body:
              '{"error":{"code":"forbidden_by_class",'
              '"message":"owner or admin required"}}',
        );
      final manager = _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      await expectLater(
        manager.deleteNetwork('net1'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('owner or admin required'),
          ),
        ),
      );
      expect(wallet.networks['net1'], isNotNull);
    });
  });
}
