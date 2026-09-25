// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
