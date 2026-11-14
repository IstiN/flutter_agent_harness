// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:test/test.dart';

void main() {
  test('fanet1 seal carries sender pub and exact frame/channel AD', () async {
    final sender = await hubGenerateX25519KeyPair();
    final recipient = await hubGenerateX25519KeyPair();
    final recipientPub = await recipient.extractPublicKey();
    const frameId = 'minted-msg-id';
    const channel = 'dm:user:user-1:agent@device-1';

    final sealed = await hubSealFanet1(
      senderDhKeyPair: sender,
      recipientDhPubkey: recipientPub,
      frameId: frameId,
      aadTarget: channel,
      plaintext: 'viewer text',
    );
    final opened = hubTryOpenFanet1(sealed)!;
    final senderPub = await sender.extractPublicKey();
    expect(opened.senderPubkey.bytes, senderPub.bytes);
    expect(
      await hubDecryptPayloadWithKeyPair(
        recipientDhKeyPair: recipient,
        senderDhPubkey: opened.senderPubkey,
        frameId: frameId,
        aadTarget: channel,
        ciphertextB64: opened.ciphertextB64,
      ),
      'viewer text',
    );
    expect(
      () => hubDecryptPayloadWithKeyPair(
        recipientDhKeyPair: recipient,
        senderDhPubkey: opened.senderPubkey,
        frameId: 'different-msg-id',
        aadTarget: channel,
        ciphertextB64: opened.ciphertextB64,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}
