// Deterministic, seeded, chunked world generation (terrain, biomes-lite,
// caves). Same seed + same coords → identical bytes on every engine.
var Facraft = Facraft || {};
Facraft.worldgen = (function() {
  var N = function() { return Facraft.noise; };
  var B = function() { return Facraft.blocks; };

  var CHUNK_X = 16, CHUNK_Y = 64, CHUNK_Z = 16;

  function index(lx, y, lz) { return (y * CHUNK_Z + lz) * CHUNK_X + lx; }

  // Surface height for a world column.
  function height(seed, wx, wz, ns) {
    ns = ns || N();
    var base = ns.fbm2(seed, wx * 0.012, wz * 0.012, 4); // [-1,1]
    var detail = ns.fbm2(seed + 555, wx * 0.06, wz * 0.06, 2);
    var h = 24 + base * 16 + detail * 3;
    h = Math.max(4, Math.min(CHUNK_Y - 6, Math.round(h)));
    // Spawn ring: blend the terrain toward a gentle dome at h≈27 —
    // clamping (the old max(24,min(34,h))) DEFORMED the landscape: the
    // floor flattened whole neighborhoods into a pancake and the cap
    // left the spawn column a lone tower (seed 111: eye 12 blocks above
    // the surroundings — the player 'hangs in a void'). Smoothstep
    // keeps natural hills at the ring edge and a solid spawn view.
    var d = Math.max(Math.abs(wx), Math.abs(wz));
    if (d <= 40) {
      var t = d / 40;
      t = t * t * (3 - 2 * t);
      // Keep 55% of the natural relief inside the dome: a fully flat
      // dome compresses the near ground into a thin pale band that
      // reads as void — rolling terrain is what makes the ground READ
      // as ground.
      var relief = h - 27;
      if (relief > 0) relief *= 0.75; else relief *= 0.85;
      h = 27 + relief * (1 - t) + (h - 27) * t;
      h = Math.max(20, Math.min(34, Math.round(h)));
    }
    return h;
  }

  function surfaceBlock(seed, wx, wz, h, bs, ns) {
    if (h > 34) return bs.STONE; // mountains
    // Spawn ring always rolls temperate: the first thing a new player
    // sees must be grass, never a desert/mountain roll of the biome
    // noise (report: repeated "no grass" spawns right after the app
    // update — the biome pick is pure seed luck at the ring).
    var d = Math.max(Math.abs(wx), Math.abs(wz));
    if (d <= 40) return bs.GRASS;
    var sand = ns.value2(seed + 91, wx * 0.05, wz * 0.05);
    if (h < 18 || sand > 0.55) return bs.SAND; // lowlands / sandy patches
    return bs.GRASS;
  }

  // Three-octave 3D fBm (sum = o0 + 0.5*o1 + 0.25*o2, norm = 1.75; threshold
  // 0.45 * 1.75 = 0.7875). Exact early-out bounds:
  //   - after octave 0: max remaining is +0.75 → if v0 <= 0.0375, cannot > 0.7875
  //   - after octave 1: max remaining is +0.25 → if s1 <= 0.5375, cannot > 0.7875
  // Bit-identical to N().fbm3(seed + 777, ..., 3) > 0.45 while skipping
  // ~65% of octave-1 and ~90% of octave-2 3D trilinear hashes on iOS JSC.
  function isCave(seed, wx, wy, wz, ns) {
    if (wy < 2) return false;
    var s0 = (seed + 777) | 0;
    var x = wx * 0.09, y = wy * 0.11, z = wz * 0.09;
    var v0 = ns.value3(s0, x, y, z);
    if (v0 <= 0.0375) return false;
    var s1 = v0 + ns.value3(s0 + 1013, x * 2, y * 2, z * 2) * 0.5;
    if (s1 <= 0.5375) return false;
    var s2 = s1 + ns.value3(s0 + 2026, x * 4, y * 4, z * 4) * 0.25;
    return s2 / 1.75 > 0.45;
  }

  // The block one world column holds at height y (0 < y <= h). This is the
  // exact fill rule chunk() applies per cell, factored out so groundY can
  // scan a single column without generating the whole chunk (boot path:
  // spawn height used to cost two throwaway 16x64x16 chunk generations).
  function columnBlock(seed, wx, wz, y, h, surf, bs, ns, crust) {
    if (y === 0) return bs.BEDROCK;
    var b;
    if (y === h) b = surf;
    else if (y >= h - 3 && surf !== bs.STONE) b = (surf === bs.SAND) ? bs.SAND : bs.DIRT;
    else b = bs.STONE;
    // The spawn ring keeps a solid crust: cave mouths eating the
    // surface next to the spawn read as holes into the void (the
    // world "hangs in emptiness" and mobs by the hole look like they
    // float). Check the crust BEFORE sampling 3D cave noise.
    if (crust && y > h - 6) return b;
    if (isCave(seed, wx, y, wz, ns)) return bs.AIR;
    return b;
  }

  // Generate one chunk column into a fresh Uint8Array.
  function chunk(seed, cx, cz) {
    var a = new Uint8Array(CHUNK_X * CHUNK_Y * CHUNK_Z);
    var bs = B(), ns = N(); // resolve modules once, not once per block
    for (var lx = 0; lx < CHUNK_X; lx++) {
      for (var lz = 0; lz < CHUNK_Z; lz++) {
        var wx = cx * CHUNK_X + lx, wz = cz * CHUNK_Z + lz;
        var h = height(seed, wx, wz, ns);
        var surf = surfaceBlock(seed, wx, wz, h, bs, ns);
        var crust = Math.max(Math.abs(wx), Math.abs(wz)) <= 40;
        var ci = lz * CHUNK_X + lx;
        for (var y = 0; y <= h; y++) {
          a[ci] = columnBlock(seed, wx, wz, y, h, surf, bs, ns, crust);
          ci += CHUNK_X * CHUNK_Z;
        }
      }
    }
    return a;
  }

  // Highest solid block y of a column (worldgen view — does not see player
  // edits). Analytical: scans the single column's fill rule from the
  // surface down — byte-identical to scanning a generated chunk, without
  // generating one.
  function groundY(seed, wx, wz) {
    var bs = B(), ns = N();
    var h = height(seed, wx, wz, ns);
    var surf = surfaceBlock(seed, wx, wz, h, bs, ns);
    var crust = Math.max(Math.abs(wx), Math.abs(wz)) <= 40;
    for (var y = h; y >= 1; y--) {
      if (columnBlock(seed, wx, wz, y, h, surf, bs, ns, crust) !== 0) return y;
    }
    return 0; // fully carved column: the bedrock floor is the ground
  }

  return {
    CHUNK_X: CHUNK_X, CHUNK_Y: CHUNK_Y, CHUNK_Z: CHUNK_Z,
    index: index, chunk: chunk, height: height, groundY: groundY,
  };
})();
