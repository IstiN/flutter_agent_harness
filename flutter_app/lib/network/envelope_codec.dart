// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// 'fanet1' channel envelope crypto — DAP/1-compatible primitives.
///
/// The DAP/1 primitives (X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305,
/// AAD `dap1|<frameId>|<channelName>`) are ported mechanically from
/// `fa_hub_client-0.2.8/lib/src/hub/payload_crypto.dart` (MIT license).
/// That file is NOT imported: its package barrel pulls in `dart:io`, which
/// would break the web build of this app.
///
/// fa_network Envelopes carry no sender X25519 pubkey, so raw DAP/1
/// ciphertext would be undecryptable by other members. [EnvelopeCodec]
/// therefore wraps ciphertext in a self-describing binary frame:
///
/// ```
/// payload = base64( 0x01 || spk(32) || nonce(12) || ct || tag(16) )
/// ```
///
/// where `spk` is the sender's X25519 public key and `nonce || ct || tag`
/// is the raw DAP/1 AEAD output. Recipients extract `spk` from the frame
/// and run the standard DAP/1 decrypt path.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when an envelope payload cannot be decrypted — wrong channel key,
/// tampered ciphertext/tag, AAD mismatch, or malformed input. Callers must
/// catch this and render a placeholder; it must never crash the UI.
final class EnvelopeCryptoException implements Exception {
  /// Creates an exception with a human-readable [message].
  const EnvelopeCryptoException(this.message);

  /// Why decryption failed (never contains key material or plaintext).
  final String message;

  @override
  String toString() => 'EnvelopeCryptoException: $message';
}

/// 'fanet1' envelope encrypt/decrypt (see the library doc for the format).
final class EnvelopeCodec {
  /// Creates a codec. Stateless — one instance can encrypt while another
  /// decrypts.
  const EnvelopeCodec();

  /// Binary frame version byte.
  static const frameVersion = 1;

  static const _hkdfInfo = 'dap1/v1';
  static const _nonceLength = 12;
  static const _tagLength = 16;
  static const _spkLength = 32;
  static const _minFrameLength = 1 + _spkLength + _nonceLength + _tagLength;

  static final _macAlgorithm = Hmac.sha256();
  static final _aead = Chacha20.poly1305Aead();
  static final _x25519 = X25519();
  static final _random = Random.secure();

  /// Generates a fresh X25519 keypair, returning base64-encoded
  /// `(pub, priv)` (32 bytes each decoded).
  static Future<({String pub, String priv})> newX25519KeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final data = await keyPair.extract();
    return (
      pub: base64Encode(data.publicKey.bytes),
      priv: base64Encode(data.bytes),
    );
  }

  /// Rebuilds an X25519 [SimpleKeyPair] from a base64-encoded private key
  /// produced by [newX25519KeyPair].
  Future<SimpleKeyPair> keyPairFromPriv(String privB64) =>
      _x25519.newKeyPairFromSeed(base64Decode(privB64));

  /// Rebuilds an X25519 [SimplePublicKey] from base64-encoded bytes.
  SimplePublicKey publicKeyFromB64(String pubB64) =>
      SimplePublicKey(base64Decode(pubB64), type: KeyPairType.x25519);

  /// Encrypts [plaintext] for the channel whose members hold the private
  /// key matching [channelPub]. Returns the base64 'fanet1' frame.
  Future<String> encrypt({
    required SimpleKeyPair senderIdentity,
    required SimplePublicKey channelPub,
    required String frameId,
    required String channelName,
    required String plaintext,
  }) async {
    final key = await _deriveKey(senderIdentity, channelPub, frameId);
    final nonce = Uint8List.fromList(
      List.generate(_nonceLength, (_) => _random.nextInt(256)),
    );
    final box = await _aead.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode('dap1|$frameId|$channelName'),
    );
    final senderPub = await senderIdentity.extractPublicKey();
    return base64Encode([
      frameVersion,
      ...senderPub.bytes,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Decrypts a 'fanet1' frame produced by [encrypt]. [frameId] and
  /// [channelName] must equal the sender's (they are AEAD AAD).
  ///
  /// Returns the sender's base64 X25519 pubkey and the plaintext.
  /// Throws [EnvelopeCryptoException] on any failure.
  Future<({String senderPub, String plaintext})> decrypt({
    required SimpleKeyPair channelKeyPair,
    required String frameId,
    required String channelName,
    required String payloadB64,
  }) async {
    try {
      final data = base64Decode(payloadB64);
      if (data.length < _minFrameLength) {
        throw const EnvelopeCryptoException('fanet1 frame too short');
      }
      if (data[0] != frameVersion) {
        throw EnvelopeCryptoException(
          'unsupported fanet1 frame version ${data[0]}',
        );
      }
      final spk = SimplePublicKey(
        data.sublist(1, 1 + _spkLength),
        type: KeyPairType.x25519,
      );
      final key = await _deriveKey(channelKeyPair, spk, frameId);
      final box = SecretBox(
        data.sublist(1 + _spkLength + _nonceLength, data.length - _tagLength),
        nonce: data.sublist(1 + _spkLength, 1 + _spkLength + _nonceLength),
        mac: Mac(data.sublist(data.length - _tagLength)),
      );
      final clear = await _aead.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode('dap1|$frameId|$channelName'),
      );
      return (
        senderPub: base64Encode(spk.bytes),
        plaintext: utf8.decode(clear),
      );
    } on EnvelopeCryptoException {
      rethrow;
    } on Object {
      // Wrong key, tampered ciphertext/tag, malformed base64 — all collapse
      // into one typed exception so callers render a placeholder.
      throw const EnvelopeCryptoException('envelope decryption failed');
    }
  }

  /// HKDF-SHA256 extract+expand per RFC 5869 (ported from fa_hub_client;
  /// the cryptography package's Hkdf has no `info` parameter).
  static Future<Uint8List> hkdfSha256({
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
      if (counter > 255) {
        throw StateError('HKDF exceeded RFC 5869 iteration cap');
      }
      final block = await _macAlgorithm.calculateMac([
        ...previous,
        ...info,
        counter,
      ], secretKey: SecretKey(prk.bytes));
      previous = block.bytes;
      okm = [...okm, ...block.bytes];
      counter++;
    }
    return Uint8List.fromList(okm.sublist(0, length));
  }

  static Future<Uint8List> _deriveKey(
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
}
