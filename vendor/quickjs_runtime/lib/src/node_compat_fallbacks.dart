part of 'node_compat.dart';

// ── Default (non-secure / approximating) fallbacks ──

/// Base64 arithmetic 4-bit mask (also reused by the UUID nibble layout).
const int _b64QuadMask = 0x0F;

/// RFC 4122 UUIDv4 bit layout: version nibble + variant bits.
const int _uuidNibbleMask = _b64QuadMask;
const int _uuidVersion4 = 0x40;
const int _uuidVariantMask = 0x3F;
const int _uuidVariantBits = 0x80;

/// LCG state seed and modulus for the non-secure fallback PRNG.
const int _pseudoSeed = 0x2545F491;
const int _pseudoMask = 0x7FFFFFFF;

int _pseudoState = _pseudoSeed;

List<int> _pseudoRandom(int count) => List<int>.generate(
      count,
      (_) =>
          (_pseudoState = (_pseudoState * 1103515245 + 12345) & _pseudoMask) &
          0xFF,
      growable: false,
    );

String _pseudoUuid() {
  final bytes = _pseudoRandom(16);
  bytes[6] = (bytes[6] & _uuidNibbleMask) | _uuidVersion4;
  bytes[8] = (bytes[8] & _uuidVariantMask) | _uuidVariantBits;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final s = bytes.map(hex).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
      '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

// True UTF-8 (dart:convert) — the latin-1 approximation is gone: default
// codecs must match Node byte-for-byte, hooks are for override only.
List<int> _utf8Bytes(String text) => utf8.encode(text);

String _utf8String(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

// Minimal base64 (RFC 4648) for the no-hook default path.
const String _b64alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

String _b64Encode(String text) {
  final bytes = _utf8Bytes(text);
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : null;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : null;
    out.write(_b64alphabet[b0 >> 2]);
    out.write(_b64alphabet[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)]);
    out.write(
      b1 == null
          ? '='
          : _b64alphabet[((b1 & _b64QuadMask) << 2) | ((b2 ?? 0) >> 6)],
    );
    out.write(b2 == null ? '=' : _b64alphabet[b2 & 0x3F]);
  }
  return out.toString();
}

String _b64Decode(String text) {
  final clean = text.replaceAll('=', '').replaceAll(RegExp(r'\s'), '');
  final out = <int>[];
  for (var i = 0; i < clean.length; i += 4) {
    final n = [0, 1, 2, 3]
        .map((k) =>
            i + k < clean.length ? _b64alphabet.indexOf(clean[i + k]) : 0)
        .toList();
    out.add((n[0] << 2) | (n[1] >> 4));
    if (i + 2 < clean.length)
      out.add(((n[1] & _b64QuadMask) << 4) | (n[2] >> 2));
    if (i + 3 < clean.length) out.add(((n[2] & 0x03) << 6) | n[3]);
  }
  return _utf8String(out);
}
