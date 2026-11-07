/// The `.fahx` provider-export format codec (issue #34 item 3, §S6
/// fallback tier): envelope validation/decryption, provider-entry parsing,
/// and the crypto primitives — one pure implementation shared by the CLI's
/// `fa config export-providers` (`lib/src/cli/provider_export.dart`, which
/// owns the io-bound command) and the browser extension's
/// `browser_ext/dart/src/fahx_import.dart` (which cannot import that
/// dart:io-bound file).
///
/// Envelope (JSON, versioned):
///
/// ```json
/// {"version":1,
///  "kdf":{"algo":"pbkdf2-sha256","iterations":210000,"salt":"<b64>"},
///  "nonce":"<b64>",
///  "ct":"<b64>"}
/// ```
///
/// `ct` = XOR(plaintext, HMAC-CTR keystream) ‖ HMAC-SHA256(macKey,
/// nonce ‖ ciphertext) — encrypt-then-MAC; both keys derive from one
/// PBKDF2-HMAC-SHA256 run (enc key = first 32 bytes, mac key = last 32).
/// Wrong passphrase or a tampered file fails LOUDLY with [FahxException];
/// nothing is ever written on a failed decrypt.
///
/// The primitives run on a stateful SHA-256/HMAC core: neither
/// package:crypto (fresh sink tree per message) nor pointycastle (a fresh
/// ByteData view per word) can reuse HMAC state, and a 210000-round KDF
/// was allocating ~4 KB per iteration → GC storms (issue #1850 AC1).
/// The envelope bytes are unchanged and pinned by
/// test/cli/provider_export_compat_test.dart goldens and the browser
/// extension's roundtrip test.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A loud, single failure type for every `.fahx` format error: bad shape,
/// unsupported version/kdf, wrong passphrase, tampered ciphertext.
final class FahxException implements Exception {
  const FahxException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One decoded `providers` list entry: the required fields plus the
/// optional keyName/key (null unless a non-empty String).
typedef FahxProviderEntry = ({
  String name,
  String apiType,
  String baseUrl,
  String modelId,
  String? keyName,
  String? key,
});

/// Validates one `providers` list entry and decodes its fields; a missing
/// or non-string name/apiType/baseUrl/modelId (or an empty name/baseUrl)
/// is malformed.
FahxProviderEntry parseFahxProviderEntry(Object? raw) {
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
  return (
    name: name,
    apiType: apiType,
    baseUrl: baseUrl,
    modelId: modelId,
    keyName: keyName is String && keyName.isNotEmpty ? keyName : null,
    key: key is String && key.isNotEmpty ? key : null,
  );
}

/// Validates the `.fahx` [envelope] (version/kdf/field shapes), decodes the
/// base64 payload, derives the enc‖mac keys from [passphrase], verifies the
/// authentication tag in constant time, and returns the decrypted UTF-8
/// plaintext. Wrong passphrase and tampered ciphertext are
/// indistinguishable by design — both throw [FahxException].
String decryptFahxEnvelope(
  Map<String, dynamic> envelope,
  String passphrase, {
  required int version,
}) {
  if (envelope['version'] != version) {
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
  final keys = pbkdf2Sha256(utf8.encode(passphrase), salt, iterations, 64);
  final expected = fahxMacTag(keys.sublist(32), nonce, ciphertext);
  if (!_constantTimeEquals(expected, tag)) {
    throw const FahxException('wrong passphrase or corrupted .fahx file');
  }
  return utf8.decode(
    fahxXor(
      ciphertext,
      fahxKeystream(keys.sublist(0, 32), nonce, ciphertext.length),
    ),
  );
}

/// Allocation-free SHA-256 (FIPS 180-4) with mid-state capture for HMAC.
///
/// Neither crypto package in the dependency graph can reuse HMAC state:
/// package:crypto's Converter API allocates a fresh sink tree per message
/// (~4 KB per 210000-round KDF iteration → GC storms), and pointycastle's
/// SHA256Digest wraps a fresh ByteData view around every word (same churn).
/// This core implements the same primitives with reusable buffers; byte
/// identity is pinned by test/cli/provider_export_compat_test.dart
/// (published PBKDF2 vectors + envelope goldens from the original
/// implementation).
final class _Sha256 {
  static const List<int> _initial = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  static const List<int> _k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final Uint32List _h = Uint32List.fromList(_initial);
  final Uint32List _w = Uint32List(64);
  final Uint8List _buf = Uint8List(64);
  final Uint8List _pad = Uint8List(128);
  int _bufLen = 0;
  int _totalLen = 0;

  /// True mid-state restore: [state] is the `_h` of a hasher that has
  /// absorbed exactly one aligned 64-byte block (see [_HmacSha256]).
  void _restore(Uint32List state) {
    _h.setAll(0, state);
    _bufLen = 0;
    _totalLen = 64;
  }

  Uint32List _capture() => Uint32List.fromList(_h);

  void update(Uint8List data, int start, int end) {
    _totalLen += end - start;
    var i = start;
    if (_bufLen > 0) {
      final take = 64 - _bufLen < end - i ? 64 - _bufLen : end - i;
      _buf.setRange(_bufLen, _bufLen + take, data, i);
      _bufLen += take;
      i += take;
      if (_bufLen == 64) {
        _compress();
        _bufLen = 0;
      }
    }
    while (end - i >= 64) {
      _buf.setRange(0, 64, data, i);
      _compress();
      i += 64;
    }
    if (i < end) {
      _buf.setRange(0, end - i, data, i);
      _bufLen = end - i;
    }
  }

  /// Finalizes into [out] (32 bytes at [outOff]). The state is dead after
  /// this — [_restore] or a fresh reset reinitializes it.
  void finish(Uint8List out, int outOff) {
    final bitLenLo = (_totalLen << 3) & 0xffffffff;
    // 0x80, zeros to 56 mod 64, then the 8-byte big-endian bit length
    // (spilling into a second padding block when there is no room).
    final padLen = _bufLen < 56 ? 56 - _bufLen : 120 - _bufLen;
    final pad = _pad;
    pad.fillRange(0, padLen + 8, 0);
    pad[0] = 0x80;
    pad[padLen] = (_totalLen >> 29) & 0x7;
    pad[padLen + 4] = (bitLenLo >> 24) & 0xff;
    pad[padLen + 5] = (bitLenLo >> 16) & 0xff;
    pad[padLen + 6] = (bitLenLo >> 8) & 0xff;
    pad[padLen + 7] = bitLenLo & 0xff;
    update(pad, 0, padLen + 8);
    for (var i = 0; i < 8; i++) {
      final v = _h[i];
      out[outOff + i * 4] = (v >> 24) & 0xff;
      out[outOff + i * 4 + 1] = (v >> 16) & 0xff;
      out[outOff + i * 4 + 2] = (v >> 8) & 0xff;
      out[outOff + i * 4 + 3] = v & 0xff;
    }
  }

  void _compress() {
    for (var j = 0; j < 16; j++) {
      final b = j * 4;
      _w[j] =
          (_buf[b] << 24) |
          (_buf[b + 1] << 16) |
          (_buf[b + 2] << 8) |
          _buf[b + 3];
    }
    for (var j = 16; j < 64; j++) {
      final w15 = _w[j - 15];
      final w2 = _w[j - 2];
      final s0 =
          ((w15 >> 7) | (w15 << 25)) ^ ((w15 >> 18) | (w15 << 14)) ^ (w15 >> 3);
      final s1 =
          ((w2 >> 17) | (w2 << 15)) ^ ((w2 >> 19) | (w2 << 13)) ^ (w2 >> 10);
      _w[j] = (_w[j - 16] + s0 + _w[j - 7] + s1) & 0xffffffff;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var j = 0; j < 64; j++) {
      final s1 =
          ((e >> 6) | (e << 26)) ^
          ((e >> 11) | (e << 21)) ^
          ((e >> 25) | (e << 7));
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (h + s1 + ch + _k[j] + _w[j]) & 0xffffffff;
      final s0 =
          ((a >> 2) | (a << 30)) ^
          ((a >> 13) | (a << 19)) ^
          ((a >> 22) | (a << 10));
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }
}

/// HMAC-SHA256 (RFC 2104) with the ipad/opad mid-states captured at
/// construction: every message restores them in place — zero allocation
/// per [start]/[update]/[finish] round.
final class _HmacSha256 {
  static const int _blockSize = 64;

  final _Sha256 _inner = _Sha256();
  final _Sha256 _outer = _Sha256();
  late final Uint32List _innerState;
  late final Uint32List _outerState;
  final Uint8List _innerDigest = Uint8List(32);
  bool _started = false;

  _HmacSha256(List<int> key) {
    final block = Uint8List(_blockSize);
    var keyBytes = key is Uint8List ? key : Uint8List.fromList(key);
    if (keyBytes.length > _blockSize) {
      final hasher = _Sha256();
      hasher
        ..update(keyBytes, 0, keyBytes.length)
        ..finish(block, 0);
      keyBytes = block;
    } else {
      block.setRange(0, keyBytes.length, keyBytes);
    }
    for (var i = 0; i < _blockSize; i++) {
      block[i] ^= 0x36;
    }
    _inner.update(block, 0, _blockSize);
    _innerState = _inner._capture();
    for (var i = 0; i < _blockSize; i++) {
      block[i] = (block[i] ^ 0x36) ^ 0x5c;
    }
    _outer.update(block, 0, _blockSize);
    _outerState = _outer._capture();
  }

  /// Begins a new message over the primed ipad state.
  void start() {
    _inner._restore(_innerState);
    _started = true;
  }

  void update(Uint8List data, int start, int end) {
    if (!_started) throw StateError('HMAC: start() first');
    _inner.update(data, start, end);
  }

  /// Writes the 32-byte tag at [outOff]; the instance is ready for the
  /// next [start].
  void finish(Uint8List out, int outOff) {
    _inner.finish(_innerDigest, 0);
    _started = false;
    _outer._restore(_outerState);
    _outer.update(_innerDigest, 0, 32);
    _outer.finish(out, outOff);
  }
}

/// One-shot HMAC over [nonce ‖ data] — the envelope tag, without the
/// full-payload spread copy the old `convert([...nonce, ...ct])` made.
Uint8List fahxMacTag(List<int> key, List<int> nonce, List<int> data) {
  final mac = _HmacSha256(key);
  final nonceBytes = nonce is Uint8List ? nonce : Uint8List.fromList(nonce);
  final dataBytes = data is Uint8List ? data : Uint8List.fromList(data);
  mac
    ..start()
    ..update(nonceBytes, 0, nonceBytes.length)
    ..update(dataBytes, 0, dataBytes.length);
  final tag = Uint8List(32);
  mac.finish(tag, 0);
  return tag;
}

/// PBKDF2-HMAC-SHA256 (RFC 2898) with per-round HMAC state reuse —
/// a 210000-iteration derivation now allocates a handful of buffers
/// once instead of a sink tree per round (issue #1850 AC1).
Uint8List pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int dkLen,
) {
  final mac = _HmacSha256(password);
  final saltBytes = salt is Uint8List ? salt : Uint8List.fromList(salt);
  final out = Uint8List(dkLen);
  final u = Uint8List(32);
  final t = Uint8List(32);
  // RFC message = salt ‖ INT(block), INT big-endian starting at 1.
  final msg = Uint8List(saltBytes.length + 4);
  msg.setRange(0, saltBytes.length, saltBytes);
  final rounds = iterations < 1 ? 1 : iterations;
  var written = 0;
  for (var block = 1; written < dkLen; block++) {
    msg[saltBytes.length] = block >> 24;
    msg[saltBytes.length + 1] = block >> 16;
    msg[saltBytes.length + 2] = block >> 8;
    msg[saltBytes.length + 3] = block & 0xff;
    mac
      ..start()
      ..update(msg, 0, msg.length)
      ..finish(u, 0);
    t.setAll(0, u);
    for (var round = 1; round < rounds; round++) {
      mac
        ..start()
        ..update(u, 0, 32)
        ..finish(u, 0);
      for (var j = 0; j < 32; j++) {
        t[j] ^= u[j];
      }
    }
    final take = dkLen - written < 32 ? dkLen - written : 32;
    out.setRange(written, written + take, t);
    written += take;
  }
  return out;
}

/// HMAC-CTR keystream in 32-byte blocks: block `n` =
/// HMAC(key, nonce ‖ u32le(n)) — an HKDF-Expand-shaped PRF stream.
Uint8List fahxKeystream(List<int> key, List<int> nonce, int length) {
  final mac = _HmacSha256(key);
  final nonceBytes = nonce is Uint8List ? nonce : Uint8List.fromList(nonce);
  final out = Uint8List(length);
  final msg = Uint8List(nonceBytes.length + 4);
  msg.setRange(0, nonceBytes.length, nonceBytes);
  final block = Uint8List(32);
  var counter = 0;
  var off = 0;
  while (off < length) {
    msg[nonceBytes.length] = counter & 0xff;
    msg[nonceBytes.length + 1] = (counter >> 8) & 0xff;
    msg[nonceBytes.length + 2] = (counter >> 16) & 0xff;
    msg[nonceBytes.length + 3] = (counter >> 24) & 0xff;
    counter++;
    mac
      ..start()
      ..update(msg, 0, msg.length)
      ..finish(block, 0);
    final take = length - off < 32 ? length - off : 32;
    out.setRange(off, off + take, block);
    off += take;
  }
  return out;
}

Uint8List fahxXor(List<int> data, List<int> keystream) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ keystream[i];
  }
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
