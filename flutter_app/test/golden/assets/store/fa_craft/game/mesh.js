// Per-chunk face-culling mesher. Emits plain arrays (JSON-friendly bridge
// payloads): chunk-local positions, per-vertex colors, quad indices.
// Only dirty chunks rebuild (buffer reuse, IT gate).
var Facraft = Facraft || {};
Facraft.mesh = (function() {
  var W = function() { return Facraft.world; };
  var WG = function() { return Facraft.worldgen; };
  var B = function() { return Facraft.blocks; };

  // face table: dir → 4 corner offsets (CCW from outside)
  var FACES = [
    { n: [1, 0, 0], c: [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]] },
    { n: [-1, 0, 0], c: [[0, 0, 1], [0, 1, 1], [0, 1, 0], [0, 0, 0]] },
    { n: [0, 1, 0], c: [[0, 1, 0], [0, 1, 1], [1, 1, 1], [1, 1, 0]] },
    { n: [0, -1, 0], c: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]] },
    { n: [0, 0, 1], c: [[1, 0, 1], [1, 1, 1], [0, 1, 1], [0, 0, 1]] },
    { n: [0, 0, -1], c: [[0, 0, 0], [0, 1, 0], [1, 1, 0], [1, 0, 0]] },
  ];

  // In-plane axes (U, V) per face — the two axes not pierced by the normal.
  var AXES = [[1, 2], [1, 2], [0, 2], [0, 2], [0, 1], [0, 1]];
  // Merged-quad corner patterns per face, in (A-slice, U, V) terms; each
  // row reduces to FACES[f].c for a 1x1 quad, preserving CCW-from-outside
  // winding (the painter's backface cull depends on it).
  // corner order: (u0v0-like …) encoded as [su, sv] sign pairs below.
  var CORNERS = [
    [[0, 0], [1, 0], [1, 1], [0, 1]], // +x
    [[0, 1], [1, 1], [1, 0], [0, 0]], // -x
    [[0, 0], [0, 1], [1, 1], [1, 0]], // +y
    [[0, 0], [1, 0], [1, 1], [0, 1]], // -y
    [[1, 0], [1, 1], [0, 1], [0, 0]], // +z
    [[0, 0], [0, 1], [1, 1], [1, 0]], // -z
  ];
  var MASK = new Int32Array(16 * 64); // reused per slice — no per-slice allocs

  function block(w, lx, y, lz, cx, cz) {
    if (y < 0 || y >= WG().CHUNK_Y) return B().AIR;
    var dx = 0, dz = 0, x = lx, z = lz;
    if (lx < 0) { dx = -1; x = lx + 16; } else if (lx > 15) { dx = 1; x = lx - 16; }
    if (lz < 0) { dz = -1; z = lz + 16; } else if (lz > 15) { dz = 1; z = lz - 16; }
    var k = W().key(cx + dx, cz + dz);
    var c = w.chunks[k];
    if (!c) { c = WG().chunk(w.seed, cx + dx, cz + dz); w.chunks[k] = c; }
    return c[WG().index(x, y, z)];
  }

  // Greedy mesher: per face direction, sweep 16 slices perpendicular to the
  // normal and merge maximal rectangles of same-color visible faces. Flat
  // terrain (the common case) collapses 16x16 single-block quads into a
  // handful of large ones — 3-10x fewer triangles for the painter and the
  // bridge. shadeFaces() works per-quad, so merged quads shade uniformly
  // (the per-block hue jitter becomes per-rectangle).
  function buildMask(w, cx, cz, f, s, SIZES, p, q, seedCol) {
    var A = f >> 1, positive = (f & 1) === 0;
    var U = AXES[f][0], V = AXES[f][1];
    var SU = SIZES[U], SV = SIZES[V];
    var dn = positive ? 1 : -1;
    for (var v = 0; v < SV; v++) {
      for (var u = 0; u < SU; u++) {
        p[A] = s; p[U] = u; p[V] = v;
        var b = block(w, p[0], p[1], p[2], cx, cz);
        if (!B().isSolid(b)) continue;
        q[A] = s + dn; q[U] = u; q[V] = v;
        if (B().isSolid(block(w, q[0], q[1], q[2], cx, cz))) continue;
        // Pixel-grain texturing: one of 4 per-type tones from a
        // world-position hash (grass sides use the dirt palette).
        // The MERGE key below IS the tone, so only same-tone
        // neighbours merge — crisp per-block grain at ~2.5-4x the
        // fully-merged triangle count, zero view-dependence.
        var pal = B().palette(b, A !== 1);
        var h = ((cx * 16 + p[0]) * 73856093) ^ (p[1] * 19349663) ^
                ((cz * 16 + p[2]) * 83492791);
        h = (h ^ (h >>> 13)) >>> 0;
        var col = pal[h & 3];
        seedCol[v * SU + u] = col;
        MASK[v * SU + u] =
          ((Math.round(col[0] * 255) << 16) |
            (Math.round(col[1] * 255) << 8) |
            Math.round(col[2] * 255)) + 1;
      }
    }
  }

  function mergeSlice(positions, colors, indices, f, s, SIZES, seedCol) {
    var A = f >> 1, positive = (f & 1) === 0;
    var U = AXES[f][0], V = AXES[f][1];
    var SU = SIZES[U], SV = SIZES[V];
    for (var vv = 0; vv < SV; vv++) {
      for (var uu = 0; uu < SU; uu++) {
        var key = MASK[vv * SU + uu];
        if (!key) continue;
        var wdt = 1;
        while (uu + wdt < SU && MASK[vv * SU + uu + wdt] === key) wdt++;
        var hgt = 1;
        outer: while (vv + hgt < SV) {
          for (var du = 0; du < wdt; du++) {
            if (MASK[(vv + hgt) * SU + uu + du] !== key) break outer;
          }
          hgt++;
        }
        emitQuad(positions, colors, indices, f, s, positive, A, U, V,
          uu, uu + wdt, vv, vv + hgt, seedCol[vv * SU + uu]);
        for (var dv = 0; dv < hgt; dv++) {
          for (var du2 = 0; du2 < wdt; du2++) {
            MASK[(vv + dv) * SU + uu + du2] = 0;
          }
        }
      }
    }
  }

  function buildChunk(w, cx, cz) {
    var positions = [], colors = [], indices = [];
    var SIZES = [16, WG().CHUNK_Y, 16];
    var p = [0, 0, 0], q = [0, 0, 0];
    for (var f = 0; f < 6; f++) {
      var A = f >> 1;
      var U = AXES[f][0], V = AXES[f][1];
      var SU = SIZES[U], SV = SIZES[V];
      for (var s = 0; s < SIZES[A]; s++) {
        MASK.fill(0);
        var seedCol = new Array(SU * SV);
        buildMask(w, cx, cz, f, s, SIZES, p, q, seedCol);
        mergeSlice(positions, colors, indices, f, s, SIZES, seedCol);
      }
    }
    return { positions: positions, colors: colors, indices: indices, origin: [cx * 16, 0, cz * 16] };
  }

  function emitQuad(positions, colors, indices, f, s, positive, A, U, V,
      u0, u1, v0, v1, col) {
    var base = positions.length / 3;
    var a = positive ? s + 1 : s;
    var cs = CORNERS[f];
    for (var i = 0; i < 4; i++) {
      var cr = [0, 0, 0];
      cr[A] = a;
      cr[U] = cs[i][0] ? u1 : u0;
      cr[V] = cs[i][1] ? v1 : v0;
      positions.push(cr[0], cr[1], cr[2]);
      colors.push(col[0], col[1], col[2]);
    }
    indices.push(base, base + 1, base + 2, base, base + 2, base + 3);
  }

  // Rebuild only dirty chunks; untouched meshes keep their buffer objects.
  function rebuildDirty(w) {
    var built = [];
    w.dirty.forEach(function(k) {
      var parts = k.split(',');
      w.meshes.set(k, buildChunk(w, parseInt(parts[0], 10), parseInt(parts[1], 10)));
      built.push(k);
    });
    w.dirty.clear();
    return built;
  }

  return { buildChunk: buildChunk, rebuildDirty: rebuildDirty };
})();
