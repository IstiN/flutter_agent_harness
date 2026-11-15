// HUD: declarative JSON UI around the voxel viewport — crosshair, hotbar,
// hearts, notices, F3-style debug, crafting sheet, death dialog, touch pads.
// Pure: build the tree from state; jsr.render replaces the whole thing.
var Facraft = Facraft || {};
Facraft.hud = (function() {
  var B = function() { return Facraft.blocks; };

  function hotbarBlocks() {
    var b = B();
    return [b.GRASS, b.DIRT, b.STONE, b.LOG, b.LEAVES, b.SAND, b.PLANKS, b.BRICKS];
  }

  // Minecraft-style slot: a compact square, the block swatch filling it
  // (the grass green reads wide), stack count bottom-right, and a white
  // frame on the selected slot. No name labels — icons carry the UI.
  function slot(state, t, id, index) {
    var selected = state.selected === index;
    var count = state.world.mode === 'creative' ? '∞' : String(state.world.inventory[id] || 0);
    var c = B().color(id);
    return {
      // The slot itself carries the tap: payload.slot routes to the same
      // 'hotbar' action the digit keys fire (runtime >= 0.4.157 payload
      // merge; older runtimes fire a bare 'hotbar' = cycle — degraded but
      // never dead).
      type: 'gestureDetector', onTap: 'hotbar', payload: { slot: index },
      child: {
      type: 'container', hotbarIndex: index,
      width: 36, height: 36,
      decoration: {
        color: selected ? '#2a2f3ae6' : '#10131acc',
        borderRadius: 4,
        // runtime schema: flat borderColor/borderWidth (nested border:{} is
        // silently ignored by the decoration parser)
        borderColor: selected ? '#ffffff' : '#ffffff26',
        borderWidth: selected ? 2 : 1,
      },
      child: {
        type: 'stack', children: [
          { type: 'center',
            child: { type: 'rect', width: 30, height: 30, fill: swatch(c) } },
          { positioned: { right: 3, bottom: 2 },
            child: { type: 'text', data: count,
              style: { fontSize: 11, fontWeight: 'bold', color: '#ffffff' } } },
        ],
      },
      },
    };
  }

  function swatch(c) {
    function cc(v) {
      var x = Math.max(0, Math.min(255, Math.round(v * 255)));
      return (x < 16 ? '0' : '') + x.toString(16);
    }
    return '#' + cc(c[0]) + cc(c[1]) + cc(c[2]);
  }

  // Store capture: equal flexible actions keep the complete HUD inside the
  // narrowest phone viewport (the released fixed-size bar assumes a tablet).
  function captureAction(text, onTap, t) {
    return {
      type: 'expanded',
      child: {
        type: 'textButton', text: text, onTap: onTap,
        style: { backgroundColor: t.surface, foregroundColor: t.text },
      },
    };
  }

  function build(state, t) {
    var F = Facraft;
    var w = state.world;
    var sky = F.daynight.sky(w.dayTime);
    var hearts = [];
    var filled = Math.ceil(w.health / 2);
    for (var h = 0; h < filled; h++) {
      hearts.push({ type: 'icon', icon: 'favorite', heart: true, color: '#ef4444', size: 16 });
    }

    var hotbar = { type: 'row', mainAxisSize: 'min', children: [] };
    var hb = hotbarBlocks();
    for (var i = 0; i < hb.length; i++) hotbar.children.push(slot(state, t, hb[i], i + 1));

    var overlays = [];

    if (state.notice) {
      overlays.push({
        type: 'container', positioned: { left: 16, right: 16, bottom: 272 },
        ignorePointer: true,
        decoration: { color: t.surface, borderRadius: 8, borderColor: t.borderBright, borderWidth: 1 },
        padding: [10, 6, 10, 6],
        child: { type: 'text', data: state.notice, style: { fontSize: 12, color: t.text } },
      });
    }
    if (state.hint) {
      overlays.push({
        // translucent band: readable over any terrain, parked clear above the
        // joystick circle (top = 168)
        type: 'container', positioned: { left: 0, right: 0, bottom: 176 },
        ignorePointer: true, // labels must never eat look-drags (runtime >=0.4.133)
        decoration: { color: '#00000066' }, padding: [10, 4, 10, 4],
        child: { type: 'center', child: { type: 'text', data: 'Drag to look · tap to place · hold to break', style: { fontSize: 11, color: t.text }, width: 320 } },
      });
    }
    if (state.debug) {
      overlays.push({
        type: 'container', positioned: { left: 8, top: 8 },
        ignorePointer: true,
        decoration: { color: '#00000088', borderRadius: 4 }, padding: [6, 4, 6, 4],
        child: { type: 'text', debugOverlay: true, lines: debugLines(state), data: debugLines(state).join('\n'), style: { fontSize: 10, color: '#a7f3d0' } },
      });
    }

    var gameStack = {
      type: 'stack', children: [
        { // viewport area: drag = look, tap = place, long hold = break
          // (Minecraft touch scheme — stationary hold wins the gesture
          // arena, a moved finger loses to the look-drag). The voxel node
          // paints the world from bridge-resident chunk buffers (I4).
          // onScroll routes two-finger trackpad swipes into the same look
          // action (pointer scroll signals are not drags — runtime >=0.4.131).
          // Long-press + payload need runtime >= 0.4.157; older runtimes
          // keep tap-to-place + the Break button.
          type: 'container', positioned: { left: 0, top: 0, right: 0, bottom: 0 },
          child: {
            type: 'gestureDetector', onTap: 'place', onPanUpdate: 'look',
            onScroll: 'scrollLook',
            onLongPressStart: 'breakHold',
            onLongPressEnd: 'breakEnd', onLongPressCancel: 'breakEnd',
            child: F.voxel.view(),
          },
        },
        { // virtual joystick pad (touch walk) — parked above the hotbar strip:
          // at bottom-left it painted over the first hotbar slot
          type: 'container', positioned: { left: 16, bottom: 72 },
          child: {
            // panCancel: an OS-stolen pointer (iOS edge gesture) must
            // release the stick, not leave the player running (>=0.4.157).
            type: 'gestureDetector', onPanUpdate: 'joyMove', onPanEnd: 'joyEnd',
            onPanCancel: 'joyEnd',
            child: {
              type: 'container', width: 96, height: 96,
              decoration: { color: t.surfaceAlt, borderRadius: 48, borderColor: t.borderBright, borderWidth: 1 },
              child: { type: 'center', child: { type: 'text', data: 'move', style: { fontSize: 10, color: t.muted } } },
            },
          },
        },
        { // jump pad (touch): hold to hop — right-bottom, mirrors the joystick.
          // tapCancel covers the OS-stolen tap AFTER tapDown landed — without
          // it the jump stays held forever (>=0.4.157).
          type: 'container', positioned: { right: 16, bottom: 72 },
          child: {
            type: 'gestureDetector', onTapDown: 'jumpDown', onTapUp: 'jumpUp',
            onTapCancel: 'jumpUp',
            onPanEnd: 'jumpUp',
            child: {
              type: 'container', width: 96, height: 96,
              decoration: { color: t.surfaceAlt, borderRadius: 48, borderColor: t.borderBright, borderWidth: 1 },
              child: { type: 'center', child: { type: 'text', data: 'jump', style: { fontSize: 10, color: t.muted } } },
            },
          },
        },
        { // crosshair: clean symmetric plus (column cross-axis is START in
          // this runtime — center the vertical bar with explicit spacers).
          // ignorePointer: look-drags start at screen center — the crosshair
          // must never eat them.
          type: 'center', ignorePointer: true, child: {
            type: 'column', mainAxisSize: 'min', children: [
              { type: 'row', mainAxisSize: 'min', children: [
                { type: 'sizedBox', width: 6, height: 6 },
                { type: 'rect', width: 2, height: 6, fill: '#ffffffcc' },
                { type: 'sizedBox', width: 6, height: 6 },
              ] },
              { type: 'rect', width: 14, height: 2, fill: '#ffffffcc' },
              { type: 'row', mainAxisSize: 'min', children: [
                { type: 'sizedBox', width: 6, height: 6 },
                { type: 'rect', width: 2, height: 6, fill: '#ffffffcc' },
                { type: 'sizedBox', width: 6, height: 6 },
              ] },
            ],
          },
        },
        { // top action bar
          type: 'container', positioned: { left: 0, right: 0, top: 0 },
          padding: [8, 8, 8, 8],
          child: {
            type: 'row', children: [
              captureAction('Dig', 'break', t),
              captureAction('Craft', 'craft', t),
              captureAction('Go', 'mode', t),
              captureAction('Fly', 'fly', t),
              captureAction('F3', 'debug', t),
            ],
          },
        },
        { // hearts (survival, alive) — beside the joystick, above the hotbar
          type: 'container', positioned: { left: 0, right: 0, bottom: 76 },
          child: { type: 'center', child: { type: 'row', mainAxisSize: 'min', children: hearts } },
        },
        { // hotbar
          type: 'container', positioned: { left: 0, right: 0, bottom: 12 },
          child: { type: 'center', child: hotbar },
        },
      ],
    };
    for (var o = 0; o < overlays.length; o++) gameStack.children.push(overlays[o]);

    // ponytail: plain container root — listView collapsed to a ~20px strip
    // in the unbounded-height web preview host (issue #6); a container
    // fills the surface, same as voxel-sandbox's root.
    var root = {
      type: 'container', child: gameStack,
    };

    if (state.craftOpen) {
      root = {
        type: 'stack', children: [root, craftSheet(t)],
      };
    }
    if (w.dead) {
      root = {
        type: 'stack', children: [root, {
          type: 'dialog', deathDialog: true, title: 'You died', dismissible: false,
          message: 'Respawn to keep building. Your blocks are safe.',
          actions: [{ label: 'Respawn', onTap: 'respawn' }],
        }],
      };
    }
    return root;
  }

  function craftSheet(t) {
    var rows = [];
    var recipes = Facraft.craft.recipes;
    for (var i = 0; i < recipes.length; i++) {
      var r = recipes[i];
      rows.push({
        type: 'textButton', text: r.id + ' — craft 1', onTap: 'craftRecipe', payload: { id: r.id },
        style: { backgroundColor: t.surfaceAlt, foregroundColor: t.text },
      });
    }
    rows.push({ type: 'textButton', text: 'Close', onTap: 'closeCraft', style: { foregroundColor: t.muted } });
    return {
      type: 'bottomSheet', craftSheet: true, height: 260, color: t.surface,
      // top padding keeps recipe rows clear of the hotbar band while the
      // runtime's modal slide-up animation settles (goldens freeze it early)
      child: { type: 'padding', padding: [16, 48, 16, 12], child: { type: 'column', children: rows } },
    };
  }

  function debugLines(state) {
    var p = state.world.player;
    var lines = [
      'pos ' + p.x.toFixed(1) + ' ' + p.y.toFixed(1) + ' ' + p.z.toFixed(1),
      'fps ' + Math.round(state.fps || 0),
      'chunks ' + state.world.meshes.size,
      'day ' + state.world.dayTime.toFixed(0),
      'mode ' + state.world.mode,
      'edits ' + state.world.logOps.length,
    ];
    var pr = Facraft.prof;
    if (pr) {
      lines.push(
        'pipe ' + (Facraft.voxel.isNative() ? 'voxel' : 'unsupported'),
        'hud ' + (pr.hudMs / Math.max(1, pr.frames)).toFixed(1) +
          'ms mesh ' + (pr.meshMs / Math.max(1, pr.frames)).toFixed(1) + 'ms',
        'up ' + pr.uploads + ' (' + Math.round(pr.meshBytes / 1024) + 'KB)'
      );
    }
    return lines;
  }

  return { build: build, hotbarBlocks: hotbarBlocks };
})();
