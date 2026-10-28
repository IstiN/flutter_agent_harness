// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Account-network discovery (`GET /api/networks/mine`): the manager
/// syncs account-scoped memberships into the wallet after sign-in and
/// account restore, tolerating a 404 from an older backend silently.
library;

import 'dart:async';

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

/// A fake whose `/api/networks/mine` call stays pending until [gate]
/// completes — pins the restore path's UI-first ordering.
final class _GatedMineClient extends FakeHttpClient {
  final gate = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/api/networks/mine') await gate.future;
    return super.send(request);
  }
}

const _initiateBody =
    '{"auth_url":"https://accounts.google.com/o/oauth2/auth?state=st-1&'
    'redirect_uri=http%3A%2F%2F127.0.0.1%3A0%2Fcallback",'
    '"state":"st-1","expires_in":600}';

const _exchangeBody =
    '{"accessToken":"at-1","refreshToken":"rt-1","expiresIn":3600,'
    '"refreshExpiresIn":86400,"tokenType":"Bearer"}';

const _profileBody =
    '{"authenticated":true,"id":"u1","email":"a@b.dev","name":"Alice",'
    '"provider":"google"}';

/// Two memberships: one the wallet already knows (with a stored
/// password) and one created out-of-band via curl/API (no password).
const _mineBody =
    '{"items":['
    '{"id":"net2","name":"curl-made","public":false,"memberClass":"owner"},'
    '{"id":"net1","name":"fa-team-renamed","public":false,'
    '"memberClass":"admin"}]}';

http.Response _mineOk() => http.Response(_mineBody, 200);

Future<NetworkSessionManager> _manager({
  KeyWallet? wallet,
  FakeHttpClient? httpClient,
  String? jwt,
  DateTime Function()? clock,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet ?? await KeyWallet.load(MemoryWalletBackend()),
  httpClient: httpClient ?? FakeHttpClient(),
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
  startReceiver: () async => FakeOAuthReceiver(callbackUri: kFakeOAuthCallback),
  openUrl: (_) async {},
  clock: clock,
);

Future<KeyWallet> _walletWithMembership() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.addNetwork(
    networkId: 'net1',
    name: 'fa-team',
    memberClass: 'member',
    displayName: 'Me',
    password: 'secret-pw',
  );
  return wallet;
}

void main() {
  group('NetworkSessionManager.syncAccountNetworks', () {
    test('merges server memberships into the wallet and notifies', () async {
      final wallet = await _walletWithMembership();
      final httpClient = FakeHttpClient()..accountNetworksResponse = _mineOk();
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );
      var notifications = 0;
      manager.addListener(() => notifications++);

      await manager.syncAccountNetworks();

      expect(notifications, 1);
      final mine = httpClient.requests.singleWhere(
        (r) => r.url.path == '/api/networks/mine',
      );
      expect(mine.method, 'GET');
      expect(mine.headers['authorization'], 'Bearer jwt-1');
      // Known membership: name/class updated, password preserved.
      final known = wallet.networks['net1']!;
      expect(known.name, 'fa-team-renamed');
      expect(known.memberClass, 'admin');
      expect(known.password, 'secret-pw');
      // Out-of-band membership: present, no password yet.
      final added = wallet.networks['net2']!;
      expect(added.name, 'curl-made');
      expect(added.memberClass, 'owner');
      expect(added.password, isNull);
    });

    test('an unchanged merge does not notify', () async {
      final wallet = await _walletWithMembership();
      final httpClient = FakeHttpClient()..accountNetworksResponse = _mineOk();
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );
      await manager.syncAccountNetworks();
      var notifications = 0;
      manager.addListener(() => notifications++);

      await manager.syncAccountNetworks();

      expect(notifications, 0);
    });

    test('404 from an older backend is silent and non-destructive', () async {
      final wallet = await _walletWithMembership();
      // The fake's default /api/networks/mine answer IS the older-backend
      // 404.
      final httpClient = FakeHttpClient();
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );
      var notifications = 0;
      manager.addListener(() => notifications++);

      await manager.syncAccountNetworks();

      expect(notifications, 0);
      expect(wallet.networks.keys, ['net1']);
      expect(wallet.networks['net1']!.name, 'fa-team');
      expect(manager.hasJwt, isTrue);
    });

    test('a hard sync failure (500) is equally silent', () async {
      final wallet = await _walletWithMembership();
      final httpClient = FakeHttpClient()
        ..accountNetworksResponse = http.Response('boom', 500);
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      await manager.syncAccountNetworks();

      expect(wallet.networks.keys, ['net1']);
    });

    test('without a JWT it is a no-op with no HTTP traffic', () async {
      final wallet = await _walletWithMembership();
      final httpClient = FakeHttpClient();
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await manager.syncAccountNetworks();

      expect(
        httpClient.requests.where((r) => r.url.path == '/api/networks/mine'),
        isEmpty,
      );
      expect(wallet.networks.keys, ['net1']);
    });

    test('signInWithProvider syncs after the OAuth flow', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        ..respond(200, body: _initiateBody)
        ..respond(200, body: _exchangeBody)
        ..respond(200, body: _profileBody)
        ..accountNetworksResponse = _mineOk();
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await manager.signInWithProvider('google');

      expect(manager.hasJwt, isTrue);
      expect(wallet.networks['net2']?.name, 'curl-made');
      expect(wallet.networks['net2']?.password, isNull);
    });

    test('dev signIn syncs too', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        ..respond(200, body: '{"token":"jwt-dev"}')
        ..accountNetworksResponse = _mineOk();
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await manager.signIn(login: 'dev', password: 'dev');

      expect(wallet.networks['net1']?.name, 'fa-team-renamed');
      expect(wallet.networks['net2'], isNotNull);
    });

    test('restoreAccount syncs on the fresh-token path', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.saveAccount(
        WalletAccount(
          provider: 'google',
          login: 'a@b.dev',
          displayName: 'Alice',
          accessToken: 'at-old',
          refreshToken: 'rt-old',
          accessExpiresAt: DateTime.utc(2026, 2, 1, 13),
        ),
      );
      final httpClient = FakeHttpClient()..accountNetworksResponse = _mineOk();
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        clock: () => DateTime.utc(2026, 2, 1, 12),
      );

      await manager.restoreAccount();

      expect(manager.hasJwt, isTrue);
      expect(wallet.networks['net2']?.name, 'curl-made');
    });

    test(
      'restoreAccount surfaces the account BEFORE the sync completes',
      () async {
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        await wallet.saveAccount(
          WalletAccount(
            provider: 'google',
            login: 'a@b.dev',
            displayName: 'Alice',
            accessToken: 'fresh-token',
            refreshToken: 'refresh-token',
            accessExpiresAt: DateTime.utc(2026, 2, 1, 13),
          ),
        );
        final httpClient = _GatedMineClient();
        final manager = await _manager(
          wallet: wallet,
          httpClient: httpClient,
          clock: () => DateTime.utc(2026, 2, 1, 12),
        );
        var notifications = 0;
        manager.addListener(() => notifications++);

        final restore = manager.restoreAccount();

        // A slow account-networks probe must never keep the signed-in
        // account itself off the screen.
        expect(manager.hasJwt, isTrue);
        expect(notifications, 1);
        httpClient.gate.complete();
        await restore;
      },
    );

    test('restoreAccount syncs on the refreshed-token path', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.saveAccount(
        WalletAccount(
          provider: 'google',
          login: 'a@b.dev',
          displayName: 'Alice',
          accessToken: 'at-old',
          refreshToken: 'rt-old',
          accessExpiresAt: DateTime.utc(2026, 2, 1, 11), // expired
          refreshExpiresAt: DateTime.utc(2026, 3, 1),
        ),
      );
      final httpClient = FakeHttpClient()
        ..respond(
          200,
          body:
              '{"accessToken":"at-new","refreshToken":"rt-new",'
              '"expiresIn":3600,"refreshExpiresIn":86400}',
        )
        ..accountNetworksResponse = _mineOk();
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        clock: () => DateTime.utc(2026, 2, 1, 12),
      );

      await manager.restoreAccount();

      expect(manager.hasJwt, isTrue);
      expect(wallet.networks['net2']?.name, 'curl-made');
      expect(wallet.networks['net1']?.name, 'fa-team-renamed');
    });

    test('a sync failure never breaks the sign-in itself', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        ..respond(200, body: _initiateBody)
        ..respond(200, body: _exchangeBody)
        ..respond(200, body: _profileBody);
      // Default 404 on /api/networks/mine — the older backend.
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await manager.signInWithProvider('google');

      expect(manager.hasJwt, isTrue);
      expect(wallet.account, isNotNull);
      expect(wallet.networks, isEmpty);
    });
  });
}
