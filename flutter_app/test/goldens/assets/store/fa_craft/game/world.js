// Chunk grid + the single mutation gate. Every state change (blocks,
// inventory, health, mode) enters as a validated op in the event log so
// replay reconstructs the full world (I3) and hostile data fails closed (E5).
var Facraft = Facraft || {};
Facraft.world = (function() {
  var W = function() { return Facraft.worldgen; };
  var B = function() { return Facraft.blocks; };

  var LOAD_RADIUS = 3; // view distance in chunks (S1 spike will tune)
  var LIMIT = 4096;

  function key(cx, cz) { return cx + ',' + cz; }

  function chunkOf(w, cx, cz) {
    var k = key(cx, cz);
    var c = w.chunks[k];
    if (!c) { c = W().chunk(w.seed, cx, cz); w.chunks[k] = c; }
    return c;
  }

  function get(w, x, y, z) {
    if (y < 0 || y >= W().CHUNK_Y) return B().AIR;
    var cx = Math.floor(x / 16), cz = Math.floor(z / 16);
    var c = chunkOf(w, cx, cz);
    return c[W().index(x - cx * 16, y, z - cz * 16)];
  }

  function markDirty(w, cx, cz) { w.dirty.add(key(cx, cz)); }

  function isInt(v) { return typeof v === 'number' && isFinite(v) && Math.floor(v) === v; }

  var VALIDATORS = {
    set: function(op) {
      if (!isInt(op.x) || !isInt(op.z) || Math.abs(op.x) > LIMIT || Math.abs(op.z) > LIMIT) return 'bad x/z';
      if (!isInt(op.y) || op.y < 0 || op.y > 255) return 'bad y';
      if (!isInt(op.b) || op.b < 0 || op.b > Facraft.blocks.MAX) return 'bad block';
      return null;
    },
    craft: function(op) {
      if (typeof op.r !== 'string') return 'bad recipe';
      if (!isInt(op.n) || op.n < 1) return 'bad count';
      return null;
    },
    damage: function(op) {
      if (op.cause !== 'fall' && op.cause !== 'void') return 'bad cause';
      if (typeof op.n !== 'number' || !isFinite(op.n) || op.n <= 0 || op.n > 200) return 'bad amount';
      return null;
    },
    respawn: function() { return null; },
    mode: function(op) {
      if (op.m !== 'survival' && op.m !== 'creative') return 'bad mode';
      return null;
    },
  };

  function validate(op) {
    if (!op || typeof op !== 'object' || typeof op.t !== 'string') return 'bad op';
    var v = VALIDATORS[op.t];
    return v ? v(op) : 'unknown op ' + op.t;
  }

  var MUTATORS = {
    set: function(w, op) {
      // Unconditional set (last-write-wins): keeps the log replayable and
      // idempotent — guards live only at the trust boundaries.
      var B = Facraft.blocks;
      var old = get(w, op.x, op.y, op.z);
      if (op.b !== B.BEDROCK && (op.y === 0 || old === B.BEDROCK)) {
        throw new Error('bedrock is unbreakable');
      }
      setRaw(w, op.x, op.y, op.z, op.b);
      if (op.b === B.AIR) {
        if (old !== B.AIR) w.inventory[old] = (w.inventory[old] || 0) + 1; // break → collect
      } else if ((w.inventory[op.b] || 0) > 0) {
        w.inventory[op.b]--; // place → consume (floored at zero, deterministic)
      }
    },
    craft: function(w, op) {
      var res = Facraft.craft.craft(w.inventory, op.r, op.n);
      if (!res.ok) throw new Error('craft failed: ' + res.error);
      w.inventory = res.inv;
    },
    damage: function(w, op) {
      Facraft.survival.damage(w, op.cause, op.n);
    },
    respawn: function(w) {
      Facraft.survival.respawn(w, w.spawn);
      w.player.x = w.spawn.x; w.player.y = w.spawn.y; w.player.z = w.spawn.z;
    },
    mode: function(w, op) {
      w.mode = op.m;
      if (op.m === 'survival') w.player.flying = false;
    },
  };

  // The one mutation path. Throws on invalid ops; appends to the log on success.
  function apply(w, op) {
    if (!w.inventory) w.inventory = {}; // stub worlds (mesh tests) may omit it
    if (!w.logOps) w.logOps = [];
    var err = validate(op);
    if (err) throw new Error('rejected op: ' + err + ' ' + JSON.stringify(op));
    MUTATORS[op.t](w, op);
    w.logOps.push(op);
    return op;
  }

  function setRaw(w, x, y, z, b) {
    var cx = Math.floor(x / 16), cz = Math.floor(z / 16);
    chunkOf(w, cx, cz)[W().index(x - cx * 16, y, z - cz * 16)] = b;
    // Raw generated chunks are disposable; edited ones must survive view
    // eviction because regenerating terrain would erase the player's edit.
    if (w.edited) w.edited.add(key(cx, cz));
    markDirty(w, cx, cz);
    var lx = x - cx * 16, lz = z - cz * 16;
    if (lx === 0) markDirty(w, cx - 1, cz);
    if (lx === 15) markDirty(w, cx + 1, cz);
    if (lz === 0) markDirty(w, cx, cz - 1);
    if (lz === 15) markDirty(w, cx, cz + 1);
  }

  // Guarded entry point for live edits (used by tests to build terrain too).
  function setBlock(w, x, y, z, b) {
    return apply(w, { t: 'set', x: x, y: y, z: z, b: b });
  }

  function create(seed) {
    var spawnY = W().groundY(seed, 0, 0) + 1.01; // one scan, shared by spawn + player
    var w = {
      seed: seed,
      chunks: {},
      dirty: new Set(),
      edited: new Set(),
      meshes: new Map(),
      logOps: [],
      inventory: {},
      mode: 'survival',
      health: 20,
      dead: false,
      deaths: 0,
      dayTime: 0,
      spawn: { x: 0.5, y: spawnY, z: 0.5 },
      player: {
        x: 0.5, y: spawnY, z: 0.5,
        vx: 0, vy: 0, vz: 0, yaw: 0,
        // Spawn looking slightly DOWN: a level view from an eye 1.6
        // blocks above flat terrain fills the frame with sky and reads
        // as "the player hangs in a void" — the most-reported first
        // impression. The near ground must fill the lower half.
        pitch: -0.55,
        onGround: true, flying: false,
      },
    };
    ensureArea(w, 0, 0, LOAD_RADIUS);
    w.get = function(x, y, z) { return get(w, x, y, z); };
    w.set = function(x, y, z, b) { return apply(w, { t: 'set', x: x, y: y, z: z, b: b }); };
    return w;
  }

  // Validate then replay a full log into a fresh world. Fails closed BEFORE
  // any mutation when the log is hostile (E5).
  function fromLog(seed, ops) {
    if (!Array.isArray(ops)) throw new Error('log must be an array');
    for (var i = 0; i < ops.length; i++) {
      var err = validate(ops[i]);
      if (err) throw new Error('rejected op at ' + i + ': ' + err);
    }
    var w = create(seed);
    for (var j = 0; j < ops.length; j++) apply(w, ops[j]);
    return w;
  }

  function ensureArea(w, pcx, pcz, r) {
    for (var dx = -r; dx <= r; dx++) {
      for (var dz = -r; dz <= r; dz++) {
        if (!w.meshes.has(key(pcx + dx, pcz + dz))) markDirty(w, pcx + dx, pcz + dz);
      }
    }
  }

  return {
    create: create, fromLog: fromLog, apply: apply, setBlock: setBlock,
    get: get, key: key, ensureArea: ensureArea, validate: validate,
    // Data-only warm-up: runs the worldgen for a chunk without meshing or
    // uploading it, so a later mesh build / physics probe hits the cache
    // instead of bursting worldgen mid-frame (mobile stutter report).
    pregen: function(w, cx, cz) { chunkOf(w, cx, cz); },
    LOAD_RADIUS: LOAD_RADIUS,
  };
})();
