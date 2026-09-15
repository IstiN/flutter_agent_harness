/// DAP/1 wire crypto for the hub-backed messaging fabric (docs/protocol.md):
/// canonical-JSON frame signatures (Ed25519) and end-to-end payload
/// encryption (X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305).
///
/// Deliberately a local implementation — the same rule as the hub's own
/// signature check (`local_hub.dart`): independent implementations keep a
/// wire-format bug in one side from cancelling out the other. The interop
/// tests (`test/hub/hub_messaging_repository_test.dart`) run this code
/// against a `fa_hub_client` peer over the fake hub, pinning the exact
/// byte-level contract.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'hub_identity.dart';

final _sha256 = Sha256();
final _ed25519 = Ed25519();
final _x25519 = X25519();
final _mac = Hmac.sha256();
final _aead = Chacha20.poly1305Aead();
const _hkdfInfo = 'dap1/v1';

/// Recursively key-sorted, whitespace-free JSON encoding of [value].
String hubCanonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

/// The DAP/1 signing payload for [frame] (which must not yet contain `sig`):
/// `dap1|op|ts|hex(sha256(canonicalJson(frame)))`.
Future<String> hubSigningPayload(Map<String, dynamic> frame) async {
  final digest = await _sha256.hash(utf8.encode(hubCanonicalJson(frame)));
  return 'dap1|${frame['op']}|${frame['ts']}|${hubHex(digest.bytes)}';
}

/// Signs [frame] (without its `sig` field) with [identity]'s Ed25519 key.
Future<String> hubSignFrame(
  Map<String, dynamic> frame,
  HubIdentity identity,
) async {
  final payload = await hubSigningPayload(frame);
  final sig = await _ed25519.sign(
    utf8.encode(payload),
    keyPair: identity.signingKeyPair,
  );
  return base64Encode(sig.bytes);
}

/// HKDF-SHA256 extract+expand per RFC 5869 (the cryptography package's
/// Hkdf carries no `info` parameter, so expand runs on raw HMAC).
Future<List<int>> _hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) async {
  final prk = await _mac.calculateMac(ikm, secretKey: SecretKey(salt));
  var previous = const <int>[];
  var okm = <int>[];
  for (var counter = 1; okm.length < length && counter <= 255; counter++) {
    final block = await _mac.calculateMac(
      [...previous, ...info, counter],
      secretKey: SecretKey(prk.bytes),
    );
    previous = block.bytes;
    okm = [...okm, ...block.bytes];
  }
  return okm.sublist(0, length);
}

/// The DM payload key: ECDH(sender DH priv, recipient DH pub) →
/// HKDF-SHA256(salt = frame id, info = "dap1/v1") → 32 bytes.
Future<SecretKey> _deriveDmKey(
  SimpleKeyPair senderDh,
  SimplePublicKey recipientDhPub,
  String frameId,
) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: senderDh,
    remotePublicKey: recipientDhPub,
  );
  final key = await _hkdfSha256(
    ikm: await shared.extractBytes(),
    salt: utf8.encode(frameId),
    info: utf8.encode(_hkdfInfo),
    length: 32,
  );
  return SecretKey(key);
}

/// Encrypts [plaintext] for the holder of the DH private key matching
/// [recipientDhPubkey]. [aadTarget] is the recipient agent id (DM).
/// ciphertext = base64(nonce(12) || ct || tag(16)),
/// AAD = `dap1|<frameId>|<aadTarget>`.
Future<String> hubEncryptPayload({
  required HubIdentity sender,
  required SimplePublicKey recipientDhPubkey,
  required String frameId,
  required String aadTarget,
  required String plaintext,
}) async {
  final key = await _deriveDmKey(
    sender.dhKeyPair,
    recipientDhPubkey,
    frameId,
  );
  final box = await _aead.encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    aad: utf8.encode('dap1|$frameId|$aadTarget'),
  );
  return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// Decrypts a DM payload produced by [hubEncryptPayload]: [ourIdentity]
/// holds the recipient DH key, [senderDhPubkey] is the sender's DH public
/// key (from a whois). Throws on a missing key or tampered payload.
Future<String> hubDecryptPayload({
  required HubIdentity ourIdentity,
  required SimplePublicKey senderDhPubkey,
  required String frameId,
  required String ciphertextB64,
}) async {
  final raw = base64Decode(ciphertextB64);
  if (raw.length < 12 + 16) throw ArgumentError('ciphertext too short');
  final key = await _deriveDmKey(ourIdentity.dhKeyPair, senderDhPubkey, frameId);
  final clear = await _aead.decrypt(
    SecretBox(
      raw.sublist(12, raw.length - 16),
      nonce: raw.sublist(0, 12),
      mac: Mac(raw.sublist(raw.length - 16)),
    ),
    secretKey: key,
    aad: utf8.encode('dap1|$frameId|${ourIdentity.agentId}'),
  );
  return utf8.decode(clear);
}
