// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The `dapkey1` passphrase-encrypted channel-key envelope (issue #1825,
/// owner decision v3): a channel config JSON holds the private key ONLY
/// in this encrypted form; plaintext `priv` exists in memory and in the
/// pure-env CI path, never in a committed config.
///
/// Construction (on the existing `package:cryptography` primitives, the
/// same family as `hub_crypto.dart`):
/// - KDF: PBKDF2-HMAC-SHA256, 32-byte output, random 16-byte salt, the
///   iteration count stored IN the envelope (default 100k; tests lower it
///   for speed — the count is data, not a constant of the format);
/// - AEAD: ChaCha20-Poly1305, random 12-byte nonce, AAD = `dapkey1`;
/// - wire form: `dapkey1.<base64url(json)>`, where the JSON carries
///   `{v:1, kdf:'pbkdf2-sha256', iter:N, salt, nonce, ct}` (all binary
///   fields base64url). Versioned by both the prefix and `v`, so a future
///   `dapkey2` can change KDF/AEAD without ambiguity.
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// The envelope prefix every encrypted `priv` carries.
const dapKeyEnvelopePrefix = 'dapkey1.';

/// Default PBKDF2 iteration count for new envelopes (stored per-envelope).
const dapKeyDefaultIterations = 100000;

final _aead = Chacha20.poly1305Aead();

/// True when a stored `priv` value is an encrypted envelope (as opposed
/// to a plaintext base64 key from the pure-env CI path).
bool isEncryptedChannelPriv(String priv) =>
    priv.startsWith(dapKeyEnvelopePrefix);

Future<List<int>> _deriveKey(
  String passphrase,
  List<int> salt,
  int iterations,
) async {
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  final key = await kdf.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
  return key.extractBytes();
}

/// Encrypts a plaintext base64 channel private key with [passphrase].
/// [random]/[iterations] are test seams; production uses secure random
/// and [dapKeyDefaultIterations].
Future<String> encryptChannelPriv(
  String plaintextPriv,
  String passphrase, {
  Random? random,
  int iterations = dapKeyDefaultIterations,
}) async {
  final rng = random ?? Random.secure();
  final salt = List<int>.generate(16, (_) => rng.nextInt(256));
  final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
  final key = await _deriveKey(passphrase, salt, iterations);
  final box = await _aead.encrypt(
    utf8.encode(plaintextPriv),
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: utf8.encode('dapkey1'),
  );
  final payload = jsonEncode({
    'v': 1,
    'kdf': 'pbkdf2-sha256',
    'iter': iterations,
    'salt': base64Url.encode(salt),
    'nonce': base64Url.encode(nonce),
    'ct': base64Url.encode([...box.cipherText, ...box.mac.bytes]),
  });
  return '$dapKeyEnvelopePrefix${base64Url.encode(utf8.encode(payload))}';
}

/// Decrypts a `dapkey1.` envelope. Throws [FormatException] on a malformed
/// envelope, an unsupported version, or a WRONG PASSPHRASE (AEAD tag
/// mismatch) — the caller surfaces one clear error and proceeds with the
/// primary job (AC15), never a retry loop.
Future<String> decryptChannelPriv(String envelope, String passphrase) async {
  if (!isEncryptedChannelPriv(envelope)) {
    // The pure-env plaintext path is first-class: pass through unchanged.
    return envelope;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(
        base64Url.decode(envelope.substring(dapKeyEnvelopePrefix.length)),
      ),
    );
  } on Object {
    throw const FormatException('dapkey1: malformed envelope');
  }
  if (decoded is! Map || decoded['v'] != 1) {
    throw const FormatException('dapkey1: unsupported envelope version');
  }
  try {
    final iterations = decoded['iter'] as int;
    final salt = base64Url.decode(decoded['salt'] as String);
    final nonce = base64Url.decode(decoded['nonce'] as String);
    final ct = base64Url.decode(decoded['ct'] as String);
    if (ct.length < 16) throw const FormatException('dapkey1: short ct');
    final key = await _deriveKey(passphrase, salt, iterations);
    final clear = await _aead.decrypt(
      SecretBox(
        ct.sublist(0, ct.length - 16),
        nonce: nonce,
        mac: Mac(ct.sublist(ct.length - 16)),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode('dapkey1'),
    );
    return utf8.decode(clear);
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException(
      'dapkey1: cannot decrypt — wrong passphrase or corrupted key '
      '(set DAP_KEY_PASSPHRASE or rejoin with the invite)',
    );
  }
}
