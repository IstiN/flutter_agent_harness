// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/wallet_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wallet_export', () {
    // Reduced KDF cost keeps unit tests fast; the format records m/t/p so
    // import derives with the stored parameters regardless.
    const fast = WalletKdfParams(memoryKiB: 256, iterations: 1, lanes: 1);

    Future<KeyWallet> sampleWallet() async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'exporter');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'Exported Net',
        memberClass: 'member',
      );
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'general',
        pub: base64Encode(List.filled(32, 9)),
        priv: base64Encode(List.filled(32, 8)),
      );
      return wallet;
    }

    test('export→import roundtrip restores the full wallet', () async {
      final wallet = await sampleWallet();
      final exported = await exportWallet(wallet, 'hunter2', kdf: fast);
      final imported = await importWallet(exported, 'hunter2');
      expect(imported.identityPub, wallet.identityPub);
      expect(imported.networks['net1']!.name, 'Exported Net');
      final keys = imported.channelKeysFor('net1', 'general');
      expect(keys, isNotNull);
      expect(keys!.priv, base64Encode(List.filled(32, 8)));
    });

    test('export format carries kdf/cipher metadata', () async {
      final wallet = await sampleWallet();
      final exported = await exportWallet(wallet, 'pw', kdf: fast);
      final json = jsonDecode(exported) as Map<String, Object?>;
      expect(json['v'], 1);
      expect(json['kdf'], 'argon2id');
      expect(json['m'], fast.memoryKiB);
      expect(json['t'], fast.iterations);
      expect(json['p'], fast.lanes);
      expect(json['cipher'], 'aes-256-gcm');
      for (final field in ['salt', 'nonce', 'ct']) {
        expect(json[field], isA<String>());
        expect((json[field]! as String), isNotEmpty);
      }
    });

    test('export never leaks plaintext key material', () async {
      final wallet = await sampleWallet();
      final exported = await exportWallet(wallet, 'pw', kdf: fast);
      expect(exported, isNot(contains(wallet.identityPriv!)));
      expect(exported, isNot(contains(base64Encode(List.filled(32, 8)))));
    });

    test(
      'wrong passphrase → WalletImportException, no partial state',
      () async {
        final wallet = await sampleWallet();
        final exported = await exportWallet(wallet, 'right', kdf: fast);
        await expectLater(
          importWallet(exported, 'wrong'),
          throwsA(
            isA<WalletImportException>().having(
              (e) => e.message.toLowerCase(),
              'message',
              contains('passphrase'),
            ),
          ),
        );
      },
    );

    test('corrupted export JSON fails cleanly', () async {
      await expectLater(
        importWallet('{not json', 'pw'),
        throwsA(isA<WalletImportException>()),
      );
      await expectLater(
        importWallet(jsonEncode({'v': 99}), 'pw'),
        throwsA(isA<WalletImportException>()),
      );
      await expectLater(
        importWallet(jsonEncode({'v': 1, 'kdf': 'scrypt'}), 'pw'),
        throwsA(isA<WalletImportException>()),
      );
    });

    test('tampered ciphertext fails authentication', () async {
      final wallet = await sampleWallet();
      final exported = await exportWallet(wallet, 'pw', kdf: fast);
      final json = jsonDecode(exported) as Map<String, Object?>;
      final ct = base64Decode(json['ct']! as String);
      ct[0] ^= 0xFF;
      json['ct'] = base64Encode(ct);
      await expectLater(
        importWallet(jsonEncode(json), 'pw'),
        throwsA(isA<WalletImportException>()),
      );
    });

    test(
      'roundtrip with default spec parameters (m=65536, t=3, p=2)',
      () async {
        final wallet = await sampleWallet();
        final exported = await exportWallet(wallet, 'pw');
        final json = jsonDecode(exported) as Map<String, Object?>;
        expect(json['m'], 65536);
        expect(json['t'], 3);
        expect(json['p'], 2);
        final imported = await importWallet(exported, 'pw');
        expect(imported.identityPub, wallet.identityPub);
      },
      // Pure-Dart Argon2id at 64 MiB is slow under the VM test runner.
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
