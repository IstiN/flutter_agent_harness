// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/auth_flow.dart';
import 'package:fa/network/auth_pending_store.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

const _initiateBody =
    '{"auth_url":"https://accounts.google.com/o/oauth2/auth?state=st-1",'
    '"state":"st-1","expires_in":600}';
const _exchangeBody =
    '{"accessToken":"at-1","refreshToken":"rt-1","expiresIn":3600,'
    '"refreshExpiresIn":86400,"tokenType":"Bearer"}';
const _profileBody =
    '{"authenticated":true,"id":"u1","email":"a@b.dev","name":"Alice",'
    '"provider":"google"}';

final _now = DateTime.utc(2026, 2, 1, 12);

PendingOAuthFlow _pending({DateTime? createdAt, String state = 'st-1'}) =>
    PendingOAuthFlow(
      provider: 'google',
      clientType: 'desktop',
      environment: 'prod',
      redirectUri: Uri.parse('fah://oauth/network'),
      state: state,
      createdAt: createdAt ?? _now.subtract(const Duration(minutes: 1)),
    );

NetworkSessionManager _manager({
  required KeyWallet wallet,
  required FakeHttpClient httpClient,
  required MemoryPendingOAuthStore store,
  required Uri initialLink,
}) => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: httpClient,
  wsConnector: FakeWsConnector(),
  pendingStore: store,
  getInitialLink: () async => initialLink,
  clock: () => _now,
);

void main() {
  group('pending OAuth store', () {
    test(
      'file store writes every resume field, reads it, and clears',
      () async {
        final env = MemoryExecutionEnv();
        final store = FilePendingOAuthStore(env);
        final pending = _pending();

        await store.save(pending);

        final path = '${env.cwd}/${FilePendingOAuthStore.fileName}';
        final raw = (await env.readTextFile(path)).valueOrNull;
        expect(jsonDecode(raw!), pending.toJson());
        final restored = await store.read();
        expect(restored?.provider, 'google');
        expect(restored?.clientType, 'desktop');
        expect(restored?.environment, 'prod');
        expect(restored?.redirectUri, pending.redirectUri);
        expect(restored?.state, 'st-1');
        expect(restored?.createdAt, pending.createdAt);

        await store.clear();
        expect((await env.exists(path)).valueOrNull, isFalse);
        expect(await store.read(), isNull);
      },
    );
  });

  group('NetworkAuthFlow pending lifecycle', () {
    test(
      'persists before opening the browser and clears after exchange',
      () async {
        final httpClient = FakeHttpClient()
          ..respond(200, body: _initiateBody)
          ..respond(200, body: _exchangeBody);
        final store = MemoryPendingOAuthStore();
        final flow = NetworkAuthFlow(
          client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
          pendingStore: store,
          clock: () => _now,
        );
        PendingOAuthFlow? atBrowserLaunch;

        await flow.signIn(
          provider: 'google',
          clientType: 'desktop',
          environment: 'prod',
          startReceiver: () async => FakeOAuthReceiver(
            redirectUri: Uri.parse('fah://oauth/network'),
            callbackUri: Uri.parse(
              'fah://oauth/network?code=temp-1&state=st-1',
            ),
          ),
          openUrl: (_) async => atBrowserLaunch = await store.read(),
        );

        expect(atBrowserLaunch?.toJson(), _pending(createdAt: _now).toJson());
        expect(await store.read(), isNull);
      },
    );

    test('clears the pending record when the callback times out', () async {
      final httpClient = FakeHttpClient()..respond(200, body: _initiateBody);
      final store = MemoryPendingOAuthStore();
      final flow = NetworkAuthFlow(
        client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
        pendingStore: store,
        clock: () => _now,
      );

      await expectLater(
        flow.signIn(
          provider: 'google',
          startReceiver: () async => FakeOAuthReceiver(
            callbackError: const AuthFlowException('callback timeout'),
          ),
          openUrl: (_) async {},
        ),
        throwsA(isA<AuthFlowException>()),
      );
      expect(await store.read(), isNull);
    });
  });

  group('cold-start OAuth resume', () {
    test(
      'matching fresh state exchanges, saves the account, and syncs',
      () async {
        final httpClient = FakeHttpClient()
          ..respond(200, body: _exchangeBody)
          ..respond(200, body: _profileBody)
          ..accountNetworksResponse = http.Response(
            '{"items":[{"id":"net1","name":"Fa team",'
            '"memberClass":"owner"}]}',
            200,
          );
        final store = MemoryPendingOAuthStore();
        await store.save(_pending());
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        final manager = _manager(
          wallet: wallet,
          httpClient: httpClient,
          store: store,
          initialLink: Uri.parse(
            'fah://oauth/network?code=cold-code&state=st-1',
          ),
        );
        var notifications = 0;
        manager.addListener(() => notifications++);

        expect(await manager.resumeOAuthSignInFromInitialLink(), isTrue);

        expect(httpClient.requests.map((request) => request.url.path), [
          '/api/oauth-proxy/exchange',
          '/api/auth/user',
          '/api/networks/mine',
        ]);
        expect(jsonDecode(httpClient.requests.first.body), {
          'code': 'cold-code',
          'state': 'st-1',
        });
        expect(wallet.account?.provider, 'google');
        expect(wallet.account?.login, 'a@b.dev');
        expect(wallet.account?.accessToken, 'at-1');
        expect(
          wallet.account?.accessExpiresAt,
          _now.add(const Duration(hours: 1)),
        );
        expect(manager.hasJwt, isTrue);
        expect(wallet.networks['net1']?.name, 'Fa team');
        expect(notifications, greaterThan(0));
        expect(await store.read(), isNull);
      },
    );

    test(
      'state mismatch is refused without exchange or account save',
      () async {
        final httpClient = FakeHttpClient();
        final store = MemoryPendingOAuthStore();
        await store.save(_pending());
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        final manager = _manager(
          wallet: wallet,
          httpClient: httpClient,
          store: store,
          initialLink: Uri.parse(
            'fah://oauth/network?code=attacker-code&state=WRONG',
          ),
        );

        expect(await manager.resumeOAuthSignInFromInitialLink(), isFalse);
        expect(httpClient.requests, isEmpty);
        expect(wallet.account, isNull);
        expect(manager.hasJwt, isFalse);
        expect(await store.read(), isNull);
      },
    );

    test('an expired pending record is refused and removed', () async {
      final httpClient = FakeHttpClient();
      final store = MemoryPendingOAuthStore();
      await store.save(
        _pending(
          createdAt: _now.subtract(const Duration(minutes: 10, seconds: 1)),
        ),
      );
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = _manager(
        wallet: wallet,
        httpClient: httpClient,
        store: store,
        initialLink: Uri.parse('fah://oauth/network?code=cold-code&state=st-1'),
      );

      expect(await manager.resumeOAuthSignInFromInitialLink(), isFalse);
      expect(httpClient.requests, isEmpty);
      expect(wallet.account, isNull);
      expect(await store.read(), isNull);
    });
  });
}
