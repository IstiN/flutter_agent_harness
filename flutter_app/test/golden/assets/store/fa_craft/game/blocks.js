// Block palette shared by worldgen, meshing, crafting, HUD.
var Facraft = Facraft || {};
Facraft.blocks = (function() {
  var AIR = 0, GRASS = 1, DIRT = 2, STONE = 3, LOG = 4, LEAVES = 5,
    SAND = 6, PLANKS = 7, BRICKS = 8, BEDROCK = 9;

  var NAMES = ['air', 'grass', 'dirt', 'stone', 'log', 'leaves', 'sand', 'planks', 'bricks', 'bedrock'];

  // Mesh colors [r,g,b] 0..1 per block id.
  var RGB = {};
  RGB[GRASS] = [0.35, 0.62, 0.26];
  RGB[DIRT] = [0.48, 0.35, 0.23];
  RGB[STONE] = [0.55, 0.55, 0.57];
  RGB[LOG] = [0.42, 0.31, 0.18];
  RGB[LEAVES] = [0.24, 0.46, 0.2];
  RGB[SAND] = [0.82, 0.75, 0.52];
  RGB[PLANKS] = [0.72, 0.56, 0.34];
  RGB[BRICKS] = [0.58, 0.32, 0.26];
  RGB[BEDROCK] = [0.18, 0.18, 0.2];

  // Per-type tone palettes: 4 deterministic tones per block. The mesher
  // picks one per block from a world-position hash and keys greedy
  // merging BY TONE, so same-tone neighbours still collapse — the world
  // reads as pixel-grain texture with zero per-frame cost and zero
  // view-dependent artifacts (unlike uv/shader texturing on the
  // software rasterizer). Tones within a palette must stay distinct
  // after *255 rounding (the merge key).
  var TONES = {};
  TONES[GRASS] = [[0.33, 0.60, 0.24], [0.38, 0.64, 0.26],
                  [0.34, 0.58, 0.29], [0.40, 0.62, 0.23]];
  // Grass SIDE faces read as dirt with a green tint (Minecraft grass
  // block: brown sides, green top) — kills the "all green" flat look.
  var GRASS_SIDE = [[0.44, 0.36, 0.22], [0.48, 0.39, 0.24],
                    [0.42, 0.34, 0.23], [0.46, 0.38, 0.21]];
  TONES[DIRT] = [[0.45, 0.33, 0.21], [0.51, 0.37, 0.24],
                 [0.47, 0.36, 0.26], [0.50, 0.34, 0.22]];
  TONES[STONE] = [[0.52, 0.52, 0.54], [0.58, 0.58, 0.60],
                  [0.54, 0.55, 0.56], [0.50, 0.51, 0.53]];
  TONES[LOG] = [[0.40, 0.29, 0.17], [0.45, 0.33, 0.19],
                [0.38, 0.28, 0.16], [0.43, 0.32, 0.20]];
  TONES[LEAVES] = [[0.22, 0.44, 0.18], [0.26, 0.48, 0.21],
                   [0.20, 0.42, 0.22], [0.25, 0.46, 0.17]];
  TONES[SAND] = [[0.80, 0.73, 0.50], [0.84, 0.77, 0.54],
                 [0.78, 0.72, 0.53], [0.83, 0.74, 0.49]];
  TONES[PLANKS] = [[0.70, 0.54, 0.32], [0.74, 0.58, 0.35],
                   [0.68, 0.53, 0.34], [0.72, 0.57, 0.31]];
  TONES[BRICKS] = [[0.56, 0.30, 0.25], [0.61, 0.34, 0.27],
                   [0.54, 0.31, 0.28], [0.59, 0.33, 0.24]];
  TONES[BEDROCK] = [[0.16, 0.16, 0.18], [0.20, 0.20, 0.22],
                    [0.17, 0.17, 0.21], [0.19, 0.18, 0.19]];

  var SOLID = [];
  SOLID[AIR] = false;
  SOLID[BEDROCK] = true;
  for (var i = 1; i <= 8; i++) SOLID[i] = true;

  return {
    AIR: AIR, GRASS: GRASS, DIRT: DIRT, STONE: STONE, LOG: LOG, LEAVES: LEAVES,
    SAND: SAND, PLANKS: PLANKS, BRICKS: BRICKS, BEDROCK: BEDROCK,
    MAX: BEDROCK,
    isSolid: function(id) { return SOLID[id] === true; },
    color: function(id) { return RGB[id] || RGB[STONE]; },
    // side=true -> the block's vertical-face palette (grass gets dirt
    // sides); everything else uses the one per-type palette.
    palette: function(id, side) {
      if (id === GRASS && side) return GRASS_SIDE;
      return TONES[id] || TONES[STONE];
    },
    name: function(id) { return NAMES[id] || '?'; },
    // The voxel.blocks palette spec (js_widget_runtime >= 0.4.163):
    // entry k colors block type k; 0 is the air placeholder. Four
    // deterministic tones per type — the runtime's greedy mesher picks
    // one per face from its own world-position hash, so the pixel-grain
    // texture survives the move from the JS mesher (whose hash lived in
    // mesh.js) to the Dart one; only the exact grain pattern differs.
    // Grass: green top tones, dirt-green side tones (Minecraft grass
    // block); every other type uses one palette on all faces.
    paletteSpec: function() {
      function hex1(c) {
        function h(v) {
          var s = Math.round(v * 255).toString(16);
          return s.length < 2 ? '0' + s : s;
        }
        return '#' + h(c[0]) + h(c[1]) + h(c[2]);
      }
      function tones4(t) {
        var out = [];
        for (var i = 0; i < 4; i++) out.push(hex1(t[i]));
        return out;
      }
      var out = [['#000000', '#000000', '#000000', '#000000']];
      for (var i = 1; i <= BEDROCK; i++) {
        var t = TONES[i] || TONES[STONE];
        if (i === GRASS) {
          out.push({ top: tones4(t), side: tones4(GRASS_SIDE) });
        } else {
          out.push(tones4(t));
        }
      }
      return out;
    },
  };
})();
