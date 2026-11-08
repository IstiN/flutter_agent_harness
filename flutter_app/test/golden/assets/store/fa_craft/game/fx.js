// Juice: block-break particle bursts + physical meat drops.
// Particles live in one resident '__fx' chunk re-uploaded per frame
// while anything is alive; each meat drop is a '__drop<N>' resident
// chunk re-uploaded while it pops/bobs. All gameplay (heal on pickup)
// is decided by the caller via tick()'s return value, so the module
// stays renderer-agnostic (uploadMesh/removeMesh no-op off-native).
var Facraft = Facraft || {};
Facraft.fx = (function() {
  function B() { return Facraft.blocks; }
  function W() { return Facraft.world; }

  var parts = [];      // {x,y,z,vx,vy,vz,t,life,r,g,b}
  var nextDrop = 1;
  var rngState = 123456789; // LCG — fx stay deterministic for tests

  function rnd() {
    rngState = (rngState * 1103515245 + 12345) & 0x7fffffff;
    return rngState / 0x7fffffff;
  }

  // Meat slab palettes per mob type: [top, side].
  var MEAT = {
    chicken: [[0.88, 0.80, 0.70], [0.75, 0.66, 0.56]],
    pig: [[0.90, 0.55, 0.58], [0.78, 0.45, 0.48]],
  };
  // Death burst colors per mob type (feathers / hide + a red flash).
  var GIBS = {
    chicken: [[0.92, 0.92, 0.90], [0.85, 0.80, 0.72], [0.75, 0.25, 0.20]],
    pig: [[0.85, 0.60, 0.60], [0.70, 0.45, 0.42], [0.75, 0.25, 0.20]],
  };

  // A burst of small colored cubes from a broken block / killed mob.
  // colors: array of [r,g,b] cycled across particles.
  function burst(w, x, y, z, colors, n) {
    for (var i = 0; i < (n || 12); i++) {
      var c = colors[i % colors.length];
      var a = rnd() * Math.PI * 2;
      var sp = 1.5 + rnd() * 2.5;
      parts.push({
        x: x, y: y, z: z,
        vx: Math.cos(a) * sp, vy: 2.5 + rnd() * 3, vz: Math.sin(a) * sp,
        t: 0, life: 0.45 + rnd() * 0.3,
        r: c[0], g: c[1], b: c[2],
      });
    }
  }

  // A physical meat drop: pops out of the mob, lands, bobs until the
  // player walks over it (or it despawns after 45s).
  function spawnDrop(w, x, y, z, type) {
    if (!w.drops) w.drops = [];
    w.drops.push({ id: nextDrop++, x: x, y: y, z: z, vy: 3, type: type, t: 0 });
  }

  function solidAt(w, x, y, z) {
    return B().isSolid(W().get(w, Math.floor(x), Math.floor(y), Math.floor(z)));
  }

  // Box centered at (cx,cy,cz) with sizes (sx,sy,sz), yaw-rotated around
  // its center. cols = [top, side, bottom] — 24 verts so faces shade
  // flat. Face table is CCW-from-outside, the winding contract of
  // mesh.js (the painter backface-culls on it) — same as mobs.emitBox.
  function pushBox(P, C, I, cx, cy, cz, sx, sy, sz, cols, yaw) {
    var cs = Math.cos(yaw), sn = Math.sin(yaw);
    var x0 = -sx / 2, y0 = -sy / 2, z0 = -sz / 2;
    var x1 = sx / 2, y1 = sy / 2, z1 = sz / 2;
    var F = [
      [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1], 1],
      [[x0, y0, z1], [x0, y1, z1], [x0, y1, z0], [x0, y0, z0], 1],
      [[x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0], 0],
      [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1], 2],
      [[x1, y0, z1], [x1, y1, z1], [x0, y1, z1], [x0, y0, z1], 1],
      [[x0, y0, z0], [x0, y1, z0], [x1, y1, z0], [x1, y0, z0], 1],
    ];
    for (var f = 0; f < 6; f++) {
      var base = P.length / 3;
      var col = cols[F[f][4]];
      for (var v = 0; v < 4; v++) {
        var lx = F[f][v][0], ly = F[f][v][1], lz = F[f][v][2];
        P.push(cx + lx * cs + lz * sn, cy + ly, cz - lx * sn + lz * cs);
        C.push(col[0], col[1], col[2]);
      }
      I.push(base, base + 1, base + 2, base, base + 2, base + 3);
    }
  }

  function uploadParts() {
    if (!parts.length) { Facraft.voxel.removeMesh('__fx'); return; }
    var P = [], C = [], I = [];
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      var f = 1 - (p.t / p.life) * 0.4;
      pushBox(P, C, I, p.x, p.y, p.z, 0.09, 0.09, 0.09, [
        [p.r * f, p.g * f, p.b * f],
        [p.r * f * 0.8, p.g * f * 0.8, p.b * f * 0.8],
        [p.r * f * 0.6, p.g * f * 0.6, p.b * f * 0.6],
      ], 0);
    }
    Facraft.voxel.uploadMesh('__fx', {
      origin: [0, 0, 0], positions: P, colors: C, indices: I,
    });
  }

  function tickParts(w, dt) {
    if (!parts.length) return;
    for (var i = parts.length - 1; i >= 0; i--) {
      var p = parts[i];
      p.t += dt;
      p.vy -= 18 * dt;
      var nx = p.x + p.vx * dt, ny = p.y + p.vy * dt, nz = p.z + p.vz * dt;
      if (p.t >= p.life || solidAt(w, nx, ny, nz)) {
        parts.splice(i, 1); // expired or popped against a block
        continue;
      }
      p.x = nx; p.y = ny; p.z = nz;
    }
    uploadParts();
  }

  function groundY(w, x, z, fromY) {
    var y = Math.floor(fromY);
    for (var i = 0; i < 6 && y > 0; i++, y--) {
      if (B().isSolid(W().get(w, Math.floor(x), y, Math.floor(z)))) return y + 1;
    }
    return fromY - 6; // over the void: keep falling, despawn by time
  }

  function uploadDrop(d) {
    var cols = MEAT[d.type] || MEAT.chicken;
    var bob = d.vy === 0 ? Math.sin(d.t * 4) * 0.04 : 0;
    var P = [], C = [], I = [];
    pushBox(P, C, I, d.x, d.y + 0.10 + bob, d.z, 0.34, 0.12, 0.34, [
      cols[0], cols[1],
      [cols[1][0] * 0.7, cols[1][1] * 0.7, cols[1][2] * 0.7],
    ], d.t * 2.5);
    Facraft.voxel.uploadMesh('__drop' + d.id, {
      origin: [0, 0, 0], positions: P, colors: C, indices: I,
    });
  }

  function tickDrops(w, dt) {
    var got = [];
    if (!w.drops || !w.drops.length) return got;
    var pl = w.player;
    for (var i = w.drops.length - 1; i >= 0; i--) {
      var d = w.drops[i];
      d.t += dt;
      if (d.vy !== 0) {
        d.vy -= 14 * dt;
        d.y += d.vy * dt;
        var gy = groundY(w, d.x, d.z, d.y) + 0.06;
        if (d.vy < 0 && d.y <= gy) { d.y = gy; d.vy = 0; }
      }
      var dx = pl.x - d.x, dy = (pl.y + 0.8) - d.y, dz = pl.z - d.z;
      if (dx * dx + dy * dy + dz * dz < 1.9) {
        got.push(d.type); // walked over it: the caller feeds the player
      } else if (d.t <= 45) {
        uploadDrop(d);
        continue;
      }
      Facraft.voxel.removeMesh('__drop' + d.id);
      w.drops.splice(i, 1);
    }
    return got;
  }

  // Advance all fx. Returns the mob types picked up this tick ([] most
  // frames) — the caller turns those into health/notice.
  function tick(w, dt) {
    tickParts(w, dt);
    return tickDrops(w, dt);
  }

  return {
    burst: burst, spawnDrop: spawnDrop, tick: tick,
    GIBS: GIBS, MEAT: MEAT,
    particleCount: function() { return parts.length; },
  };
})();
