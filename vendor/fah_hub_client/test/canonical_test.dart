import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

void main() {
  test('canonicalJson sorts keys recursively, no whitespace', () {
    final messy = <String, dynamic>{
      'b': 1,
      'a': <String, dynamic>{'z': 1, 'y': [3, 2]},
    };
    expect(canonicalJson(messy), '{"a":{"y":[3,2],"z":1},"b":1}');
  });

  test('signingPayload matches the spec formula', () async {
    final frame = <String, dynamic>{
      'op': 'hello',
      'v': 1,
      'pubkey': 'a2V5',
      'nonce': '0011223344556677',
      'ts': 1700000000000,
    };
    // Independent reconstruction: sha256 over canonical JSON of the frame
    // without the sig field, embedded in "dap1|op|ts|<hex>".
    final digest = await Sha256().hash(
      utf8.encode('{"nonce":"0011223344556677","op":"hello",'
          '"pubkey":"a2V5","ts":1700000000000,"v":1}'),
    );
    final hex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(
      await signingPayload(frame),
      'dap1|hello|1700000000000|$hex',
    );
  });

  test('signFrame/verifyFrame round-trip, and tamper detection', () async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final frame = <String, dynamic>{
      'op': 'send',
      'channel': 'general',
      'id': 'x1',
      'ts': 1700000000001,
      'ciphertext': 'Zm9v',
    };
    final sig = await signFrame(frame, keyPair);
    expect(await verifyFrame(frame, sig, publicKey), isTrue);
    expect(
      await verifyFrame({...frame, 'ciphertext': 'YmFy'}, sig, publicKey),
      isFalse,
    );
  });

  test('hexEncode and randomHex', () {
    expect(hexEncode([0, 1, 255, 16]), '0001ff10');
    final a = randomHex(32);
    final b = randomHex(32);
    expect(a, hasLength(32));
    expect(a, isNot(equals(b)));
    expect(a, matches(RegExp(r'^[0-9a-f]+$')));
  });

  test('newFrameId is uuid-v4 shaped and unique', () {
    final ids = {for (var i = 0; i < 100; i++) newFrameId()};
    expect(ids, hasLength(100));
    expect(
      ids.first,
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      )),
    );
  });
}
