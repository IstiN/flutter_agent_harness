// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A backend that counts writes — the sync merge must persist ONCE.
class _CountingBackend implements WalletBackend {
  int writes = 0;
  String? stored;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String json) async {
    writes++;
    stored = json;
  }
}

void main() {
  group('KeyWallet', () {
    test('createIfMissing generates identity and persists', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      expect(wallet.hasIdentity, isFalse);
      await wallet.createIfMissing(displayName: 'tester');
      expect(wallet.hasIdentity, isTrue);
      expect(base64Decode(wallet.identityPub!), hasLength(32));
      expect(base64Decode(wallet.identityPriv!), hasLength(32));
      expect(backend.stored, isNotNull);
      // Idempotent: second call keeps the same identity.
      final pub = wallet.identityPub;
      await wallet.createIfMissing();
      expect(wallet.identityPub, pub);
    });

    test('load with no data yields an empty wallet', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      expect(wallet.hasIdentity, isFalse);
      expect(wallet.networks, isEmpty);
    });

    test('addNetwork/addChannelKeys → persist → reload roundtrip '
        '(MemoryWalletBackend)', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.createIfMissing(displayName: 'me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'Test Net',
        memberClass: 'admin',
      );
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'general',
        pub: base64Encode(List.filled(32, 1)),
        priv: base64Encode(List.filled(32, 2)),
      );

      final reloaded = await KeyWallet.load(backend);
      expect(reloaded.identityPub, wallet.identityPub);
      expect(reloaded.networks['net1']!.name, 'Test Net');
      expect(reloaded.networks['net1']!.memberClass, 'admin');
      final keys = reloaded.channelKeysFor('net1', 'general');
      expect(keys, isNotNull);
      expect(base64Decode(keys!.pub), List.filled(32, 1));
      expect(base64Decode(keys.priv), List.filled(32, 2));
    });

    test('removeNetwork drops the network and its channels only', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.createIfMissing();
      await wallet.addNetwork(networkId: 'net1', name: 'One');
      await wallet.addNetwork(networkId: 'net2', name: 'Two');
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'a',
        pub: 'p',
        priv: 'q',
      );
      await wallet.addChannelKeys(
        networkId: 'net2',
        channel: 'b',
        pub: 'p',
        priv: 'q',
      );
      await wallet.removeNetwork('net1');
      final reloaded = await KeyWallet.load(backend);
      expect(reloaded.networks.containsKey('net1'), isFalse);
      expect(reloaded.networks.containsKey('net2'), isTrue);
      expect(reloaded.channelKeysFor('net1', 'a'), isNull);
      expect(reloaded.channelKeysFor('net2', 'b'), isNotNull);
    });

    test('identityKeyPair reconstructs the stored identity', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing();
      final kp = await wallet.identityKeyPair();
      final pub = await kp.extractPublicKey();
      expect(base64Encode(pub.bytes), wallet.identityPub);
    });

    test('channelKeyPair returns a working X25519 keypair', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing();
      // Generate a real channel keypair via the codec helper.
      final channelPair = await EnvelopeCodec.newX25519KeyPair();
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'general',
        pub: channelPair.pub,
        priv: channelPair.priv,
      );
      final kp = await wallet.channelKeyPair('net1', 'general');
      final pub = await kp.extractPublicKey();
      expect(base64Encode(pub.bytes), channelPair.pub);
    });

    test('channelKeyPair for an unknown channel throws StateError', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing();
      expect(wallet.channelKeyPair('nope', 'nope'), throwsA(isA<StateError>()));
    });

    test('identityKeyPair without identity throws StateError', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      expect(wallet.identityKeyPair(), throwsA(isA<StateError>()));
    });

    test(
      'load tolerates a wallet JSON with missing optional sections',
      () async {
        final backend = MemoryWalletBackend()..stored = jsonEncode({'v': 1});
        final wallet = await KeyWallet.load(backend);
        expect(wallet.hasIdentity, isFalse);
        expect(wallet.networks, isEmpty);
      },
    );

    test('load throws FormatException on corrupted JSON (never silently '
        'wipes keys)', () async {
      final backend = MemoryWalletBackend()..stored = '{not json';
      expect(KeyWallet.load(backend), throwsA(isA<FormatException>()));
    });

    test('saveTo switches backend and persists current state', () async {
      final first = MemoryWalletBackend();
      final wallet = await KeyWallet.load(first);
      await wallet.createIfMissing();
      final second = MemoryWalletBackend();
      await wallet.saveTo(second);
      final reloaded = await KeyWallet.load(second);
      expect(reloaded.identityPub, wallet.identityPub);
    });
  });

  group('KeychainWalletBackend', () {
    test(
      'roundtrip via injected keychain closures under the wallet name',
      () async {
        final store = <String, String>{};
        final backend = KeychainWalletBackend(
          readAll: () async => Map.of(store),
          setValue: (name, value) async {
            store[name] = value;
            return true;
          },
          deleteValue: (name) async {
            store.remove(name);
            return true;
          },
        );
        final wallet = await KeyWallet.load(backend);
        await wallet.createIfMissing();
        expect(store.keys, contains(KeychainWalletBackend.storageName));
        expect(store[KeychainWalletBackend.storageName], isNotNull);

        final reloaded = await KeyWallet.load(backend);
        expect(reloaded.identityPub, wallet.identityPub);
      },
    );
  });

  group('FileWalletBackend', () {
    test(
      'roundtrip via MemoryExecutionEnv at <cwd>/network_wallet.json',
      () async {
        final env = MemoryExecutionEnv(cwd: '/home/tester');
        final backend = FileWalletBackend(env);
        expect(await backend.read(), isNull);
        final wallet = await KeyWallet.load(backend);
        await wallet.createIfMissing();
        await wallet.addNetwork(networkId: 'net9', name: 'File Net');

        final file = await env.readTextFile('/home/tester/network_wallet.json');
        expect(file.isOk, isTrue);

        final reloaded = await KeyWallet.load(backend);
        expect(reloaded.identityPub, wallet.identityPub);
        expect(reloaded.networks['net9']!.name, 'File Net');
      },
    );
  });

  group('syncAccountNetworks (account-scoped membership merge)', () {
    AccountNetworkInfo net(String id, String name, MemberClass memberClass) =>
        AccountNetworkInfo(
          id: id,
          name: name,
          isPublic: false,
          memberClass: memberClass,
        );

    test('merges new and known memberships in ONE persist', () async {
      final backend = _CountingBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'stale-name',
        memberClass: 'member',
        displayName: 'Me',
        password: 'keep-me',
      );
      backend.writes = 0; // ignore the setup writes

      final changed = await wallet.syncAccountNetworks([
        net('net2', 'fa-network', MemberClass.owner),
        net('net1', 'renamed', MemberClass.admin),
      ]);

      expect(changed, isTrue);
      expect(backend.writes, 1);
      final persisted = await KeyWallet.load(backend);
      // Known id: name + class updated, local password/displayName kept.
      final known = persisted.networks['net1']!;
      expect(known.name, 'renamed');
      expect(known.memberClass, 'admin');
      expect(known.password, 'keep-me');
      expect(known.displayName, 'Me');
      // New id: inserted with NO password (join supplies it later).
      final added = persisted.networks['net2']!;
      expect(added.name, 'fa-network');
      expect(added.memberClass, 'owner');
      expect(added.password, isNull);
      expect(added.joinedAt, isNotEmpty);
    });

    test('rekeys a legacy name-keyed membership to the canonical id '
        'instead of duplicating it', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'fa-team',
        name: 'fa-team',
        memberClass: 'member',
        displayName: 'Me',
        password: 'legacy-pw',
      );
      await wallet.addChannelKeys(
        networkId: 'fa-team',
        channel: 'c1',
        pub: 'ch-pub',
        priv: 'ch-priv',
      );

      await wallet.syncAccountNetworks([
        net('net1', 'fa-team', MemberClass.admin),
      ]);

      // ONE membership, keyed by the id the server (and member routes)
      // speak — the pre-contract name key must not survive as a second,
      // passwordless row.
      expect(wallet.networks.keys.toList(), ['net1']);
      final migrated = wallet.networks['net1']!;
      expect(migrated.name, 'fa-team');
      expect(migrated.memberClass, 'admin');
      expect(migrated.password, 'legacy-pw');
      expect(migrated.displayName, 'Me');
      expect(wallet.channelKeysFor('net1', 'c1'), (
        pub: 'ch-pub',
        priv: 'ch-priv',
      ));
      expect(wallet.channelKeysFor('fa-team', 'c1'), isNull);
    });

    test('keeps a locally-joined network the account list omits', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.addNetwork(networkId: 'guest-net', name: 'G', password: 'p');

      await wallet.syncAccountNetworks([
        net('net1', 'One', MemberClass.member),
      ]);

      expect(wallet.networks['guest-net']?.password, 'p');
      expect(wallet.networks['net1'], isNotNull);
    });

    test('an unchanged merge persists nothing', () async {
      final backend = _CountingBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.syncAccountNetworks([
        net('net1', 'One', MemberClass.member),
      ]);
      final firstWrite = backend.writes;
      expect(firstWrite, 1);

      final changed = await wallet.syncAccountNetworks([
        net('net1', 'One', MemberClass.member),
      ]);

      expect(changed, isFalse);
      expect(backend.writes, firstWrite);
    });

    test('new entries land in server order', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.syncAccountNetworks([
        net('newest', 'Newest', MemberClass.owner),
        net('oldest', 'Oldest', MemberClass.member),
      ]);
      expect(wallet.networks.keys.toList(), ['newest', 'oldest']);
    });
  });

  group('account (OAuth tokens, issue #955 iteration 3)', () {
    WalletAccount account() => WalletAccount(
      provider: 'google',
      login: 'a@b.dev',
      displayName: 'Alice',
      accessToken: 'at-1',
      refreshToken: 'rt-1',
      accessExpiresAt: DateTime.utc(2026, 2, 1, 13),
      refreshExpiresAt: DateTime.utc(2026, 3, 1),
    );

    test('saveAccount → persist → reload roundtrip', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.saveAccount(account());
      expect(wallet.account!.login, 'a@b.dev');

      final reloaded = await KeyWallet.load(backend);
      final reloadedAccount = reloaded.account!;
      expect(reloadedAccount.provider, 'google');
      expect(reloadedAccount.login, 'a@b.dev');
      expect(reloadedAccount.displayName, 'Alice');
      expect(reloadedAccount.accessToken, 'at-1');
      expect(reloadedAccount.refreshToken, 'rt-1');
      expect(reloadedAccount.accessExpiresAt, DateTime.utc(2026, 2, 1, 13));
      expect(reloadedAccount.refreshExpiresAt, DateTime.utc(2026, 3, 1));
    });

    test('an old wallet without the account field loads fine', () {
      final wallet = KeyWallet.fromJsonString(
        '{"v":1,"identity":{"pub":"p","priv":"s","displayName":"me"},'
        '"channels":{},"networks":{}}',
      );
      expect(wallet.hasIdentity, isTrue);
      expect(wallet.account, isNull);
      // Re-serializing adds no account key.
      expect(wallet.toJson().containsKey('account'), isFalse);
    });

    test('a malformed account entry is skipped, the wallet still loads', () {
      final wallet = KeyWallet.fromJsonString(
        '{"v":1,"identity":{"pub":"p","priv":"s"},'
        '"channels":{},"networks":{},'
        '"account":{"provider":"google"}}', // no tokens/expiry
      );
      expect(wallet.hasIdentity, isTrue);
      expect(wallet.account, isNull);
    });

    test('clearAccount drops the account and persists', () async {
      final backend = MemoryWalletBackend();
      final wallet = await KeyWallet.load(backend);
      await wallet.saveAccount(account());
      await wallet.clearAccount();
      expect(wallet.account, isNull);
      final reloaded = await KeyWallet.load(backend);
      expect(reloaded.account, isNull);
    });

    test('withTokens swaps the token fields only', () {
      final updated = account().withTokens(
        TokenBundle(
          accessToken: 'at-2',
          refreshToken: 'rt-2',
          expiresAt: DateTime.utc(2026, 2, 2),
        ),
      );
      expect(updated.accessToken, 'at-2');
      expect(updated.refreshToken, 'rt-2');
      expect(updated.accessExpiresAt, DateTime.utc(2026, 2, 2));
      expect(updated.refreshExpiresAt, isNull);
      expect(updated.login, 'a@b.dev');
      expect(updated.displayName, 'Alice');
      expect(updated.provider, 'google');
    });
  });
}
