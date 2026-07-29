// 3D Game — dodge the falling blocks in a real 3D scene (scene3d node on
// the runtime's flutter_cube host). Drag anywhere on the scene to steer
// the player cube; blocks fall toward the camera, three lives, best score
// persisted via jsr.storage.
//
// Demonstrates the imperative 3D bridge: jsr.scene3d.create/addModel/
// setTransforms (ONE batched transform message per frame)/removeModel,
// a rAF game loop, touch steering via a gestureDetector overlay, and a
// tap-to-restart game-over overlay.
(function() {
  // Unique per engine instance — the app's full view and its launcher tile
  // run separate engines, and stale controllers must never be reused.
  var sceneId = 'dodge-' + (jsr.instanceId || 'app') + '-' +
    Math.floor(Math.random() * 1e9);
  var playerId = 'player';

  // World layout (cube host units).
  var FIELD_X = 5;        // player clamp: x in [-FIELD_X, FIELD_X]
  var PLAYER_Z = 2;
  var SPAWN_Z = -22;
  var DESPAWN_Z = 5;
  var PLAYER_SPEED = 0.045; // units per drag pixel
  var START_LIVES = 3;

  var state;
  var lastTick = 0;
  var blockSeq = 0;

  function freshState() {
    return {
      running: true,
      score: 0,
      lives: START_LIVES,
      best: 0,
      elapsed: 0,
      fallSpeed: 6,
      spawnEvery: 0.8,
      spawnTimer: 0,
      playerX: 0,
      invulnerable: 0,
      hudTimer: 0,
      blocks: []
    };
  }

  function init() {
    jsr.scene3d.create(sceneId, {
      camera: { position: [0, 12, 14], target: [0, 0, -4], fov: 55 },
      light: { position: [5, 10, 8], color: '#ffffff', ambient: 0.5, diffuse: 0.7 }
    });
    jsr.scene3d.addModel(sceneId, {
      modelId: playerId,
      primitive: 'cube',
      color: '#22d3ee',
      position: [0, 0, PLAYER_Z],
      scale: [1.2, 1.2, 1.2]
    });
    jsr.storage.get('dodge-best').then(function(saved) {
      if (typeof saved === 'number' && saved > state.best) {
        state.best = saved;
        render();
      }
    });
    lastTick = 0;
    requestAnimationFrame(tick);
    render();
  }

  function restart() {
    var best = state.best;
    for (var i = 0; i < state.blocks.length; i++) {
      jsr.scene3d.removeModel(sceneId, state.blocks[i].id);
    }
    state = freshState();
    state.best = best;
    jsr.scene3d.setTransforms(sceneId, [
      { modelId: playerId, position: [0, 0, PLAYER_Z] }
    ]);
    render();
  }

  function spawnBlock() {
    var id = 'block-' + (blockSeq++);
    var x = (Math.random() * 2 - 1) * FIELD_X;
    state.blocks.push({ id: id, x: x, z: SPAWN_Z });
    jsr.scene3d.addModel(sceneId, {
      modelId: id,
      primitive: 'cube',
      color: '#ef4444',
      position: [x, 0, SPAWN_Z],
      scale: [1, 1, 1]
    });
  }

  function tick(elapsedMs) {
    requestAnimationFrame(tick);
    if (!state.running) return;
    if (!lastTick) { lastTick = elapsedMs; return; }
    var dt = Math.min((elapsedMs - lastTick) / 1000, 0.1);
    lastTick = elapsedMs;

    state.elapsed += dt;
    state.score = Math.floor(state.elapsed * 10) / 10;
    if (state.score > state.best) state.best = state.score;
    state.fallSpeed = 6 + state.elapsed * 0.15;
    state.spawnEvery = Math.max(0.35, 0.8 - state.elapsed * 0.01);
    if (state.invulnerable > 0) state.invulnerable -= dt;

    // Spawn and advance blocks.
    state.spawnTimer += dt;
    if (state.spawnTimer >= state.spawnEvery) {
      state.spawnTimer = 0;
      spawnBlock();
    }
    var items = [{ modelId: playerId, position: [state.playerX, 0, PLAYER_Z] }];
    var survivors = [];
    for (var i = 0; i < state.blocks.length; i++) {
      var b = state.blocks[i];
      b.z += state.fallSpeed * dt;
      if (b.z > DESPAWN_Z) {
        jsr.scene3d.removeModel(sceneId, b.id);
        continue;
      }
      if (state.invulnerable <= 0 && hitPlayer(b)) {
        jsr.scene3d.removeModel(sceneId, b.id);
        loseLife();
        if (!state.running) return;
        continue;
      }
      survivors.push(b);
      items.push({ modelId: b.id, position: [b.x, 0, b.z] });
    }
    state.blocks = survivors;

    // ONE batched transform message per frame.
    jsr.scene3d.setTransforms(sceneId, items);
    jsr.exportState({
      running: state.running,
      score: state.score,
      lives: state.lives,
      best: state.best,
      blockCount: state.blocks.length
    });

    // Refresh the HUD a few times per second (not every frame).
    state.hudTimer += dt;
    if (state.hudTimer >= 0.25) {
      state.hudTimer = 0;
      render();
    }
  }

  function hitPlayer(b) {
    return Math.abs(b.x - state.playerX) < 1.1 && Math.abs(b.z - PLAYER_Z) < 1.1;
  }

  function loseLife() {
    state.lives -= 1;
    state.invulnerable = 1.5;
    if (state.lives <= 0) {
      state.running = false;
      state.best = Math.round(Math.max(state.best, state.score) * 10) / 10;
      jsr.storage.set('dodge-best', state.best);
      jsr.exportState({
        running: false,
        score: state.score,
        lives: 0,
        best: state.best,
        blockCount: state.blocks.length
      });
    }
    render();
  }

  function clamp(v, lo, hi) {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  function hearts() {
    var s = '';
    for (var i = 0; i < START_LIVES; i++) {
      s += i < state.lives ? '❤️' : '🖤';
    }
    return s;
  }

  function statText(t, label, value) {
    return {
      type: 'column',
      mainAxisSize: 'min',
      crossAxisAlignment: 'center',
      children: [
        { type: 'text', data: label, style: { fontSize: 10, color: t.muted } },
        { type: 'text', data: String(value),
          style: { fontSize: 16, color: t.text, fontWeight: 'w600' } }
      ]
    };
  }

  function gameOverOverlay(t) {
    return {
      type: 'fill',
      color: '#B3000000',
      child: {
        type: 'center',
        child: {
          type: 'column',
          mainAxisSize: 'min',
          crossAxisAlignment: 'center',
          children: [
            { type: 'text', data: '💥 GAME OVER',
              style: { fontSize: 26, color: '#ef4444', fontWeight: 'w700' } },
            { type: 'sizedBox', height: 8 },
            { type: 'text', data: 'Score: ' + state.score.toFixed(1) + 's',
              style: { fontSize: 16, color: '#ffffff' } },
            { type: 'sizedBox', height: 14 },
            { type: 'button', label: 'Restart', onPressed: 'restart',
              color: t.accent }
          ]
        }
      }
    };
  }

  function render() {
    // Read jsr.theme fresh on every render — the object is replaced when
    // the host theme changes.
    var t = jsr.theme;
    var sceneChildren = [
      { type: 'scene3d', id: sceneId, interactive: false },
      // Transparent drag surface over the scene: steering by touch.
      {
        type: 'gestureDetector',
        onPanUpdate: 'steer',
        child: { type: 'fill', color: '#00000000' }
      }
    ];
    if (!state.running) {
      sceneChildren.push(gameOverOverlay(t));
    }
    jsr.render({
      type: 'column',
      crossAxisAlignment: 'stretch',
      children: [
        {
          type: 'expanded',
          child: { type: 'stack', fit: 'expand', children: sceneChildren }
        },
        {
          type: 'container',
          color: t.surface,
          padding: [10, 16, 10, 16],
          child: {
            type: 'row',
            mainAxisAlignment: 'spaceBetween',
            crossAxisAlignment: 'center',
            children: [
              statText(t, 'SCORE', state.score.toFixed(1) + 's'),
              { type: 'text', data: hearts(), style: { fontSize: 16 } },
              statText(t, 'BEST', state.best.toFixed(1) + 's'),
              { type: 'text', data: 'drag to steer',
                style: { fontSize: 11, color: t.muted } }
            ]
          }
        }
      ]
    });
  }

  jsr.onEvent(function(actionId, payload) {
    if (actionId === 'steer') {
      if (!state.running) return;
      state.playerX = clamp(
        state.playerX + (payload && payload.dx ? payload.dx : 0) * PLAYER_SPEED,
        -FIELD_X,
        FIELD_X
      );
    } else if (actionId === 'restart') {
      if (!state.running) restart();
    }
  });
  // Re-render with the new colors when the host flips light/dark mode.
  jsr._onThemeChange = function() { render(); };
  jsr.setTitle('🕹️ 3D Game');
  state = freshState();
  init();
})();
