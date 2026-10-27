/// Headless `fa config export-providers` (issue #34 item 3, §S6 fallback
/// tier): writes the saved custom providers + their keys to a
/// passphrase-encrypted `.fahx` file, and the matching pure import.
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
/// Wrong passphrase or a tampered file fails LOUDLY with
/// [ProviderExportException]; nothing is ever written on a failed
/// decrypt.
///
/// The primitives run on a stateful SHA-256/HMAC core below: neither
/// package:crypto (fresh sink tree per message) nor pointycastle (a fresh
/// ByteData view per word) can reuse HMAC state, and a 210000-round KDF
/// was allocating ~4 KB per iteration → GC storms (issue #1850 AC1).
/// The envelope bytes are unchanged and pinned by
/// test/cli/provider_export_compat_test.dart goldens.
///
/// Like `ext_cli.dart`, this file is bin-only (dart:io for the default
/// environment lookup); the core library never imports it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../env/execution_env.dart';
import '../model_roles/provider_catalog.dart' show parseAuthHeaderName;
import 'agent_cli.dart';
import 'cli_args.dart';
import 'custom_providers.dart';

/// Envelope + payload version.
const int providerExportVersion = 1;

/// Default PBKDF2-HMAC-SHA256 work factor (>= 100000 per the §S6 spec).
const int providerExportIterations = 210000;

/// Default `--out` file name.
const String providerExportDefaultFile = 'providers.fahx';

/// A loud, single failure type for every export/import error: bad shape,
/// unsupported version/kdf, wrong passphrase, tampered ciphertext.
final class ProviderExportException implements Exception {
  const ProviderExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One imported provider: the registry entry plus its transferred key
/// (null when the export carried none).
final class ExportedProvider {
  const ExportedProvider({required this.entry, this.key});

  final CustomProviderEntry entry;
  final String? key;
}

// ---------------------------------------------------------------------------
// Crypto — stateful SHA-256/HMAC core (issue #1850 AC1).
// ---------------------------------------------------------------------------

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
Uint8List _macTag(_HmacSha256 mac, List<int> nonce, List<int> data) {
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
Uint8List _keystream(List<int> key, List<int> nonce, int length) {
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

Uint8List _xor(List<int> data, List<int> keystream) {
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

List<int> _deriveKeys(String passphrase, List<int> salt, int iterations) =>
    pbkdf2Sha256(utf8.encode(passphrase), salt, iterations, 64);

Uint8List _randomBytes(int count) {
  final bytes = Uint8List(count);
  final random = Random.secure();
  for (var i = 0; i < count; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Encrypts [plaintext] into the `.fahx` envelope map.
Map<String, dynamic> encryptProvidersExport(
  String plaintext,
  String passphrase, {
  int iterations = providerExportIterations,
  List<int>? salt,
  List<int>? nonce,
}) {
  final usedSalt = salt ?? _randomBytes(16);
  final usedNonce = nonce ?? _randomBytes(16);
  final plainBytes = utf8.encode(plaintext);
  final keys = _deriveKeys(passphrase, usedSalt, iterations);
  final ciphertext = _xor(
    plainBytes,
    _keystream(keys.sublist(0, 32), usedNonce, plainBytes.length),
  );
  final tag = _macTag(_HmacSha256(keys.sublist(32)), usedNonce, ciphertext);
  final blob = Uint8List(ciphertext.length + tag.length);
  blob
    ..setRange(0, ciphertext.length, ciphertext)
    ..setRange(ciphertext.length, blob.length, tag);
  return {
    'version': providerExportVersion,
    'kdf': {
      'algo': 'pbkdf2-sha256',
      'iterations': iterations,
      'salt': base64Encode(usedSalt),
    },
    'nonce': base64Encode(usedNonce),
    'ct': base64Encode(blob),
  };
}

/// Decrypts a `.fahx` envelope. Every failure is a loud
/// [ProviderExportException] — wrong passphrase and tampered ciphertext
/// are indistinguishable by design (same authentication failure).
String decryptProvidersExport(
  Map<String, dynamic> envelope,
  String passphrase,
) {
  if (envelope['version'] != providerExportVersion) {
    throw ProviderExportException(
      'unsupported .fahx version: ${envelope['version']}',
    );
  }
  final kdf = envelope['kdf'];
  if (kdf is! Map<String, dynamic> || kdf['algo'] != 'pbkdf2-sha256') {
    throw const ProviderExportException(
      'unsupported .fahx kdf (expected pbkdf2-sha256)',
    );
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
    throw const ProviderExportException('.fahx envelope is malformed');
  }
  final (salt, nonce, blob) = _decodeEnvelopeFields(saltB64, nonceB64, ctB64);
  if (blob.length <= 32) {
    throw const ProviderExportException('.fahx envelope is malformed');
  }
  final ciphertext = blob.sublist(0, blob.length - 32);
  final tag = blob.sublist(blob.length - 32);
  final keys = _deriveKeys(passphrase, salt, iterations);
  final expected = _macTag(_HmacSha256(keys.sublist(32)), nonce, ciphertext);
  if (!_constantTimeEquals(expected, tag)) {
    throw const ProviderExportException(
      'wrong passphrase or corrupted .fahx file',
    );
  }
  return utf8.decode(
    _xor(ciphertext, _keystream(keys.sublist(0, 32), nonce, ciphertext.length)),
  );
}

/// Decodes the envelope's base64 fields; every decode failure is the same
/// loud malformed-envelope exception (no oracle for encoders).
(Uint8List, Uint8List, Uint8List) _decodeEnvelopeFields(
  String saltB64,
  String nonceB64,
  String ctB64,
) {
  try {
    return (base64Decode(saltB64), base64Decode(nonceB64), base64Decode(ctB64));
  } on FormatException {
    throw const ProviderExportException('.fahx envelope is malformed');
  }
}

// ---------------------------------------------------------------------------
// Pure import.
// ---------------------------------------------------------------------------

/// Decodes + decrypts + verifies a `.fahx` file's contents into entries.
/// Pure: reads nothing, writes nothing.
List<ExportedProvider> importProvidersExport(
  String contents,
  String passphrase,
) {
  final envelope = _decodeJsonObject(contents, '.fahx file is not valid JSON');
  final payload = _decodeJsonObject(
    decryptProvidersExport(envelope, passphrase),
    '.fahx payload is not valid JSON',
  );
  if (payload['version'] != providerExportVersion ||
      payload['providers'] is! List) {
    throw const ProviderExportException('.fahx payload is malformed');
  }
  return [
    for (final raw in payload['providers'] as List) _parseProviderEntry(raw),
  ];
}

/// Decodes [text] and requires a JSON object; anything else is a loud
/// [ProviderExportException] with [message].
Map<String, dynamic> _decodeJsonObject(String text, String message) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw ProviderExportException(message);
  }
  if (decoded is! Map<String, dynamic>) {
    throw ProviderExportException(message);
  }
  return decoded;
}

/// Validates one `providers` list entry and decodes it into an
/// [ExportedProvider]; a missing name/apiType/baseUrl/modelId is malformed.
ExportedProvider _parseProviderEntry(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const ProviderExportException('.fahx payload is malformed');
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
    throw const ProviderExportException('.fahx payload is malformed');
  }
  final keyName = raw['keyName'];
  final key = raw['key'];
  return ExportedProvider(
    entry: CustomProviderEntry(
      name: name,
      apiType: apiType,
      baseUrl: baseUrl,
      modelId: modelId,
      keyName: _optionalExportedField(keyName),
      authHeader: parseAuthHeaderName(raw['authHeader'], 'exported "$name"'),
    ),
    key: _optionalExportedField(key),
  );
}

/// Coerces an optional exported field: null unless a non-empty [String].
String? _optionalExportedField(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

// ---------------------------------------------------------------------------
// CLI command.
// ---------------------------------------------------------------------------

/// Runs one `fa config <verb>` command and returns the process exit code.
///
/// All file access goes through [env]; key resolution consults
/// [environment] first, then [secureRead] (the secure-store snapshot) —
/// the same order as the interactive CLI. Key values NEVER appear in
/// output lines.
Future<int> runProviderExportCommand(
  ConfigCliCommand cmd, {
  required CliIO io,
  required ExecutionEnv env,
  required List<CustomProviderEntry> entries,
  String? Function(String keyName)? secureRead,
  Map<String, String>? environment,
  Future<String> Function()? readPassphrase,
  int iterations = providerExportIterations,
}) async {
  // The parser admits only export-providers today; kept switch-shaped so
  // the next verb extends, not forks.
  switch (cmd.verb) {
    case 'export-providers':
      return _exportProviders(
        cmd,
        io: io,
        env: env,
        entries: entries,
        secureRead: secureRead,
        environment: environment,
        readPassphrase: readPassphrase,
        iterations: iterations,
      );
    default:
      io.writeln('unknown config verb: ${cmd.verb}');
      return 1;
  }
}

Future<int> _exportProviders(
  ConfigCliCommand cmd, {
  required CliIO io,
  required ExecutionEnv env,
  required List<CustomProviderEntry> entries,
  String? Function(String keyName)? secureRead,
  Map<String, String>? environment,
  Future<String> Function()? readPassphrase,
  required int iterations,
}) async {
  final passphrase = await _readPassphrase(
    cmd,
    io: io,
    readPassphrase: readPassphrase,
  );
  if (passphrase == null) return 1;
  final providers = <Map<String, dynamic>>[];
  final envMap = environment ?? Platform.environment;
  for (final entry in entries) {
    final keyName = _keyNameFor(entry);
    final fromEnv = envMap[keyName];
    final stored = secureRead?.call(keyName);
    final key = fromEnv != null && fromEnv.isNotEmpty
        ? fromEnv
        : (stored != null && stored.isNotEmpty ? stored : null);
    if (key == null) {
      io.writeln(
        'warning: no key for "${entry.name}" ($keyName) — '
        'entry exported without it',
      );
    }
    providers.add({
      'name': entry.name,
      'apiType': entry.apiType,
      'baseUrl': entry.baseUrl,
      'modelId': entry.modelId,
      'authMethod': entry.authMethod.name,
      'keyName': ?entry.keyName,
      'authHeader': ?entry.authHeader,
      'key': ?key,
    });
  }
  final envelope = encryptProvidersExport(
    jsonEncode({
      'version': providerExportVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'providers': providers,
    }),
    passphrase,
    iterations: iterations,
  );
  final target = cmd.out ?? providerExportDefaultFile;
  final result = await env.writeFile(target, '${jsonEncode(envelope)}\n');
  switch (result) {
    case Err(:final error):
      io.writeln('fa: cannot write $target: $error');
      return 1;
    case Ok():
      break;
  }
  final withKeys = providers.where((p) => p['key'] != null).length;
  io.writeln(
    'wrote $target: ${providers.length} providers, '
    '$withKeys keys (passphrase-encrypted .fahx)',
  );
  return 0;
}

/// Reads the passphrase: one stdin line in `--passphrase-stdin` mode,
/// else the double prompt (empty or mismatched → null, exit).
Future<String?> _readPassphrase(
  ConfigCliCommand cmd, {
  required CliIO io,
  Future<String> Function()? readPassphrase,
}) async {
  if (cmd.passphraseStdin) {
    return _readPassphraseStdin(io, readPassphrase: readPassphrase);
  }
  return _readPassphrasePrompt(io, readPassphrase: readPassphrase);
}

/// The `--passphrase-stdin` mode: one line from the injected reader.
Future<String?> _readPassphraseStdin(
  CliIO io, {
  required Future<String> Function()? readPassphrase,
}) async {
  if (readPassphrase == null) {
    io.writeln('fa: --passphrase-stdin needs a stdin reader');
    return null;
  }
  final value = await readPassphrase();
  if (value.isEmpty) {
    io.writeln('fa: passphrase must not be empty');
    return null;
  }
  return value;
}

/// The interactive double prompt: empty or mismatched pair → null.
Future<String?> _readPassphrasePrompt(
  CliIO io, {
  required Future<String> Function()? readPassphrase,
}) async {
  Future<String> readLine() =>
      readPassphrase != null ? readPassphrase() : io.lines.first;
  io.writeln('enter passphrase:');
  final first = await readLine();
  io.writeln('confirm passphrase:');
  final second = await readLine();
  if (first.isEmpty) {
    io.writeln('fa: passphrase must not be empty');
    return null;
  }
  if (first != second) {
    io.writeln('fa: passphrases do not match');
    return null;
  }
  return first;
}

String _keyNameFor(CustomProviderEntry entry) =>
    entry.keyName ??
    CustomProviderRegistry.keyNameFor(entry.baseUrl, providerName: entry.name);
