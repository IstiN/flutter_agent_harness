// Voxel host adapter (I4: the only file that knows the runtime 3D
// capability). Chunk buffers cross the bridge ONCE per chunk via
// voxel.mesh, each frame costs one tiny voxel.camera call, and the render
// tree carries a bare {type:'voxel'} node. js_widget_runtime >= 0.4.156
// is required: a failed (or hung) capability probe renders a static
// update card — there is no software meshes fallback.
var Facraft = Facraft || {};
Facraft.voxel = (function() {
  var M = function() { return Facraft.mesh; };
  var WG = function() { return Facraft.worldgen; };
  var B = function() { return Facraft.blocks; };

  var VIEW_RADIUS = 3;  // 7x7 chunk ring (49 chunks, 48m radius) — balances
  // wide horizon + rim fog with mobile CPU/GPU budgets on JIT-less iOS JSC
  var FOV = 72;

  // ---- native voxel node (I4) ----
  // js_widget_runtime 0.4.127+ owns a bridge-side voxel world: chunk
  // buffers cross the bridge ONCE per chunk (and per edit) via voxel.mesh
  // and the per-frame traffic shrinks to one tiny voxel.camera call. A
  // failed probe renders the update card — no scene3d meshes path exists.
  // 0.4.163+ additionally advertises `blocks: true` on the probe: the
  // chunk then crosses as raw base64 block bytes (~22 KB) and the greedy
  // mesher runs in Dart AOT instead of interpreted JS — the fix for the
  // world-streaming hitches on JIT-less engines (iOS JSC). Without the
  // flag (or pre-0.4.156 entirely) the JS-meshed voxel.mesh path stays.
  var NATIVE_ID = 'fa-craft';
  var nativeOn = null; // null = probe in flight; true/false once it lands
  var blocksCap = false; // probe said the runtime greedy-meshes in Dart
  var binCap = false;    // probe said the native bytes lane is wired
  var paletteSent = false; // palette crosses once per session, then cached
  var uploaded = {};   // chunk key -> true (re-upload driven by w.dirty)
  var hlCell = '';     // last uploaded highlight cell key

  function isNative() { return nativeOn === true; }
  function isBlocks() { return nativeOn === true && blocksCap; }

  function probe() {
    jsr.hostCall('voxel.attach', { id: NATIVE_ID }).then(
      function(res) {
        nativeOn = true;
        blocksCap = !!(res && res.blocks === true);
        // 0.4.171+ advertises `bin: true` when the native bytes lane is
        // wired: chunk bytes then cross as a typed array by
        // (pointer, length) — no base64 encode on the JS side, no
        // decode on the Dart side.
        binCap = !!(res && res.bin === true) &&
          typeof jsr.hostCallBinary === 'function';
      },
      function() { nativeOn = false; }
    );
    // A probe that never settles (pre-0.4.156 JSC: __jsr_host_call not
    // registered) must surface the update card too — fail it after ~2 s.
    setTimeout(function() { if (nativeOn === null) nativeOn = false; }, 2000);
  }

  // Fire-and-forget with a swallowed rejection: the bridge resolves voxel.*
  // itself, but a rejecting/absent handler must never wedge the game loop
  // (and the test harness counts calls without registering handlers).
  function push(name, args) {
    jsr.hostCall(name, args).then(function() {}, function() {});
  }

  // Per-face shading: a top/side/bottom brightness class, applied to the
  // four corner colors of every quad buildChunk emitted. Runs once per
  // chunk upload, not per frame.
  function shadeFaces(m, cx, cz) {
    var P = m.positions, C = m.colors, I = m.indices;
    var CLS = [0.62, 0.82, 1.0]; // bottom, side, top
    for (var q = 0; q < I.length; q += 6) {
      var v0 = I[q] * 3, v1 = I[q + 1] * 3, v3 = I[q + 5] * 3;
      var ax = P[v1] - P[v0], ay = P[v1 + 1] - P[v0 + 1], az = P[v1 + 2] - P[v0 + 2];
      var ux = P[v3] - P[v0], uy = P[v3 + 1] - P[v0 + 1], uz = P[v3 + 2] - P[v0 + 2];
      var ny = az * ux - ax * uz;
      var s = CLS[ny > 0 ? 2 : ny < 0 ? 0 : 1];
      // Flat per-quad tint: per-corner jitter on a greedy-merged quad
      // interpolates into WAVY gradient bands after the painter's texture
      // subdivision — the noise tile owns the pixel detail now, so the
      // face keeps one straight brightness class (Minecraft-flat look).
      var vs = [I[q], I[q + 1], I[q + 2], I[q + 5]];
      for (var v = 0; v < 4; v++) {
        var b = vs[v] * 3;
        C[b] = Math.min(1, C[b] * s);
        C[b + 1] = Math.min(1, C[b + 1] * s);
        C[b + 2] = Math.min(1, C[b + 2] * s);
      }
    }
  }

  // Base64 (standard alphabet, padded) over a Uint8Array — ES5, no btoa
  // dependency: the JS engines this widget runs on (QuickJS, iOS JSC)
  // do not ship one. 16 KB chunk → ~22 KB string, ~5.5k loop turns.
  var B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' + // 0-25
    'abcdefghijklmnopqrstuvwxyz' + // 26-51
    '0123456789+/'; // 52-63
  function b64(u8) {
    var out = [];
    var n = u8.length, i, h;
    for (i = 0; i + 2 < n; i += 3) {
      h = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
      out.push(B64A[(h >> 18) & 63], B64A[(h >> 12) & 63],
               B64A[(h >> 6) & 63], B64A[h & 63]);
    }
    var rem = n - i;
    if (rem === 1) {
      h = u8[i] << 16;
      out.push(B64A[(h >> 18) & 63], B64A[(h >> 12) & 63], '=', '=');
    } else if (rem === 2) {
      h = (u8[i] << 16) | (u8[i + 1] << 8);
      out.push(B64A[(h >> 18) & 63], B64A[(h >> 12) & 63],
               B64A[(h >> 6) & 63], '=');
    }
    return out.join('');
  }

  // ES5 utf-8: the packed header JSON is pure ASCII in practice, but the
  // encoder stays correct for any id/key a host hands us.
  function utf8Bytes(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      else {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
    }
    return out;
  }

  // Packs one chunk for the zero-JSON lane. Layout (little-endian, see
  // JsVoxelChunk.parseBinaryEnvelope in the runtime): u32 magic 'JVXM',
  // u32 version = 1, u32 header length, the header JSON bytes padded
  // with NULs to a 4-byte boundary, then the RAW block bytes (no
  // base64). Fire-and-forget through jsr.hostCallBinary: engines with
  // the native bytes lane move (pointer, length) only.
  function packBlocks(key, cx, cz, bytes, palette) {
    var head = utf8Bytes(JSON.stringify({
      id: NATIVE_ID,
      key: key,
      origin: [cx * 16, 0, cz * 16],
      size: [16, WG().CHUNK_Y, 16],
      palette: palette || undefined,
    }));
    var pad = (4 - (head.length % 4)) % 4;
    var total = 12 + head.length + pad + bytes.length;
    var buf = new ArrayBuffer(total);
    var dv = new DataView(buf);
    dv.setUint32(0, 0x4A56584D, true);
    dv.setUint32(4, 1, true);
    dv.setUint32(8, head.length, true);
    new Uint8Array(buf, 12, head.length).set(head);
    new Uint8Array(buf, 12 + head.length + pad, bytes.length).set(bytes);
    return new Uint8Array(buf);
  }

  function uploadChunk(w, cx, cz, prof) {
    var k = cx + ',' + cz;
    if (isBlocks()) {
      // Native-fast path: raw chunk bytes only. The runtime greedy-meshes
      // in Dart AOT and keeps the bytes resident so later chunks cull
      // their interior faces against this one (and re-mesh this one when
      // an edit changes its border). Palette crosses once, then lives in
      // the runtime's per-instance cache.
      var c = w.chunks[k];
      if (!c) { c = WG().chunk(w.seed, cx, cz); w.chunks[k] = c; }
      if (binCap) {
        // 0.4.171+ packed lane: the bytes cross as a typed array by
        // (pointer, length) — same 'JVXM' envelope as voxel.mesh.bin
        // (magic, version, JSON header, NUL-padded to 4 bytes), but the
        // body is the RAW block bytes. No b64 expansion, no encode.
        jsr.hostCallBinary('voxel.blocks.bin',
          packBlocks(k, cx, cz, c, !paletteSent ? B().paletteSpec() : null));
        paletteSent = true;
      } else {
        var args = {
          id: NATIVE_ID, key: k,
          origin: [cx * 16, 0, cz * 16],
          size: [16, WG().CHUNK_Y, 16],
          blocks: b64(c),
        };
        if (!paletteSent) { args.palette = B().paletteSpec(); paletteSent = true; }
        push('voxel.blocks', args);
      }
      if (prof) {
        prof.uploads++;
        prof.meshBytes += binCap ? c.length : ((c.length * 4 + 2) / 3) | 0;
      }
    } else {
      var m = M().buildChunk(w, cx, cz);
      shadeFaces(m, cx, cz);
      push('voxel.mesh', {
        id: NATIVE_ID, key: k,
        origin: m.origin, positions: m.positions,
        colors: m.colors, indices: m.indices,
      });
      if (prof) {
        prof.uploads++;
        prof.meshBytes += (m.positions.length + m.colors.length + m.indices.length) * 4;
      }
    }
    uploaded[k] = true;
    // ensureArea re-marks every chunk missing from w.meshes each frame —
    // a sentinel entry stops the loop (only this uploader fills w.meshes).
    w.meshes.set(k, true);
  }

  // Upload the chunks of the view ring that are new or dirty, at most
  // UPLOADS_PER_FRAME per call, nearest-to-player first. The boot wall
  // from the field report was this loop uploading the whole 5x5 ring
  // (~25 chunk worldgens + ~2 MB of mesh JSON) in ONE frame — streaming
  // spreads it over ~9 frames so the first pixels land in <100 ms and
  // the terrain pops in Minecraft-style. Dirty chunks outside the ring
  // stay marked and upload when the ring reaches them.
  // When the player crosses a chunk boundary, chunks beyond the ring+1
  // margin are evicted (voxel.chunkRemove) so long walks do not grow the
  // resident set — and the per-frame painter triangle count — forever.
  var lastEvictPcx = null, lastEvictPcz = null;
  var lastColdPcx = null, lastColdPcz = null, coldComplete = false;
  var UPLOADS_PER_FRAME = 3;
  var GENS_PER_FRAME = 2;  // data-only worldgen warm-up budget per frame

  // Adaptive stream budget: the tick loop keeps an EWMA of the per-frame
  // cost and clamps the upload budget so a hitching frame sheds work
  // instead of compounding it. On JIT-less engines a streamed chunk can
  // cost 10-30 ms of interpreted worldgen — 3 per frame stalls the walk;
  // 1 per frame just pops the far ring in a moment later (invisible at
  // streaming distance). budgetFor() is pure — unit-tested thresholds.
  var streamBudget = UPLOADS_PER_FRAME;
  var budgetPinned = false;
  function budgetFor(tickMs) {
    if (typeof tickMs !== 'number' || !isFinite(tickMs) || tickMs <= 0) {
      return UPLOADS_PER_FRAME;
    }
    if (tickMs > 33) return 1;
    if (tickMs > 22) return 2;
    return UPLOADS_PER_FRAME;
  }
  function setBudget(n) {
    if (typeof n !== 'number' || !isFinite(n)) return;
    streamBudget = Math.max(1, Math.min(UPLOADS_PER_FRAME, Math.round(n)));
  }
  // Deterministic override for tests and field diagnosis: pins the budget
  // so the per-tick adaptive update leaves it alone until reset().
  function pinBudget(n) { budgetPinned = true; setBudget(n); }
  function isBudgetPinned() { return budgetPinned; }
  function currentBudget() { return streamBudget; }

  // Renderer residency and JS world data have different lifetimes. Removing
  // a host chunk does not release its Uint8Array in w.chunks, so an endless
  // walk otherwise retains every chunk ever visited (~16 KB each). Keep
  // player-edited chunks; all other bytes regenerate deterministically.
  function evictWorldData(w, pcx, pcz) {
    for (var key in w.chunks) {
      var parts = key.split(',');
      var kx = parseInt(parts[0], 10), kz = parseInt(parts[1], 10);
      if (Math.abs(kx - pcx) <= VIEW_RADIUS + 1 &&
          Math.abs(kz - pcz) <= VIEW_RADIUS + 1) continue;
      var edited = w.edited && w.edited.has(key);
      var legacyDirty = !w.edited && w.dirty.has(key);
      if (!edited && !legacyDirty) delete w.chunks[key];
      if (w.meshes) w.meshes.delete(key);
      w.dirty.delete(key);
    }
  }

  function uploadView(w, pcx, pcz, prof) {
    var todo = [];
    for (var dx = -VIEW_RADIUS; dx <= VIEW_RADIUS; dx++) {
      for (var dz = -VIEW_RADIUS; dz <= VIEW_RADIUS; dz++) {
        var cx = pcx + dx, cz = pcz + dz, key = cx + ',' + cz;
        if (uploaded[key] && !w.dirty.has(key)) continue;
        todo.push({ cx: cx, cz: cz, key: key, d2: dx * dx + dz * dz });
      }
    }
    todo.sort(function(a, b) { return a.d2 - b.d2; });
    var n = Math.min(streamBudget, todo.length);
    for (var i = 0; i < n; i++) {
      uploadChunk(w, todo[i].cx, todo[i].cz, prof);
      w.dirty.delete(todo[i].key);
    }
    return { uploaded: n, pending: todo.length - n };
  }

  // Worldgen smoothing: data-only warm-up of the ring+1 margin, biased
  // toward the direction of travel. Sprinting into fresh terrain used to
  // burst ~5 lazy chunk generations (world.js get → worldgen.chunk) plus
  // their mesh builds into the boundary-crossing frames — the mobile
  // stutter report. Spreading generation over the approach keeps every
  // frame's worldgen work bounded.
  function warmView(w, player, pcx, pcz, uploadedCount) {
    var cold = [];
    if (!coldComplete || pcx !== lastColdPcx || pcz !== lastColdPcz) {
      lastColdPcx = pcx; lastColdPcz = pcz;
      for (var gx = -VIEW_RADIUS - 1; gx <= VIEW_RADIUS + 1; gx++) {
        for (var gz = -VIEW_RADIUS - 1; gz <= VIEW_RADIUS + 1; gz++) {
          if (!w.chunks[(pcx + gx) + ',' + (pcz + gz)]) {
            var ahead = (player.vx || 0) * gx + (player.vz || 0) * gz;
            cold.push({ cx: pcx + gx, cz: pcz + gz, ahead: -ahead,
                        d2: gx * gx + gz * gz });
          }
        }
      }
      coldComplete = cold.length === 0;
    }
    cold.sort(function(a, b) { return (a.ahead - b.ahead) || (a.d2 - b.d2); });
    var warm = uploadedCount > 0 ? 0 : Math.min(Math.max(0, streamBudget - 1), cold.length);
    for (var g = 0; g < warm; g++) {
      Facraft.world.pregen(w, cold[g].cx, cold[g].cz);
    }
  }

  function evictView(w, pcx, pcz) {
    if (pcx === lastEvictPcx && pcz === lastEvictPcz) return;
    lastEvictPcx = pcx; lastEvictPcz = pcz;
    for (var key in uploaded) {
      var parts = key.split(',');
      var kx = parseInt(parts[0], 10), kz = parseInt(parts[1], 10);
      if (Math.abs(kx - pcx) > VIEW_RADIUS + 1 ||
          Math.abs(kz - pcz) > VIEW_RADIUS + 1) {
        push('voxel.chunkRemove', { id: NATIVE_ID, key: key });
        delete uploaded[key];
      }
    }
    evictWorldData(w, pcx, pcz);
  }

  function sync(w, player, prof) {
    if (!isNative()) return { uploaded: 0, pending: 0 };
    var pcx = Math.floor(player.x / 16), pcz = Math.floor(player.z / 16);
    var result = uploadView(w, pcx, pcz, prof);
    warmView(w, player, pcx, pcz, result.uploaded);
    evictView(w, pcx, pcz);
    return result;
  }

  // Aimed-face marker: a bright border RING on the raycast entry face —
  // top face when looking down, side face when facing a wall. Reads as a
  // selection outline (Minecraft-style) instead of a shaded blob.
  // Face tables mirror mesh.js (CCW-from-outside winding contract).
  var HL_AXES = [[1, 2], [1, 2], [0, 2], [0, 2], [0, 1], [0, 1]];
  var HL_CORNERS = [
    [[0, 0], [1, 0], [1, 1], [0, 1]], // +x
    [[0, 1], [1, 1], [1, 0], [0, 0]], // -x
    [[0, 0], [0, 1], [1, 1], [1, 0]], // +y
    [[0, 0], [1, 0], [1, 1], [0, 1]], // -y
    [[1, 0], [1, 1], [0, 1], [0, 0]], // +z
    [[0, 0], [0, 1], [1, 1], [1, 0]], // -z
  ];
  var HL_LIFT = 0.004; // off the surface — no coplanar flicker
  var HL_INSET = 0.10; // border thickness, in blocks

  function faceOutlineMesh(t) {
    var n = [t.nx, t.ny, t.nz];
    var A = n[0] !== 0 ? 0 : (n[1] !== 0 ? 1 : 2);
    var positive = n[A] > 0;
    var f = A * 2 + (positive ? 0 : 1);
    var U = HL_AXES[f][0], V = HL_AXES[f][1];
    var a = positive ? 1 + HL_LIFT : -HL_LIFT;
    var base = [t.x, t.y, t.z];
    // corner point of rect (u0,u1,v0,v1) at sign (su, sv)
    function corner(su, sv, u0, u1, v0, v1) {
      var q = [0, 0, 0];
      q[A] = base[A] + a;
      q[U] = base[U] + (su ? u1 : u0);
      q[V] = base[V] + (sv ? v1 : v0);
      return q;
    }
    var cs = HL_CORNERS[f];
    var P = [], C = [], I = [];
    var o = [-HL_LIFT, 1 + HL_LIFT], inn = [HL_INSET, 1 - HL_INSET];
    for (var k = 0; k < 4; k++) {
      var k2 = (k + 1) % 4;
      var quad = [
        corner(cs[k][0], cs[k][1], o[0], o[1], o[0], o[1]),
        corner(cs[k2][0], cs[k2][1], o[0], o[1], o[0], o[1]),
        corner(cs[k2][0], cs[k2][1], inn[0], inn[1], inn[0], inn[1]),
        corner(cs[k][0], cs[k][1], inn[0], inn[1], inn[0], inn[1]),
      ];
      var vb = P.length / 3;
      for (var v = 0; v < 4; v++) {
        P.push(quad[v][0], quad[v][1], quad[v][2]);
        C.push(1, 1, 1); // bright — reads on any block, day or night
      }
      I.push(vb, vb + 1, vb + 2, vb, vb + 2, vb + 3);
    }
    return { positions: P, colors: C, indices: I };
  }

  // Targeted-block marker as a resident '__hl' chunk: replaced wholesale
  // whenever the aim cell OR the aimed face changes (an empty aim parks
  // a zero-area quad at the origin instead of a chunkRemove, so older
  // runtimes keep working).
  function highlight(w, target) {
    if (!isNative()) return;
    var cell = target && target.hit
      ? target.x + ',' + target.y + ',' + target.z + ',' +
        target.nx + ',' + target.ny + ',' + target.nz
      : '';
    if (cell === hlCell) return;
    hlCell = cell;
    var flat = cell ? faceOutlineMesh(target)
      : { positions: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          colors: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          indices: [0, 1, 2, 0, 2, 3] };
    push('voxel.mesh', {
      id: NATIVE_ID, key: '__hl', origin: [0, 0, 0],
      overlay: true, // depth-biased in the painter: wins over the coplanar face
      positions: flat.positions, colors: flat.colors, indices: flat.indices,
    });
  }

  // One tiny bridge call per frame — the whole per-frame 3D cost natively.
  function camera(w, player, sky) {
    if (!isNative()) return;
    push('voxel.camera', {
      id: NATIVE_ID,
      position: [player.x, player.y + Facraft.physics.EYE_H, player.z],
      yaw: player.yaw, pitch: player.pitch,
      light: sky.light, skyColor: sky.color, fov: FOV,
      // Distance fog tied to the stream radius: the far edge of the
      // meshed world fades into the sky instead of cutting off into
      // void — the fix for the "islands hanging in emptiness" read.
      fog: [(VIEW_RADIUS - 1) * 16 - 10, VIEW_RADIUS * 16 + 4],
      // No shader-noise texturing: affine uv on a software rasterizer
      // can only be tamed by adaptive subdivision, and every variant of
      // that (w1..w5) traded one artifact for another — swimming, band
      // pops, diagonal creases, contrast boundaries — at 20-60k tris.
      // The blocky texture feel lives in the mesher's per-block jitter.
      texture: false,
    });
  }

  // The viewport node for the current frame. Native-only: geometry lives
  // bridge-side, the render tree carries none of it. While the probe is
  // in flight the bare voxel node is already correct on any runtime that
  // can run the game; a failed (or 2 s-timed-out) probe renders a static
  // update card instead of any world geometry.
  function view() {
    if (nativeOn !== false) return { type: 'voxel', id: NATIVE_ID };
    var t = jsr.theme;
    return {
      type: 'container', decoration: { color: t.bg },
      child: {
        type: 'center',
        child: {
          type: 'text',
          data: 'fa-craft needs js_widget_runtime >= 0.4.156 — update the app',
          style: { fontSize: 14, color: t.text },
          width: 320,
        },
      },
    };
  }

  function reset() {
    uploaded = {}; hlCell = '';
    paletteSent = false;
    budgetPinned = false;
    lastEvictPcx = null; lastEvictPcz = null;
    lastColdPcx = null; lastColdPcz = null; coldComplete = false;
  }

  return {
    view: view, reset: reset,
    probe: probe, isNative: isNative, isBlocks: isBlocks,
    sync: sync, camera: camera, highlight: highlight,
    budgetFor: budgetFor, setBudget: setBudget, currentBudget: currentBudget,
    pinBudget: pinBudget, isBudgetPinned: isBudgetPinned,
    b64: b64,
    // Resident-chunk primitives for dynamic actors (mobs): uploadMesh
    // replaces a chunk wholesale, removeMesh evicts it (despawn).
    uploadMesh: function(key, flat) {
      if (!isNative()) return;
      push('voxel.mesh', {
        id: NATIVE_ID, key: key, origin: flat.origin,
        positions: flat.positions, colors: flat.colors,
        indices: flat.indices,
      });
    },
    removeMesh: function(key) {
      if (!isNative()) return;
      push('voxel.chunkRemove', { id: NATIVE_ID, key: key });
    },
  };
})();
