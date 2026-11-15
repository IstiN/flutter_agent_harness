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

final class _ReadFailureEnv extends ForwardingFs {
  _ReadFailureEnv(super.delegate, this.error);

  final FileError error;

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      Future<Result<String, FileError>>.value(Err(error));
}

final class _FailingPendingOAuthStore implements PendingOAuthStore {
  _FailingPendingOAuthStore({this.readError});

  final Object? readError;
  PendingOAuthFlow? flow;

  @override
  Future<void> save(PendingOAuthFlow flow) async => this.flow = flow;

  @override
  Future<PendingOAuthFlow?> read() async {
    final error = readError;
    if (error != null) throw error;
    return flow;
  }

  @override
  Future<void> clear() async => flow = null;
}

NetworkSessionManager _manager({
  required KeyWallet wallet,
  required FakeHttpClient httpClient,
  PendingOAuthStore? store,
  Uri? initialLink,
  Future<Uri?> Function()? getInitialLink,
}) => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: httpClient,
  wsConnector: FakeWsConnector(),
  pendingStore: store,
  getInitialLink: getInitialLink ?? () async => initialLink,
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

    test('tryFromJson rejects malformed values and every invalid field', () {
      expect(PendingOAuthFlow.tryFromJson(null), isNull);
      expect(PendingOAuthFlow.tryFromJson('not a map'), isNull);
      final valid = _pending().toJson();
      const invalidValues = <String, List<Object?>>{
        'provider': [null, 1, ''],
        'clientType': [null, 1, ''],
        'environment': [null, 1, ''],
        'redirectUri': [null, 1, 'relative/path', 'http://['],
        'state': [null, 1, ''],
        'createdAt': [null, 1, 'not-a-date'],
      };
      for (final entry in invalidValues.entries) {
        for (final invalid in entry.value) {
          final candidate = Map<String, Object?>.from(valid)
            ..[entry.key] = invalid;
          expect(
            PendingOAuthFlow.tryFromJson(candidate),
            isNull,
            reason: '${entry.key} = $invalid',
          );
        }
      }
    });

    test(
      'file store treats blank content as empty without deleting it',
      () async {
        final env = MemoryExecutionEnv();
        final store = FilePendingOAuthStore(env);
        final path = '${env.cwd}/${FilePendingOAuthStore.fileName}';
        await env.writeFile(path, ' \n\t');

        expect(await store.read(), isNull);
        expect((await env.exists(path)).valueOrNull, isTrue);
      },
    );

    test('file store clears malformed JSON and invalid documents', () async {
      for (final text in ['{not json', '{"provider":"google"}']) {
        final env = MemoryExecutionEnv();
        final store = FilePendingOAuthStore(env);
        final path = '${env.cwd}/${FilePendingOAuthStore.fileName}';
        await env.writeFile(path, text);

        expect(await store.read(), isNull, reason: text);
        expect((await env.exists(path)).valueOrNull, isFalse, reason: text);
      }
    });

    test('file store surfaces non-not-found read failures', () async {
      const error = FileError(FileErrorCode.permissionDenied, 'read denied');
      final store = FilePendingOAuthStore(
        _ReadFailureEnv(MemoryExecutionEnv(), error),
      );

      await expectLater(store.read(), throwsA(same(error)));
    });
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
    test('does not read the platform link without pending storage', () async {
      var initialLinkReads = 0;
      final manager = _manager(
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        getInitialLink: () async {
          initialLinkReads++;
          return Uri.parse('fah://oauth/network?code=c&state=st-1');
        },
      );

      expect(await manager.resumeOAuthSignInFromInitialLink(), isFalse);
      expect(initialLinkReads, 0);
    });

    test('ignores absent, foreign, and failing initial links', () async {
      for (final link in <Uri?>[null, Uri.parse('https://fa1.dev/sign-in')]) {
        final store = MemoryPendingOAuthStore();
        await store.save(_pending());
        final manager = _manager(
          wallet: await KeyWallet.load(MemoryWalletBackend()),
          httpClient: FakeHttpClient(),
          store: store,
          initialLink: link,
        );

        expect(await manager.resumeOAuthSignInFromInitialLink(), isFalse);
        expect(await store.read(), isNotNull);
      }

      final store = MemoryPendingOAuthStore();
      await store.save(_pending());
      final manager = _manager(
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        store: store,
        getInitialLink: () async => throw StateError('AppLinks unavailable'),
      );
      expect(await manager.resumeOAuthSignInFromInitialLink(), isFalse);
      expect(await store.read(), isNotNull);
    });

    test('refuses missing and unreadable pending records', () async {
      final emptyStore = MemoryPendingOAuthStore();
      final emptyManager = _manager(
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        store: emptyStore,
        initialLink: Uri.parse('fah://oauth/network?code=c&state=st-1'),
      );
      expect(await emptyManager.resumeOAuthSignInFromInitialLink(), isFalse);

      final failingStore = _FailingPendingOAuthStore(
        readError: StateError('storage unavailable'),
      );
      final failingManager = _manager(
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        store: failingStore,
        initialLink: Uri.parse('fah://oauth/network?code=c&state=st-1'),
      );
      expect(await failingManager.resumeOAuthSignInFromInitialLink(), isFalse);
    });

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

    test('missing or empty callback fields clear the fresh flow', () async {
      final links = [
        Uri.parse('fah://oauth/network?code=cold-code'),
        Uri.parse('fah://oauth/network?state=st-1'),
        Uri.parse('fah://oauth/network?code=&state=st-1'),
        Uri.parse('fah://oauth/network?code=cold-code&state='),
      ];
      for (final link in links) {
        final httpClient = FakeHttpClient();
        final store = MemoryPendingOAuthStore();
        await store.save(_pending());
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        final manager = _manager(
          wallet: wallet,
          httpClient: httpClient,
          store: store,
          initialLink: link,
        );

        expect(
          await manager.resumeOAuthSignInFromInitialLink(),
          isFalse,
          reason: link.toString(),
        );
        expect(httpClient.requests, isEmpty);
        expect(wallet.account, isNull);
        expect(await store.read(), isNull);
      }
    });

    test('exchange failure is contained and clears the pending flow', () async {
      final httpClient = FakeHttpClient()
        ..respond(
          400,
          body: '{"error":{"code":"invalid_grant","message":"bad code"}}',
        );
      final store = MemoryPendingOAuthStore();
      await store.save(_pending());
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = _manager(
        wallet: wallet,
        httpClient: httpClient,
        store: store,
        initialLink: Uri.parse('fah://oauth/network?code=bad&state=st-1'),
      );

      expect(await manager.resumeOAuthSignInFromInitialLink(), isFalse);
      expect(httpClient.requests.single.url.path, '/api/oauth-proxy/exchange');
      expect(wallet.account, isNull);
      expect(manager.hasJwt, isFalse);
      expect(await store.read(), isNull);
    });

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
