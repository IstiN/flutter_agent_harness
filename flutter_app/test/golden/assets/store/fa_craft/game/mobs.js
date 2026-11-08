// Passive mobs (pigs, chickens): a random-walk think loop drives plain
// physics bodies (gravity + collision reuse the player stepper), and each
// mob renders as a small box-built mesh uploaded to a resident
// '__mob<i>' chunk — the same resident-chunk pattern as the aim marker.
var Facraft = Facraft || {};
Facraft.mobs = (function() {
  var W = function() { return Facraft.world; };
  var P = function() { return Facraft.physics; };

  // Tiny deterministic int hash (rng.js exports only the mulberry factory).
  function hash3(a, b, c) {
    var h = (Math.imul(a, 374761393) + Math.imul(b, 668265263) +
      Math.imul(c, 974711)) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    return (h ^ (h >>> 16)) >>> 0;
  }

  var MAX_MOBS = 6;
  var WALK = 1.1;           // blocks/s — a gentle amble
  var DESPAWN_R2 = 80 * 80; // walk away and they fade out
  var SPAWN_MIN_R2 = 8 * 8; // …but never right on top of the player

  var DIMS = {
  pig: { half: 0.5, height: 1.25 },
  chicken: { half: 0.32, height: 1.05 },
  };

  var PALETTES = {
    pig: { body: [0.94, 0.62, 0.66], head: [0.96, 0.70, 0.73], leg: [0.82, 0.48, 0.53] },
    chicken: { body: [0.93, 0.93, 0.90], head: [0.97, 0.97, 0.95], leg: [0.95, 0.72, 0.20] },
  };

  // Box part lists in LOCAL space (feet at y=0, facing +z).
  // [x0, y0, z0, x1, y1, z1, paletteRole]
  var PARTS = {
    pig: [
      [-0.45, 0.40, -0.60, 0.45, 1.05, 0.55, 'body'],
      [-0.32, 0.62, 0.55, 0.32, 1.22, 1.05, 'head'],
      [-0.38, 0, -0.50, -0.16, 0.42, -0.28, 'leg'],
      [0.16, 0, -0.50, 0.38, 0.42, -0.28, 'leg'],
      [-0.38, 0, 0.24, -0.16, 0.42, 0.46, 'leg'],
      [0.16, 0, 0.24, 0.38, 0.42, 0.46, 'leg'],
    ],
    chicken: [
      [-0.28, 0.25, -0.32, 0.28, 0.68, 0.28, 'body'],
      [-0.18, 0.68, 0.10, 0.18, 1.02, 0.42, 'head'],
      [-0.08, 0.74, 0.42, 0.08, 0.88, 0.56, 'leg'], // beak (orange)
      [-0.16, 0, 0.02, -0.06, 0.26, 0.12, 'leg'],
      [0.06, 0, 0.02, 0.16, 0.26, 0.12, 'leg'],
    ],
  };

  // 6 faces of a box, CCW from outside — the winding contract of mesh.js
  // (the painter backface-culls on it).
  function emitBox(P2, C2, I2, b, col, cosA, sinA, mx, my, mz) {
    var x0 = b[0], y0 = b[1], z0 = b[2], x1 = b[3], y1 = b[4], z1 = b[5];
    var F = [
      [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]],
      [[x0, y0, z1], [x0, y1, z1], [x0, y1, z0], [x0, y0, z0]],
      [[x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0]],
      [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]],
      [[x1, y0, z1], [x1, y1, z1], [x0, y1, z1], [x0, y0, z1]],
      [[x0, y0, z0], [x0, y1, z0], [x1, y1, z0], [x1, y0, z0]],
    ];
    for (var f = 0; f < 6; f++) {
      var base = P2.length / 3;
      for (var v = 0; v < 4; v++) {
        var lx = F[f][v][0], ly = F[f][v][1], lz = F[f][v][2];
        // yaw-rotate in the horizontal plane, then translate to the mob
        P2.push(mx + lx * cosA + lz * sinA, my + ly, mz - lx * sinA + lz * cosA);
        C2.push(col[0], col[1], col[2]);
      }
      I2.push(base, base + 1, base + 2, base, base + 2, base + 3);
    }
  }

  function mobMesh(mob) {
    var P2 = [], C2 = [], I2 = [];
    var pal = PALETTES[mob.type];
    var parts = PARTS[mob.type];
    // local +z must face the walk direction: forward = (-sin yaw, -cos yaw)
    var cosA = -Math.cos(mob.yaw), sinA = -Math.sin(mob.yaw);
    for (var i = 0; i < parts.length; i++) {
      emitBox(P2, C2, I2, parts[i], pal[parts[i][6]], cosA, sinA,
        mob.x, mob.y, mob.z);
    }
    return { positions: P2, colors: C2, indices: I2 };
  }

  function ensureSpawn(w, dt) {
    if (!w.mobs) w.mobs = [];
    // Spawn trickle: without a cooldown a butchered mob respawns the very
    // next tick — from the player's view the chicken "teleports away".
    w.mobSpawnCooldown = Math.max(0, (w.mobSpawnCooldown || 0) - dt);
    if (w.mobSpawnCooldown > 0) return;
    if (w.mobs.length >= MAX_MOBS) return;
    var px = w.player.x, pz = w.player.z;
    // Hash on the ever-increasing mob id, not the current count — a
    // replacement spawns somewhere NEW, not where the last one died.
    var n = w.nextMobId || 0;
    var ang = hash3(w.seed, n, 7) % 628 / 100;
    var dist = 10 + (hash3(w.seed, n, 13) % 14);
    var x = Math.floor(px + Math.cos(ang) * dist) + 0.5;
    var z = Math.floor(pz + Math.sin(ang) * dist) + 0.5;
    var d2 = (x - px) * (x - px) + (z - pz) * (z - pz);
    if (d2 < SPAWN_MIN_R2) return;
    // surface scan: first solid from above, spawn on top of it
    for (var y = 63; y > 0; y--) {
      if (Facraft.blocks.isSolid(W().get(w, Math.floor(x), y, Math.floor(z)))) {
        w.nextMobId = (w.nextMobId || 0) + 1;
        var type = (n % 2 === 0) ? 'pig' : 'chicken';
        w.mobs.push({
          id: w.nextMobId, // chunk keys survive splice renumbering
          type: type,
          // collision box matches the visible body — no walking into walls
          halfW: DIMS[type].half, height: DIMS[type].height,
          x: x, y: y + 1, z: z, yaw: ang, vy: 0, vx: 0, vz: 0,
          onGround: false, moving: false, think: 1 + n * 0.7,
          uploadKey: '',
        });
        w.mobSpawnCooldown = 4; // seconds before the next wanderer appears
        return;
      }
    }
  }

  function tick(w, dt) {
    if (!w.mobs) w.mobs = [];
    if (w.mobsPaused) return; // test seam: deterministic bridge budgets
    ensureSpawn(w, dt);
    var px = w.player.x, pz = w.player.z;
    for (var i = w.mobs.length - 1; i >= 0; i--) {
      var m = w.mobs[i];
      var d2 = (m.x - px) * (m.x - px) + (m.z - pz) * (m.z - pz);
      if (d2 > DESPAWN_R2) {
        Facraft.voxel.removeMesh('__mob' + m.id);
        w.mobs.splice(i, 1);
        continue;
      }
      m.think -= dt;
      if (m.think <= 0) {
        var h = hash3(w.seed, i, Math.floor(w.dayTime * 60));
        m.think = 2 + (h % 40) / 10;
        m.yaw = (h % 628) / 100;
        m.moving = (h % 10) < 7;
      }
      // Analog forward deflection scales the walk speed below the
      // player's 4.3 blocks/s — a gentle amble.
      var input = m.moving ? { moveF: WALK / 4.3 } : {};
      P().step(m, input, w, dt, 'survival');
      upload(m, i);
    }
  }

  // Ray vs mob AABBs (slab test) — returns {index, dist} of the nearest
  // mob hit within maxDist, or null. Lets the attack button butcher
  // livestock instead of whiffing at the block behind it.
  function raycast(w, ex, ey, ez, dx, dy, dz, maxDist) {
    var best = null;
    var mobs = w.mobs || [];
    for (var i = 0; i < mobs.length; i++) {
      var m = mobs[i];
      var d = DIMS[m.type];
      var lo = [m.x - d.half, m.y, m.z - d.half];
      var hi = [m.x + d.half, m.y + d.height, m.z + d.half];
      var o = [ex, ey, ez], dir = [dx, dy, dz];
      var t0 = 0, t1 = maxDist, ok = true;
      for (var a = 0; a < 3 && ok; a++) {
        if (Math.abs(dir[a]) < 1e-9) {
          if (o[a] < lo[a] || o[a] > hi[a]) ok = false;
        } else {
          var ta = (lo[a] - o[a]) / dir[a];
          var tb = (hi[a] - o[a]) / dir[a];
          if (ta > tb) { var tmp = ta; ta = tb; tb = tmp; }
          if (ta > t0) t0 = ta;
          if (tb < t1) t1 = tb;
          if (t0 > t1) ok = false;
        }
      }
      if (ok && t0 < maxDist && (!best || t0 < best.dist)) {
        best = { index: i, dist: t0 };
      }
    }
    return best;
  }

  // Butcher a mob: evict its chunk, drop it from the world. Meat is
  // abstract — the caller decides the reward (heal/notice).
  function kill(w, i) {
    var m = w.mobs[i];
    if (!m) return null;
    Facraft.voxel.removeMesh('__mob' + m.id);
    w.mobs.splice(i, 1);
    return m.type;
  }

  function upload(m, i) {
    if (!Facraft.voxel.isNative()) return;
    var key = Math.round(m.x * 32) + '|' + Math.round(m.y * 32) + '|' +
      Math.round(m.z * 32) + '|' + Math.round(m.yaw * 64);
    if (key === m.uploadKey) return; // re-upload only on visible movement
    m.uploadKey = key;
    var mesh = mobMesh(m);
    Facraft.voxel.uploadMesh('__mob' + m.id, {
      origin: [0, 0, 0], positions: mesh.positions,
      colors: mesh.colors, indices: mesh.indices,
    });
  }

  return {
    tick: tick, mobMesh: mobMesh, raycast: raycast, kill: kill,
    MAX_MOBS: MAX_MOBS,
  };
})();
