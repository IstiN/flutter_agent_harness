import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

void main() {
  test('hkdfSha256 matches RFC 5869 test case 1 (SHA-256)', () async {
    final okm = await hkdfSha256(
      ikm: List.filled(22, 0x0b),
      salt: List.generate(13, (i) => i),
      info: List.generate(10, (i) => 0xf0 + i),
      length: 42,
    );
    expect(
      okm,
      equals(hexDecode(
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      )),
    );
  });

  test('payload encrypt/decrypt round-trip (DM shape)', () async {
    final alice = await X25519().newKeyPair();
    final alicePub = await alice.extractPublicKey();
    final bob = await X25519().newKeyPair();
    final bobPub = await bob.extractPublicKey();

    final ciphertext = await encryptPayload(
      senderDhKeyPair: alice,
      recipientDhPubkey: bobPub,
      frameId: 'frame-1',
      aadTarget: 'a_bob00000000000',
      plaintext: 'ping from alice',
    );
    final wire = base64Decode(ciphertext);
    expect(wire.length, greaterThan(12 + 16)); // nonce + tag + some ct
    expect(ciphertext, isNot(contains('alice')));

    final clear = await decryptPayload(
      recipientDhKeyPair: bob,
      senderDhPubkey: alicePub,
      frameId: 'frame-1',
      aadTarget: 'a_bob00000000000',
      ciphertextB64: ciphertext,
    );
    expect(clear, 'ping from alice');
  });

  test('tampered ciphertext is rejected', () async {
    final alice = await X25519().newKeyPair();
    final alicePub = await alice.extractPublicKey();
    final bob = await X25519().newKeyPair();
    final bobPub = await bob.extractPublicKey();
    final ciphertext = await encryptPayload(
      senderDhKeyPair: alice,
      recipientDhPubkey: bobPub,
      frameId: 'frame-2',
      aadTarget: 'general',
      plaintext: 'channel hello',
    );
    final wire = base64Decode(ciphertext);
    wire[wire.length - 1] ^= 1;
    expect(
      decryptPayload(
        recipientDhKeyPair: bob,
        senderDhPubkey: alicePub,
        frameId: 'frame-2',
        aadTarget: 'general',
        ciphertextB64: base64Encode(wire),
      ),
      throwsA(anything),
    );
  });

  test('wrong AAD target is rejected', () async {
    final alice = await X25519().newKeyPair();
    final alicePub = await alice.extractPublicKey();
    final bob = await X25519().newKeyPair();
    final bobPub = await bob.extractPublicKey();
    final ciphertext = await encryptPayload(
      senderDhKeyPair: alice,
      recipientDhPubkey: bobPub,
      frameId: 'frame-3',
      aadTarget: 'general',
      plaintext: 'x',
    );
    expect(
      decryptPayload(
        recipientDhKeyPair: bob,
        senderDhPubkey: alicePub,
        frameId: 'frame-3',
        aadTarget: 'other-channel',
        ciphertextB64: ciphertext,
      ),
      throwsA(anything),
    );
  });
}

List<int> hexDecode(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
