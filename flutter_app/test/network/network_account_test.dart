// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Manager-level coverage of the ai-native OAuth account (issue #955
/// iteration 3): provider sign-in persisting into the wallet, silent
/// token refresh on restore, the session-expired fallback, sign-out.
library;

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

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

Future<NetworkSessionManager> _manager({
  KeyWallet? wallet,
  FakeHttpClient? httpClient,
  DateTime Function()? clock,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet ?? await KeyWallet.load(MemoryWalletBackend()),
  httpClient: httpClient ?? FakeHttpClient(),
  wsConnector: FakeWsConnector(),
  startReceiver: () async => FakeOAuthReceiver(callbackUri: kFakeOAuthCallback),
  openUrl: (_) async {},
  clock: clock,
);

WalletAccount _account({
  required DateTime accessExpiresAt,
  DateTime? refreshExpiresAt,
}) => WalletAccount(
  provider: 'google',
  login: 'a@b.dev',
  displayName: 'Alice',
  accessToken: 'at-old',
  refreshToken: 'rt-old',
  accessExpiresAt: accessExpiresAt,
  refreshExpiresAt: refreshExpiresAt,
);

void main() {
  group('NetworkSessionManager account auth (#955 iteration 3)', () {
    test('signInWithProvider runs the flow, saves the account into the '
        'wallet and sets the JWT', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: _initiateBody)
        ..respond(200, body: _exchangeBody)
        ..respond(200, body: _profileBody);
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await manager.signInWithProvider('google');

      expect(manager.hasJwt, isTrue);
      expect(manager.accountLogin, 'a@b.dev');
      expect(manager.accountDisplayName, 'Alice');
      final account = wallet.account!;
      expect(account.provider, 'google');
      expect(account.accessToken, 'at-1');
      expect(account.refreshToken, 'rt-1');
      // The profile was fetched with the fresh bearer token, not the
      // manager JWT.
      expect(httpClient.requests.last.url.path, '/api/auth/user');
    });

    test('signInWithProvider tolerates a profile fetch failure', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: _initiateBody)
        ..respond(200, body: _exchangeBody)
        ..respond(500, body: 'oops');
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await manager.signInWithProvider('github');

      expect(manager.hasJwt, isTrue);
      expect(wallet.account!.provider, 'github');
      expect(manager.accountDisplayName, isNull); // no name, no login
    });

    test('restoreAccount: an unexpired access token becomes the JWT with '
        'no HTTP traffic', () async {
      final httpClient = FakeHttpClient();
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.saveAccount(
        _account(accessExpiresAt: DateTime.utc(2026, 2, 1, 13)),
      );
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        clock: () => DateTime.utc(2026, 2, 1, 12),
      );

      await manager.restoreAccount();

      expect(manager.hasJwt, isTrue);
      expect(manager.sessionExpired, isFalse);
      expect(httpClient.requests, isEmpty);
    });

    test('restoreAccount: an expired access token is refreshed silently '
        'and persisted', () async {
      final httpClient = FakeHttpClient()
        ..respond(
          200,
          body:
              '{"accessToken":"at-new","refreshToken":"rt-new",'
              '"expiresIn":3600,"refreshExpiresIn":86400}',
        );
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.saveAccount(
        _account(
          accessExpiresAt: DateTime.utc(2026, 2, 1, 11), // expired
          refreshExpiresAt: DateTime.utc(2026, 3, 1),
        ),
      );
      final now = DateTime.utc(2026, 2, 1, 12);
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        clock: () => now,
      );

      await manager.restoreAccount();

      expect(manager.hasJwt, isTrue);
      expect(manager.sessionExpired, isFalse);
      final account = wallet.account!;
      expect(account.accessToken, 'at-new');
      expect(account.refreshToken, 'rt-new');
      expect(account.accessExpiresAt, now.add(const Duration(hours: 1)));
      expect(account.login, 'a@b.dev'); // identity fields kept
    });

    test('restoreAccount: a failed refresh flips sessionExpired but keeps '
        'the account row', () async {
      final httpClient = FakeHttpClient()
        ..respond(
          401,
          body: '{"error":{"code":"unauthorized","message":"bad refresh"}}',
        );
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.saveAccount(
        _account(accessExpiresAt: DateTime.utc(2026, 2, 1, 11)),
      );
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        clock: () => DateTime.utc(2026, 2, 1, 12),
      );

      await manager.restoreAccount();

      expect(manager.hasJwt, isFalse);
      expect(manager.sessionExpired, isTrue);
      expect(manager.accountDisplayName, 'Alice'); // the row survives
      expect(wallet.account, isNotNull);
    });

    test('restoreAccount: a dead refresh token flips sessionExpired '
        'without HTTP', () async {
      final httpClient = FakeHttpClient();
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.saveAccount(
        _account(
          accessExpiresAt: DateTime.utc(2026, 2, 1, 11),
          refreshExpiresAt: DateTime.utc(2026, 2, 1, 11, 30),
        ),
      );
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        clock: () => DateTime.utc(2026, 2, 1, 12),
      );

      await manager.restoreAccount();

      expect(manager.hasJwt, isFalse);
      expect(manager.sessionExpired, isTrue);
      expect(httpClient.requests, isEmpty);
    });

    test('restoreAccount: no account is a no-op', () async {
      final httpClient = FakeHttpClient();
      final manager = await _manager(httpClient: httpClient);
      await manager.restoreAccount();
      expect(manager.hasJwt, isFalse);
      expect(manager.sessionExpired, isFalse);
      expect(httpClient.requests, isEmpty);
    });

    test('signOut clears the wallet account and the JWT', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: _initiateBody)
        ..respond(200, body: _exchangeBody)
        ..respond(200, body: _profileBody);
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = await _manager(wallet: wallet, httpClient: httpClient);
      await manager.signInWithProvider('google');
      expect(wallet.account, isNotNull);

      await manager.signOut();

      expect(manager.hasJwt, isFalse);
      expect(manager.accountLogin, isNull);
      expect(manager.accountDisplayName, isNull);
      expect(wallet.account, isNull);
    });

    test('dev signIn still works alongside the account state', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: '{"token":"jwt-dev"}');
      final manager = await _manager(httpClient: httpClient);
      await manager.signIn(login: 'dev', password: 'dev');
      expect(manager.hasJwt, isTrue);
      expect(manager.accountLogin, 'dev');
      expect(manager.accountDisplayName, isNull);
    });
  });
}
