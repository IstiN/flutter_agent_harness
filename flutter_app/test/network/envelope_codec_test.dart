// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EnvelopeCodec', () {
    const codec = EnvelopeCodec();

    Future<({String pub, String priv})> keyPair() =>
        EnvelopeCodec.newX25519KeyPair();

    test(
      'encrypt→decrypt roundtrip recovers plaintext and sender pub',
      () async {
        final sender = await keyPair();
        final channel = await keyPair();
        final payload = await codec.encrypt(
          senderIdentity: await codec.keyPairFromPriv(sender.priv),
          channelPub: codec.publicKeyFromB64(channel.pub),
          frameId: 'frame-1',
          channelName: 'general',
          plaintext: 'hello fa_network',
        );
        final result = await codec.decrypt(
          channelKeyPair: await codec.keyPairFromPriv(channel.priv),
          frameId: 'frame-1',
          channelName: 'general',
          payloadB64: payload,
        );
        expect(result.plaintext, 'hello fa_network');
        expect(result.senderPub, sender.pub);
      },
    );

    test(
      'cross-instance: encrypt with one codec, decrypt with another',
      () async {
        const a = EnvelopeCodec();
        const b = EnvelopeCodec();
        final sender = await keyPair();
        final channel = await keyPair();
        final payload = await a.encrypt(
          senderIdentity: await a.keyPairFromPriv(sender.priv),
          channelPub: a.publicKeyFromB64(channel.pub),
          frameId: 'f2',
          channelName: 'ops',
          plaintext: 'cross instance',
        );
        final result = await b.decrypt(
          channelKeyPair: await b.keyPairFromPriv(channel.priv),
          frameId: 'f2',
          channelName: 'ops',
          payloadB64: payload,
        );
        expect(result.plaintext, 'cross instance');
      },
    );

    test('wrong channel key throws EnvelopeCryptoException', () async {
      final sender = await keyPair();
      final channel = await keyPair();
      final otherChannel = await keyPair();
      final payload = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(sender.priv),
        channelPub: codec.publicKeyFromB64(channel.pub),
        frameId: 'f3',
        channelName: 'general',
        plaintext: 'secret',
      );
      await expectLater(
        codec.decrypt(
          channelKeyPair: await codec.keyPairFromPriv(otherChannel.priv),
          frameId: 'f3',
          channelName: 'general',
          payloadB64: payload,
        ),
        throwsA(isA<EnvelopeCryptoException>()),
      );
    });

    test('tampered ciphertext throws EnvelopeCryptoException', () async {
      final sender = await keyPair();
      final channel = await keyPair();
      final payload = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(sender.priv),
        channelPub: codec.publicKeyFromB64(channel.pub),
        frameId: 'f4',
        channelName: 'general',
        plaintext: 'tamper me',
      );
      final bytes = base64Decode(payload);
      // Flip one byte in the ciphertext region (after version+spk+nonce).
      bytes[1 + 32 + 12] ^= 0xFF;
      await expectLater(
        codec.decrypt(
          channelKeyPair: await codec.keyPairFromPriv(channel.priv),
          frameId: 'f4',
          channelName: 'general',
          payloadB64: base64Encode(bytes),
        ),
        throwsA(isA<EnvelopeCryptoException>()),
      );
    });

    test('tampered tag throws EnvelopeCryptoException', () async {
      final sender = await keyPair();
      final channel = await keyPair();
      final payload = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(sender.priv),
        channelPub: codec.publicKeyFromB64(channel.pub),
        frameId: 'f5',
        channelName: 'general',
        plaintext: 'tag tamper',
      );
      final bytes = base64Decode(payload);
      bytes[bytes.length - 1] ^= 0x01;
      await expectLater(
        codec.decrypt(
          channelKeyPair: await codec.keyPairFromPriv(channel.priv),
          frameId: 'f5',
          channelName: 'general',
          payloadB64: base64Encode(bytes),
        ),
        throwsA(isA<EnvelopeCryptoException>()),
      );
    });

    test(
      'garbage payload throws EnvelopeCryptoException (never crashes)',
      () async {
        final channel = await keyPair();
        for (final garbage in [
          '!!!not-base64!!!',
          '',
          base64Encode([0x01, 0x02]), // truncated frame
          base64Encode(List.filled(60, 7)), // bad version byte 0x07
        ]) {
          await expectLater(
            codec.decrypt(
              channelKeyPair: await codec.keyPairFromPriv(channel.priv),
              frameId: 'f6',
              channelName: 'general',
              payloadB64: garbage,
            ),
            throwsA(isA<EnvelopeCryptoException>()),
            reason: 'payload $garbage must be rejected',
          );
        }
      },
    );

    test('AAD mismatch: wrong channelName throws', () async {
      final sender = await keyPair();
      final channel = await keyPair();
      final payload = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(sender.priv),
        channelPub: codec.publicKeyFromB64(channel.pub),
        frameId: 'f7',
        channelName: 'general',
        plaintext: 'aad',
      );
      await expectLater(
        codec.decrypt(
          channelKeyPair: await codec.keyPairFromPriv(channel.priv),
          frameId: 'f7',
          channelName: 'random',
          payloadB64: payload,
        ),
        throwsA(isA<EnvelopeCryptoException>()),
      );
    });

    test('AAD mismatch: wrong frameId throws', () async {
      final sender = await keyPair();
      final channel = await keyPair();
      final payload = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(sender.priv),
        channelPub: codec.publicKeyFromB64(channel.pub),
        frameId: 'f8',
        channelName: 'general',
        plaintext: 'aad',
      );
      await expectLater(
        codec.decrypt(
          channelKeyPair: await codec.keyPairFromPriv(channel.priv),
          frameId: 'f8-other',
          channelName: 'general',
          payloadB64: payload,
        ),
        throwsA(isA<EnvelopeCryptoException>()),
      );
    });

    test('unicode plaintext roundtrips', () async {
      final sender = await keyPair();
      final channel = await keyPair();
      const text = 'привет 👋 こんにちは';
      final payload = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(sender.priv),
        channelPub: codec.publicKeyFromB64(channel.pub),
        frameId: 'f9',
        channelName: 'general',
        plaintext: text,
      );
      final result = await codec.decrypt(
        channelKeyPair: await codec.keyPairFromPriv(channel.priv),
        frameId: 'f9',
        channelName: 'general',
        payloadB64: payload,
      );
      expect(result.plaintext, text);
    });

    test('newX25519KeyPair returns 32-byte keys; priv derives pub', () async {
      final pair = await EnvelopeCodec.newX25519KeyPair();
      expect(base64Decode(pair.pub), hasLength(32));
      expect(base64Decode(pair.priv), hasLength(32));
      final restored = await codec.keyPairFromPriv(pair.priv);
      expect((await restored.extractPublicKey()).bytes, base64Decode(pair.pub));
    });
  });
}
