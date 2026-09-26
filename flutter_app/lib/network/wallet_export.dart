// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Passphrase-protected wallet export/import.
///
/// Export format (JSON):
/// ```
/// {v:1, kdf:'argon2id', salt:b64, m:65536, t:3, p:2,
///  cipher:'aes-256-gcm', nonce:b64, ct:b64}
/// ```
/// where `ct` is `ciphertext || tag` of the wallet JSON encrypted under
/// `Argon2id(passphrase, salt, memory=m KiB, iterations=t, lanes=p)`.
///
/// KDF choice: Argon2id via pointycastle's `Argon2BytesGenerator` —
/// pure Dart (register64 fallback; the native-int impl is selected only
/// behind a conditional export), so it compiles for web. pointycastle is
/// already in the resolved dependency graph; the orchestrator promotes it
/// to a direct dependency.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
// pointycastle is promoted to a direct dependency by the orchestrator; it
// is already resolved transitively.
// ignore: depend_on_referenced_packages
import 'package:pointycastle/key_derivators/api.dart';
// ignore: depend_on_referenced_packages
import 'package:pointycastle/key_derivators/argon2.dart';

import 'key_wallet.dart';

/// Thrown when an export cannot be imported — wrong passphrase, tampered
/// ciphertext, or malformed export JSON. Never carries partial state.
final class WalletImportException implements Exception {
  /// Creates an exception with a human-readable [message].
  const WalletImportException(this.message);

  /// Why the import failed (never contains key material or passphrases).
  final String message;

  @override
  String toString() => 'WalletImportException: $message';
}

/// Argon2id cost parameters recorded in the export.
final class WalletKdfParams {
  /// Creates parameters; defaults follow the spec (64 MiB, 3 passes,
  /// 2 lanes).
  const WalletKdfParams({
    this.memoryKiB = 65536,
    this.iterations = 3,
    this.lanes = 2,
  });

  /// Argon2 memory cost in KiB.
  final int memoryKiB;

  /// Argon2 iterations (passes).
  final int iterations;

  /// Argon2 lanes (parallelism).
  final int lanes;
}

final _random = Random.secure();
final _aesGcm = AesGcm.with256bits();

/// Exports [wallet] as passphrase-encrypted JSON (see the library doc).
///
/// [kdf] overrides the Argon2id cost parameters — for tests; production
/// uses the spec defaults.
Future<String> exportWallet(
  KeyWallet wallet,
  String passphrase, {
  WalletKdfParams kdf = const WalletKdfParams(),
}) async {
  final salt = Uint8List.fromList(
    List.generate(16, (_) => _random.nextInt(256)),
  );
  final nonce = Uint8List.fromList(
    List.generate(12, (_) => _random.nextInt(256)),
  );
  final key = _deriveKey(passphrase, salt, kdf);
  final box = await _aesGcm.encrypt(
    utf8.encode(wallet.serialize()),
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  return jsonEncode({
    'v': 1,
    'kdf': 'argon2id',
    'salt': base64Encode(salt),
    'm': kdf.memoryKiB,
    't': kdf.iterations,
    'p': kdf.lanes,
    'cipher': 'aes-256-gcm',
    'nonce': base64Encode(nonce),
    'ct': base64Encode([...box.cipherText, ...box.mac.bytes]),
  });
}

/// Imports a wallet exported by [exportWallet].
///
/// Throws [WalletImportException] on a wrong passphrase, tampered
/// ciphertext, or malformed export — the function either returns a complete
/// wallet or throws; no partial state escapes.
Future<KeyWallet> importWallet(String json, String passphrase) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on Object {
    throw const WalletImportException('export is not valid JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw const WalletImportException('export root is not an object');
  }
  try {
    if (decoded['v'] != 1) {
      throw const WalletImportException('unsupported export version');
    }
    if (decoded['kdf'] != 'argon2id') {
      throw const WalletImportException('unsupported kdf');
    }
    if (decoded['cipher'] != 'aes-256-gcm') {
      throw const WalletImportException('unsupported cipher');
    }
    final salt = base64Decode(decoded['salt']! as String);
    final nonce = base64Decode(decoded['nonce']! as String);
    final ct = base64Decode(decoded['ct']! as String);
    final kdf = WalletKdfParams(
      memoryKiB: decoded['m']! as int,
      iterations: decoded['t']! as int,
      lanes: decoded['p']! as int,
    );
    if (ct.length < 16) {
      throw const WalletImportException('ciphertext too short');
    }
    final key = _deriveKey(passphrase, salt, kdf);
    final box = SecretBox(
      ct.sublist(0, ct.length - 16),
      nonce: nonce,
      mac: Mac(ct.sublist(ct.length - 16)),
    );
    final clear = await _aesGcm.decrypt(box, secretKey: SecretKey(key));
    return KeyWallet.fromJsonString(utf8.decode(clear));
  } on WalletImportException {
    rethrow;
  } on SecretBoxAuthenticationError {
    throw const WalletImportException('wrong passphrase or corrupted export');
  } on Object {
    throw const WalletImportException('malformed export');
  }
}

Uint8List _deriveKey(String passphrase, Uint8List salt, WalletKdfParams kdf) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: kdf.iterations,
        memory: kdf.memoryKiB,
        lanes: kdf.lanes,
        version: Argon2Parameters.ARGON2_VERSION_13,
      ),
    );
  final out = Uint8List(32);
  generator.deriveKey(Uint8List.fromList(utf8.encode(passphrase)), 0, out, 0);
  return out;
}
