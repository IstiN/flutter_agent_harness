// `.fahx` import for the extension (issue #34 item 3, §S6 fallback tier):
// decrypts a passphrase-protected provider export written by the CLI's
// `fa config export-providers` and turns it into registry entries.
//
// Bit-compatible PORT of the crypto in `lib/src/cli/provider_export.dart`
// (PBKDF2-HMAC-SHA256 key derivation + HMAC-SHA256-CTR keystream,
// encrypt-then-MAC). That file is bin-only (dart:io for the default
// environment lookup), so the web extension carries this pure copy — the
// roundtrip against the CLI's own encrypt output is pinned in
// `test/fahx_import_test.dart`.
//
// Every failure (bad shape, unsupported version/kdf, wrong passphrase,
// tampered ciphertext) throws [FahxException] loudly; callers write
// nothing unless the whole decrypt succeeds.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Envelope + payload version (matches the CLI exporter).
const int fahxVersion = 1;

/// One decrypted `.fahx` provider entry.
typedef FahxProvider = ({
  String name,
  String apiType,
  String baseUrl,
  String modelId,
  String? keyName,
  String? key,
});

/// A loud, single failure type for every `.fahx` import error.
final class FahxException implements Exception {
  const FahxException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Decodes + decrypts + verifies a `.fahx` file's contents into entries.
/// Pure: reads nothing, writes nothing.
List<FahxProvider> importFahxProviders(String contents, String passphrase) {
  final Object? envelope;
  try {
    envelope = jsonDecode(contents);
  } on FormatException {
    throw const FahxException('.fahx file is not valid JSON');
  }
  if (envelope is! Map<String, dynamic>) {
    throw const FahxException('.fahx file is not valid JSON');
  }
  final plaintext = decryptFahx(envelope, passphrase);
  final Object? payload;
  try {
    payload = jsonDecode(plaintext);
  } on FormatException {
    throw const FahxException('.fahx payload is not valid JSON');
  }
  if (payload is! Map<String, dynamic> ||
      payload['version'] != fahxVersion ||
      payload['providers'] is! List) {
    throw const FahxException('.fahx payload is malformed');
  }
  final imported = <FahxProvider>[];
  for (final raw in payload['providers'] as List) {
    if (raw is! Map<String, dynamic>) {
      throw const FahxException('.fahx payload is malformed');
    }
    final name = raw['name'];
    final apiType = raw['apiType'];
    final baseUrl = raw['baseUrl'];
    final modelId = raw['modelId'];
    if (name is! String ||
        name.isEmpty ||
        apiType is! String ||
        baseUrl is! String ||
        baseUrl.isEmpty ||
        modelId is! String) {
      throw const FahxException('.fahx payload is malformed');
    }
    final keyName = raw['keyName'];
    final key = raw['key'];
    imported.add((
      name: name,
      apiType: apiType,
      baseUrl: baseUrl,
      modelId: modelId,
      keyName: keyName is String && keyName.isNotEmpty ? keyName : null,
      key: key is String && key.isNotEmpty ? key : null,
    ));
  }
  return imported;
}

/// Decrypts a `.fahx` envelope map. Wrong passphrase and tampered
/// ciphertext are indistinguishable by design (same authentication
/// failure) — both throw [FahxException].
String decryptFahx(Map<String, dynamic> envelope, String passphrase) {
  if (envelope['version'] != fahxVersion) {
    throw FahxException('unsupported .fahx version: ${envelope['version']}');
  }
  final kdf = envelope['kdf'];
  if (kdf is! Map<String, dynamic> || kdf['algo'] != 'pbkdf2-sha256') {
    throw const FahxException('unsupported .fahx kdf (expected pbkdf2-sha256)');
  }
  final iterations = kdf['iterations'];
  final saltB64 = kdf['salt'];
  final nonceB64 = envelope['nonce'];
  final ctB64 = envelope['ct'];
  if (iterations is! int ||
      iterations < 1 ||
      saltB64 is! String ||
      nonceB64 is! String ||
      ctB64 is! String) {
    throw const FahxException('.fahx envelope is malformed');
  }
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List blob;
  try {
    salt = base64Decode(saltB64);
    nonce = base64Decode(nonceB64);
    blob = base64Decode(ctB64);
  } on FormatException {
    throw const FahxException('.fahx envelope is malformed');
  }
  if (blob.length <= 32) {
    throw const FahxException('.fahx envelope is malformed');
  }
  final ciphertext = blob.sublist(0, blob.length - 32);
  final tag = blob.sublist(blob.length - 32);
  final keys = _deriveKeys(passphrase, salt, iterations);
  final expected = crypto.Hmac(
    crypto.sha256,
    keys.sublist(32),
  ).convert([...nonce, ...ciphertext]).bytes;
  if (!_constantTimeEquals(expected, tag)) {
    throw const FahxException('wrong passphrase or corrupted .fahx file');
  }
  return utf8.decode(
    _xor(ciphertext, _keystream(keys.sublist(0, 32), nonce, ciphertext.length)),
  );
}

// -- Crypto (package:crypto only) — verbatim port of provider_export.dart --

/// PBKDF2-HMAC-SHA256 (RFC 2898).
Uint8List pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int dkLen,
) {
  final hmac = crypto.Hmac(crypto.sha256, password);
  final out = BytesBuilder(copy: false);
  var block = 1;
  while (out.length < dkLen) {
    var u = hmac.convert([
      ...salt,
      block >> 24,
      block >> 16,
      block >> 8,
      block,
    ]).bytes;
    final t = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
    block++;
  }
  return Uint8List.fromList(out.toBytes()).sublist(0, dkLen);
}

/// HMAC-SHA256 keystream in 32-byte blocks: block `n` =
/// HMAC(key, nonce ‖ u32le(n)).
List<int> _keystream(List<int> key, List<int> nonce, int length) {
  final hmac = crypto.Hmac(crypto.sha256, key);
  final out = BytesBuilder(copy: false);
  var counter = 0;
  while (out.length < length) {
    out.add(
      hmac.convert([
        ...nonce,
        counter & 0xff,
        (counter >> 8) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 24) & 0xff,
      ]).bytes,
    );
    counter++;
  }
  return out.toBytes();
}

List<int> _xor(List<int> data, List<int> keystream) => [
  for (var i = 0; i < data.length; i++) data[i] ^ keystream[i],
];

bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _deriveKeys(String passphrase, List<int> salt, int iterations) =>
    pbkdf2Sha256(utf8.encode(passphrase), salt, iterations, 64);
