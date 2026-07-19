/// Pure-Dart xxHash32, ported from the xxHash specification (xxHash32, seed
/// parameter) so hashline file tags match oh-my-pi's `Bun.hash.xxHash32(text,
/// 0) & 0xffff` exactly for the same UTF-8 input bytes.
///
/// `lib/` must compile for web, where Dart `int` arithmetic is backed by
/// float64: products and shifts therefore never exceed 2^53 unmasked.
/// Multiplication goes through a 16-bit split ([_mul32]) and left shifts are
/// expressed as masked multiplies, so every intermediate stays exact in both
/// the VM (64-bit int) and dart2js (float64) number models.
library;

import 'dart:typed_data';

const int _prime1 = 0x9E3779B1;
const int _prime2 = 0x85EBCA77;
const int _prime3 = 0xC2B2AE3D;
const int _prime4 = 0x27D4EB2F;
const int _prime5 = 0x165667B1;

final Uint32List _truncateBox = Uint32List(1);

/// Truncates [value] to an unsigned 32-bit integer via typed-data semantics,
/// which behave identically on the VM and on the web.
int _u32(int value) {
  _truncateBox[0] = value;
  return _truncateBox[0];
}

/// Low 32 bits of `a * b`. All partial products stay below 2^34, exact in a
/// float64, so the result is correct on every platform.
int _mul32(int a, int b) {
  final aLo = a & 0xFFFF;
  final aHi = a >>> 16;
  final bLo = b & 0xFFFF;
  final bHi = b >>> 16;
  final low = aLo * bLo;
  final mid = aHi * bLo + aLo * bHi;
  return _u32(low + ((mid & 0xFFFF) << 16));
}

/// 32-bit rotate-left of [x] by [r] (1 <= r <= 31). The high part is computed
/// as a multiply by 2^r on the low (32-r) bits of [x], so no intermediate
/// exceeds 2^32; the two parts occupy disjoint bits and add without carry.
int _rotl32(int x, int r) {
  final low = (x & (0xFFFFFFFF >>> r)) * (1 << r);
  final high = x >>> (32 - r);
  return low + high;
}

/// Little-endian 32-bit lane read at [index], built with multiplies so the
/// result is exact on the web (no 32-bit-overflowing shifts).
int _lane32(Uint8List data, int index) {
  return data[index] +
      data[index + 1] * 0x100 +
      data[index + 2] * 0x10000 +
      data[index + 3] * 0x1000000;
}

int _round(int accumulator, int lane) {
  return _mul32(
    _rotl32(_u32(accumulator + _mul32(lane, _prime2)), 13),
    _prime1,
  );
}

/// Computes xxHash32 of [data] with [seed] (both treated as unsigned 32-bit).
///
/// Reference vectors (seed 0): `''` → 0x02CC5D05, `'abc'` → 0x32D153FF,
/// `'test'` → 1042293711.
int xxHash32(Uint8List data, [int seed = 0]) {
  final length = data.length;
  var index = 0;
  int hash;

  if (length >= 16) {
    var v1 = _u32(seed + _prime1 + _prime2);
    var v2 = _u32(seed + _prime2);
    var v3 = _u32(seed);
    var v4 = _u32(seed - _prime1);
    final limit = length - 16;
    while (index <= limit) {
      v1 = _round(v1, _lane32(data, index));
      v2 = _round(v2, _lane32(data, index + 4));
      v3 = _round(v3, _lane32(data, index + 8));
      v4 = _round(v4, _lane32(data, index + 12));
      index += 16;
    }
    hash = _u32(
      _rotl32(v1, 1) + _rotl32(v2, 7) + _rotl32(v3, 12) + _rotl32(v4, 18),
    );
  } else {
    hash = _u32(seed + _prime5);
  }

  hash = _u32(hash + length);

  while (index + 4 <= length) {
    hash = _mul32(
      _rotl32(_u32(hash + _mul32(_lane32(data, index), _prime3)), 17),
      _prime4,
    );
    index += 4;
  }
  while (index < length) {
    hash = _mul32(
      _rotl32(_u32(hash + _mul32(data[index], _prime5)), 11),
      _prime1,
    );
    index++;
  }

  hash = _u32(hash ^ (hash >>> 15));
  hash = _mul32(hash, _prime2);
  hash = _u32(hash ^ (hash >>> 13));
  hash = _mul32(hash, _prime3);
  hash = _u32(hash ^ (hash >>> 16));
  return hash;
}
