import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:fa_hub_client/src/hub/payload_crypto.dart';

Future<void> main() async {
  // raw vendored-style
  final a = await X25519().newKeyPair();
  final aPub = await a.extractPublicKey();
  final b = await X25519().newKeyPair();
  final bPub = await b.extractPublicKey();
  final ct = await encryptPayload(senderDhKeyPair: a, recipientDhPubkey: bPub, frameId: 'f', aadTarget: 't', plaintext: 'x');
  final clear = await decryptPayload(recipientDhKeyPair: b, senderDhPubkey: aPub, frameId: 'f', aadTarget: 't', ciphertextB64: ct);
  print('raw ok: $clear');

  // via extracted b64 pubs (what DapIdentity does)
  final aPubB64 = base64Encode(aPub.bytes);
  final bPubB64 = base64Encode(bPub.bytes);
  final ct2 = await encryptPayload(
    senderDhKeyPair: a,
    recipientDhPubkey: SimplePublicKey(base64Decode(bPubB64), type: KeyPairType.x25519),
    frameId: 'f', aadTarget: 't', plaintext: 'x');
  final clear2 = await decryptPayload(
    recipientDhKeyPair: b,
    senderDhPubkey: SimplePublicKey(base64Decode(aPubB64), type: KeyPairType.x25519),
    frameId: 'f', aadTarget: 't', ciphertextB64: ct2);
  print('b64 ok: $clear2');

  // keypair-from-seed round trip
  final aPriv = await a.extractPrivateKeyBytes();
  final a2 = await X25519().newKeyPairFromSeed(aPriv);
  final a2Pub = await a2.extractPublicKey();
  print('seed pub same: ${a2Pub.bytes.length} ${base64Encode(a2Pub.bytes) == base64Encode(aPub.bytes)}');
}
