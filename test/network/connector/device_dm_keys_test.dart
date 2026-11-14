// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/src/network/connector/device_dm_keys.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceDmKeyProvider', () {
    test('persists and reloads one x25519 keypair per agent address', () async {
      final store = MemoryDeviceDmKeyStore();
      final provider = DeviceDmKeyProvider(store);

      final first = await provider.loadOrCreate('goal@dev-1');
      final same = await provider.loadOrCreate('goal@dev-1');
      final moved = await provider.loadOrCreate('goal@dev-2');

      expect(identical(same, first), isTrue);
      expect(store.writes, 2);
      expect(base64Decode(first.privateKey), hasLength(32));
      expect(base64Decode(first.publicKey), hasLength(32));
      expect(
        base64Encode(await first.keyPair.extractPrivateKeyBytes()),
        first.privateKey,
      );
      expect(
        (await first.keyPair.extractPublicKey()).bytes,
        base64Decode(first.publicKey),
      );
      expect(moved.publicKey, isNot(first.publicKey));
      expect(store.keys.keys, {'goal@dev-1', 'goal@dev-2'});

      final restored = await DeviceDmKeyProvider(
        store,
      ).loadOrCreate('goal@dev-1');
      expect(restored.privateKey, first.privateKey);
      expect(restored.publicKey, first.publicKey);
      expect(store.writes, 2, reason: 'restoring must not rotate the key');
    });

    test(
      'concurrent provisioning serializes writes without losing addresses',
      () async {
        final store = MemoryDeviceDmKeyStore();
        final provider = DeviceDmKeyProvider(store);

        final pairs = await Future.wait([
          provider.loadOrCreate('goal@dev-1'),
          provider.loadOrCreate('scout@dev-1'),
          provider.loadOrCreate('goal@dev-1'),
        ]);

        expect(pairs[0].publicKey, pairs[2].publicKey);
        expect(store.keys.keys, {'goal@dev-1', 'scout@dev-1'});
        expect(store.writes, 2);
      },
    );

    test(
      'replaces malformed persisted key material instead of failing',
      () async {
        final store = MemoryDeviceDmKeyStore()
          ..keys['goal@dev-1'] = 'not-base64';
        final provider = DeviceDmKeyProvider(store);

        final pair = await provider.loadOrCreate('goal@dev-1');

        expect(base64Decode(store.keys['goal@dev-1']!), hasLength(32));
        expect(store.keys['goal@dev-1'], pair.privateKey);
        expect(base64Decode(pair.publicKey), hasLength(32));
      },
    );
  });
}
