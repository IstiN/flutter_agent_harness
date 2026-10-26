// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_agent_harness/src/hub/dap_key_envelope.dart';
import 'package:test/test.dart';

void main() {
  const priv = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';
  const pass = 'correct horse battery staple';

  Future<String> encrypt([String? p]) =>
      encryptChannelPriv(priv, p ?? pass, random: Random(42), iterations: 1000);

  test('round-trip: encrypt → decrypt restores the plaintext key', () async {
    final envelope = await encrypt();
    expect(envelope, startsWith(dapKeyEnvelopePrefix));
    expect(envelope, isNot(contains(priv)));
    expect(await decryptChannelPriv(envelope, pass), priv);
  });

  test('envelope carries kdf params and version (self-describing)', () async {
    final envelope = await encrypt();
    // Decoding the payload must not require the passphrase.
    final payload = utf8.decode(
      base64Url.decode(envelope.substring(dapKeyEnvelopePrefix.length)),
    );
    expect(payload, contains('"kdf":"pbkdf2-sha256"'));
    expect(payload, contains('"iter":1000'));
    expect(payload, contains('"v":1'));
  });

  test('same input + different random → different envelopes', () async {
    final a = await encryptChannelPriv(
      priv,
      pass,
      random: Random(1),
      iterations: 1000,
    );
    final b = await encryptChannelPriv(
      priv,
      pass,
      random: Random(2),
      iterations: 1000,
    );
    expect(a, isNot(b));
    expect(await decryptChannelPriv(a, pass), priv);
    expect(await decryptChannelPriv(b, pass), priv);
  });

  test(
    'wrong passphrase → clear FormatException, never silent garbage',
    () async {
      final envelope = await encrypt();
      expect(
        () => decryptChannelPriv(envelope, 'wrong'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('wrong passphrase'),
          ),
        ),
      );
    },
  );

  test('tampered ciphertext rejected (AEAD)', () async {
    final envelope = await encrypt();
    final tampered = envelope.replaceRange(
      envelope.length - 4,
      envelope.length,
      'AAAA',
    );
    expect(
      () => decryptChannelPriv(tampered, pass),
      throwsA(isA<FormatException>()),
    );
  });

  test('plaintext priv passes through (pure-env CI path, AC15)', () async {
    expect(await decryptChannelPriv(priv, 'anything'), priv);
    expect(isEncryptedChannelPriv(priv), isFalse);
    expect(isEncryptedChannelPriv(await encrypt()), isTrue);
  });

  test('malformed envelopes fail loudly', () async {
    expect(
      () => decryptChannelPriv('dapkey1.%%%', pass),
      throwsFormatException,
    );
    expect(
      () => decryptChannelPriv('dapkey1.e30', pass), // '{}' — no version
      throwsFormatException,
    );
  });

  group(
    'iteration count sanity bound (review: boot-DoS via committed config)',
    () {
      Future<String> envelopeWithIter(int iter) async {
        // Build the envelope JSON directly so the test never pays the KDF.
        final payload = jsonEncode({
          'v': 1,
          'kdf': 'pbkdf2-sha256',
          'iter': iter,
          'salt': base64Url.encode(List<int>.filled(16, 0)),
          'nonce': base64Url.encode(List<int>.filled(12, 0)),
          'ct': base64Url.encode(List<int>.filled(32, 0)),
        });
        return '$dapKeyEnvelopePrefix${base64Url.encode(utf8.encode(payload))}';
      }

      test('iter above the max is rejected BEFORE any KDF work', () async {
        final sw = Stopwatch()..start();
        await expectLater(
          decryptChannelPriv(await envelopeWithIter(1000000000), pass),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('iteration count'),
            ),
          ),
        );
        // The rejection must be immediate — no billion-iteration KDF ran.
        expect(sw.elapsedMilliseconds, lessThan(5000));
      });

      test('iter below 1 is rejected too', () async {
        await expectLater(
          decryptChannelPriv(await envelopeWithIter(0), pass),
          throwsA(isA<FormatException>()),
        );
      });

      test('just above the cap maps to the single FormatException warning '
          'path (AC15: one clear warning, primary job proceeds)', () async {
        final envelope = await envelopeWithIter(dapKeyMaxIterations + 1);
        expect(
          () => decryptChannelPriv(envelope, pass),
          throwsA(isA<FormatException>()),
        );
      });
    },
  );
}
