// Hash-based value noise (2D/3D) with fBm. Pure integer hashing → identical
// output on every engine; no Math.random anywhere.
var Facraft = Facraft || {};
Facraft.noise = (function() {
  function hash2(seed, x, y) {
    var h = Math.imul(x, 374761393) ^ Math.imul(y, 668265263) ^ Math.imul(seed | 0, 2246822519);
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
  }

  // Hot worldgen path: the old nested hash/lerp helper calls repeated the
  // same integer products eight times per 3D sample (four times in 2D).
  // Sharing those products and inlining the interpolation is bit-identical
  // but matters on QuickJS, which cannot JIT away the call overhead.
  function value2(seed, x, y) {
    var ix = Math.floor(x), iy = Math.floor(y);
    var fx = x - ix, fy = y - iy;
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    var sh = Math.imul(seed | 0, 2246822519);
    var x0 = Math.imul(ix, 374761393), x1 = Math.imul(ix + 1, 374761393);
    var y0 = Math.imul(iy, 668265263), y1 = Math.imul(iy + 1, 668265263);
    var h = x0 ^ y0 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v00 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x1 ^ y0 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v10 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x0 ^ y1 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v01 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x1 ^ y1 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v11 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    var c0 = v00 + (v10 - v00) * fx;
    var c1 = v01 + (v11 - v01) * fx;
    return (c0 + (c1 - c0) * fy) * 2 - 1;
  }

  function value3(seed, x, y, z) {
    var ix = Math.floor(x), iy = Math.floor(y), iz = Math.floor(z);
    var fx = x - ix, fy = y - iy, fz = z - iz;
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy); fz = fz * fz * (3 - 2 * fz);
    var sh = Math.imul(seed | 0, 2246822519);
    var x0 = Math.imul(ix, 374761393), x1 = Math.imul(ix + 1, 374761393);
    var y0 = Math.imul(iy, 668265263), y1 = Math.imul(iy + 1, 668265263);
    var z0 = Math.imul(iz, 2147483647), z1 = Math.imul(iz + 1, 2147483647);

    var h = x0 ^ y0 ^ z0 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v000 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x1 ^ y0 ^ z0 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v100 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x0 ^ y1 ^ z0 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v010 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x1 ^ y1 ^ z0 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v110 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x0 ^ y0 ^ z1 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v001 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x1 ^ y0 ^ z1 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v101 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x0 ^ y1 ^ z1 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v011 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    h = x1 ^ y1 ^ z1 ^ sh;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    var v111 = ((h ^ (h >>> 16)) >>> 0) / 4294967296;

    var c00 = v000 + (v100 - v000) * fx;
    var c10 = v010 + (v110 - v010) * fx;
    var c01 = v001 + (v101 - v001) * fx;
    var c11 = v011 + (v111 - v011) * fx;
    var c0 = c00 + (c10 - c00) * fy;
    var c1 = c01 + (c11 - c01) * fy;
    return (c0 + (c1 - c0) * fz) * 2 - 1;
  }

  function fbm2(seed, x, y, octaves) {
    var sum = 0, amp = 1, freq = 1, norm = 0;
    for (var o = 0; o < octaves; o++) {
      sum += value2(seed + o * 1013, x * freq, y * freq) * amp;
      norm += amp;
      amp *= 0.5;
      freq *= 2;
    }
    return sum / norm;
  }

  function fbm3(seed, x, y, z, octaves) {
    var sum = 0, amp = 1, freq = 1, norm = 0;
    for (var o = 0; o < octaves; o++) {
      sum += value3(seed + o * 1013, x * freq, y * freq, z * freq) * amp;
      norm += amp;
      amp *= 0.5;
      freq *= 2;
    }
    return sum / norm;
  }

  return { value2: value2, value3: value3, fbm2: fbm2, fbm3: fbm3, hash2: hash2 };
})();
