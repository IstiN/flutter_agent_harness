/// DAP/1 end-to-end payload crypto (docs/protocol.md "Crypto"):
///
/// * Key agreement: X25519 ECDH, sender DH privkey x recipient DH pubkey
///   (DM) or channel keypair pubkey (channels).
/// * Key = HKDF-SHA256(ikm = ecdh_secret, salt = frame_id, info = "dap1/v1")
///   → 32 bytes (RFC 5869; the cryptography package's Hkdf has no `info`
///   parameter, so it is implemented here on top of Hmac.sha256).
/// * AEAD = ChaCha20-Poly1305 (IETF, 12-byte nonce).
/// * ciphertext = base64( nonce(12) || ct || tag(16) ).
/// * AAD = "dap1|" + frame_id + "|" + (channel or recipient agentId).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _hkdfInfo = 'dap1/v1';
const _nonceLength = 12;
const _tagLength = 16;
final _macAlgorithm = Hmac.sha256();
final _aead = Chacha20.poly1305Aead();
final _x25519 = X25519();
final _random = Random.secure();

/// HKDF-SHA256 extract+expand per RFC 5869.
Future<Uint8List> hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) async {
  // RFC 5869 extract: PRK = HMAC-Hash(key = salt, message = IKM)
  final prk = await _macAlgorithm.calculateMac(
    ikm,
    secretKey: SecretKey(salt),
  );
  var okm = <int>[];
  var previous = const <int>[];
  var counter = 1;
  while (okm.length < length) {
    final block = await _macAlgorithm.calculateMac(
      [...previous, ...info, counter],
      secretKey: SecretKey(prk.bytes),
    );
    previous = block.bytes;
    okm = [...okm, ...block.bytes];
    counter++;
  }
  return Uint8List.fromList(okm.sublist(0, length));
}

/// Encrypts [plaintext] for the holder of the DH private key matching
/// [recipientDhPubkey]. [aadTarget] is the channel name (channel send) or
/// recipient agentId (DM).
Future<String> encryptPayload({
  required SimpleKeyPair senderDhKeyPair,
  required SimplePublicKey recipientDhPubkey,
  required String frameId,
  required String aadTarget,
  required String plaintext,
}) async {
  final key = await _deriveKey(
    senderDhKeyPair,
    recipientDhPubkey,
    frameId,
  );
  final nonce = Uint8List.fromList(
    List.generate(_nonceLength, (_) => _random.nextInt(256)),
  );
  final box = await _aead.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: utf8.encode('dap1|$frameId|$aadTarget'),
  );
  return base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// Decrypts a payload produced by [encryptPayload]. [aadTarget] must equal
/// the sender's. Throws on wrong key or tampered ciphertext.
Future<String> decryptPayload({
  required SimpleKeyPair recipientDhKeyPair,
  required SimplePublicKey senderDhPubkey,
  required String frameId,
  required String aadTarget,
  required String ciphertextB64,
}) async {
  final data = base64Decode(ciphertextB64);
  final key = await _deriveKey(
    recipientDhKeyPair,
    senderDhPubkey,
    frameId,
  );
  final box = SecretBox(
    data.sublist(_nonceLength, data.length - _tagLength),
    nonce: data.sublist(0, _nonceLength),
    mac: Mac(data.sublist(data.length - _tagLength)),
  );
  final clear = await _aead.decrypt(
    box,
    secretKey: SecretKey(key),
    aad: utf8.encode('dap1|$frameId|$aadTarget'),
  );
  return utf8.decode(clear);
}

Future<Uint8List> _deriveKey(
  SimpleKeyPair myKeyPair,
  SimplePublicKey remotePubkey,
  String frameId,
) async {
  final ecdhSecret = await _x25519.sharedSecretKey(
    keyPair: myKeyPair,
    remotePublicKey: remotePubkey,
  );
  return hkdfSha256(
    ikm: await ecdhSecret.extractBytes(),
    salt: utf8.encode(frameId),
    info: utf8.encode(_hkdfInfo),
    length: 32,
  );
}
