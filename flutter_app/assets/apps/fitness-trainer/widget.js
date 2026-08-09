// Fitness Trainer — guided workout with a 3D animated coach.
// The coach is a realistic human baked from NAVER's anny body model
// (Apache-2.0, assets/apps/fitness-trainer/models/coach_anny.glb — 10
// skeletal clips authored in tools/bake_coach_glb.py) rendered via
// scene3d (flame_3d). Press START and follow along: each exercise plays
// its clip with a countdown, rests play Idle, the finale plays Cheer.
// Pause / skip / quit any time. Completed sessions persist in
// jsr.storage. All colors from jsr.theme.
(function() {
  var SVG = {
    dumbbell: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 7.5v9M4.5 9v6M16.5 7.5v9M19.5 9v6M7.5 12h9"/></svg>',
    flame: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/></svg>',
    timer: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2h4M12 8v4l2.5 2.5"/><circle cx="12" cy="14" r="8"/></svg>',
    play: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M8 5.5v13l11-6.5z"/></svg>',
    pause: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M7 5h4v14H7zM13 5h4v14h-4z"/></svg>',
    next: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M6 5.5v13l9-6.5zM17 5h2v14h-2z"/></svg>',
    trophy: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 21h8M12 17v4M7 4h10v6a5 5 0 0 1-10 0zM7 6H4a1 1 0 0 0-1 1c0 2 1.5 3.5 4 3.6M17 6h3a1 1 0 0 1 1 1c0 2-1.5 3.5-4 3.6"/></svg>'
  };

  // The workout: exercise steps + rest steps between them. `clip` is a
  // skeletal animation name inside rogue.glb.
  var PLAN = [
    { type: 'exercise', name: 'Jumping Jacks', detail: 'warm-up', clip: 'Jump_Full_Long', dur: 40 },
    { type: 'rest', dur: 15 },
    { type: 'exercise', name: 'Squats', detail: 'legs', clip: 'PickUp', dur: 40 },
    { type: 'rest', dur: 15 },
    { type: 'exercise', name: 'Shadow Boxing', detail: 'arms', clip: 'Unarmed_Melee_Attack_Punch_A', dur: 40 },
    { type: 'rest', dur: 15 },
    { type: 'exercise', name: 'Lunges', detail: 'legs & balance', clip: 'Dodge_Left', clipAlt: 'Dodge_Right', dur: 40 },
    { type: 'rest', dur: 15 },
    { type: 'exercise', name: 'High Knees', detail: 'cardio', clip: 'Running_A', dur: 30 },
    { type: 'rest', dur: 15 },
    { type: 'exercise', name: 'Plank Hold', detail: 'core', clip: 'Lie_Idle', dur: 30 }
  ];

  var sceneId = 'fitness-' + (jsr.instanceId || 'app') + '-' + Math.floor(Math.random() * 1e9);
  var MODEL_SRC = 'apps/fitness-trainer/models/coach_anny.glb';

  var state = {
    screen: 'home', // home | workout | done
    step: 0, // index into PLAN
    left: 0, // seconds left in the current step
    paused: false,
    altClip: false, // lunges alternate left/right
    stats: { sessions: 0, seconds: 0, lastDay: null }
  };

  var sceneReady = false;

  function clipFor(step) {
    if (step.type === 'rest') return 'Idle';
    if (step.clipAlt && state.altClip) return step.clipAlt;
    return step.clip;
  }

  function playCurrent() {
    if (!sceneReady) return;
    jsr.scene3d.playAnimation(sceneId, 'coach', { name: clipFor(PLAN[state.step]), loop: true });
  }

  function exportNow() {
    var step = PLAN[state.step];
    jsr.exportState({
      screen: state.screen,
      step: step.type === 'exercise' ? step.name : 'rest',
      secondsLeft: state.left,
      paused: state.paused,
      sessionsCompleted: state.stats.sessions
    });
  }

  function tick() {
    if (state.screen !== 'workout' || state.paused) return;
    state.left -= 1;
    state.stats.seconds += 1;
    // Lunges: alternate sides every 2 seconds.
    var step = PLAN[state.step];
    if (step.clipAlt && state.left % 2 === 0) {
      state.altClip = !state.altClip;
      playCurrent();
    }
    if (state.left <= 0) {
      advance();
      return;
    }
    render();
  }

  function advance() {
    state.step += 1;
    if (state.step >= PLAN.length) {
      finish();
      return;
    }
    state.left = PLAN[state.step].dur;
    state.altClip = false;
    playCurrent();
    render();
  }

  function startWorkout() {
    state.screen = 'workout';
    state.step = 0;
    state.left = PLAN[0].dur;
    state.paused = false;
    state.altClip = false;
    playCurrent();
    render();
  }

  function finish() {
    state.screen = 'done';
    state.stats.sessions += 1;
    state.stats.lastDay = new Date().toDateString();
    jsr.storage.set('fitness_stats', state.stats);
    if (sceneReady) jsr.scene3d.playAnimation(sceneId, 'coach', { name: 'Cheer', loop: true });
    render();
  }

  function togglePause() {
    state.paused = !state.paused;
    if (sceneReady) {
      jsr.scene3d.playAnimation(sceneId, 'coach', { name: state.paused ? 'Idle' : clipFor(PLAN[state.step]), loop: true });
    }
    render();
  }

  function quit() {
    state.screen = 'home';
    state.paused = false;
    if (sceneReady) jsr.scene3d.playAnimation(sceneId, 'coach', { name: 'Idle', loop: true });
    render();
  }

  setInterval(tick, 1000);

  // ── shared widgets ─────────────────────────────────────────────────────

  function chip(t, iconSvg, text, accent) {
    return { type: 'container', padding: [10, 6, 10, 6], decoration: { color: t.surfaceAlt, borderRadius: 16, border: { color: t.border } },
      child: { type: 'row', mainAxisSize: 'min', children: [
        { type: 'svg', data: iconSvg, width: 14, color: accent ? t.accent : t.muted },
        { type: 'sizedBox', width: 5 },
        { type: 'text', data: text, style: { color: accent ? t.accent : t.muted, fontSize: 11, fontWeight: 'w600' } }
      ] } };
  }

  function header(t, subtitle, chips) {
    return { type: 'padding', padding: [16, 12, 16, 8], child: { type: 'row', children: [
      { type: 'container', width: 34, height: 34, alignment: 'center', decoration: { color: t.surfaceAlt, borderRadius: 10 },
        child: { type: 'svg', data: SVG.dumbbell, width: 20, color: t.accent2 } },
      { type: 'sizedBox', width: 10 },
      { type: 'expanded', child: { type: 'column', crossAxisAlignment: 'start', mainAxisSize: 'min', children: [
        { type: 'text', data: 'Fitness Trainer', style: { color: t.text, fontSize: 15, fontWeight: 'w700' } },
        { type: 'text', data: subtitle, style: { color: t.muted, fontSize: 11 } }
      ] } }
    ].concat(chips || []) } };
  }

  function sceneBox(t, height) {
    return { type: 'container', margin: [16, 4, 16, 0], height: height,
      decoration: { color: t.surface, borderRadius: 16, border: { color: t.borderBright } },
      child: { type: 'scene3d', id: sceneId } };
  }

  function bigButton(t, label, icon, action, accent) {
    return { type: 'button', label: label, icon: icon,
      color: accent ? t.accent2 : t.surfaceAlt,
      textColor: accent ? t.onAccent : t.text,
      onPressed: action };
  }

  function fmt(sec) {
    var m = Math.floor(sec / 60), s = sec % 60;
    return m + ':' + (s < 10 ? '0' + s : s);
  }

  function totalSeconds() {
    var sum = 0;
    for (var i = 0; i < PLAN.length; i++) sum += PLAN[i].dur;
    return sum;
  }

  // ── screens ────────────────────────────────────────────────────────────

  function homeScreen(t) {
    var mins = Math.round(totalSeconds() / 60);
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      header(t, 'Full body · ~' + mins + ' min', [
        chip(t, SVG.flame, state.stats.sessions + '', true)
      ]),
      sceneBox(t, 260),
      { type: 'padding', padding: [16, 10, 16, 0], child: { type: 'column', crossAxisAlignment: 'stretch', children: [
        { type: 'text', data: "Today's workout", style: { color: t.text, fontSize: 15, fontWeight: 'w700' } },
        { type: 'sizedBox', height: 6 },
        { type: 'text', data: planSummary(), style: { color: t.muted, fontSize: 12 } }
      ] } },
      { type: 'padding', padding: [16, 14, 16, 0], child: bigButton(t, 'START WORKOUT', 'play_arrow', 'start', true) }
    ] } };
  }

  function planSummary() {
    var names = [];
    for (var i = 0; i < PLAN.length; i++) {
      if (PLAN[i].type === 'exercise') names.push(PLAN[i].name);
    }
    return names.join(' · ');
  }

  function workoutScreen(t) {
    var step = PLAN[state.step];
    var isRest = step.type === 'rest';
    var nextEx = null;
    for (var i = state.step + 1; i < PLAN.length; i++) {
      if (PLAN[i].type === 'exercise') { nextEx = PLAN[i].name; break; }
    }
    var done = 0;
    for (var j = 0; j < state.step; j++) done += PLAN[j].dur;
    done += PLAN[state.step].dur - state.left;
    var total = totalSeconds();
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      header(t, isRest ? 'Rest' : step.name + ' · ' + step.detail, [
        chip(t, SVG.timer, fmt(state.left), state.left <= 5 && !isRest)
      ]),
      { type: 'padding', padding: [16, 0, 16, 0], child: progressBar(t, done, total) },
      sceneBox(t, 250),
      { type: 'padding', padding: [16, 8, 16, 0], child: { type: 'column', crossAxisAlignment: 'center', children: [
        { type: 'text', data: isRest ? 'REST' : step.name.toUpperCase(),
          style: { color: isRest ? t.muted : t.accent, fontSize: 13, fontWeight: 'w700', letterSpacing: 1.1 } },
        { type: 'sizedBox', height: 2 },
        { type: 'text', data: state.paused ? 'paused' : (isRest && nextEx ? 'next: ' + nextEx : fmt(state.left)),
          style: { color: t.muted, fontSize: 11 } }
      ] } },
      { type: 'padding', padding: [16, 10, 16, 0], child: { type: 'row', children: [
        { type: 'expanded', child: bigButton(t, state.paused ? 'RESUME' : 'PAUSE', state.paused ? 'play_arrow' : 'pause', 'pause', !state.paused) },
        { type: 'sizedBox', width: 10 },
        { type: 'expanded', child: bigButton(t, 'SKIP', 'skip_next', 'skip', false) },
        { type: 'sizedBox', width: 10 },
        { type: 'expanded', child: bigButton(t, 'QUIT', 'close', 'quit', false) }
      ] } }
    ] } };
  }

  function progressBar(t, done, total) {
    var cells = 24;
    var filled = Math.round((done / total) * cells);
    var children = [];
    for (var i = 0; i < cells; i++) {
      children.push({ type: 'expanded', child: { type: 'animatedContainer', duration: 250, curve: 'easeInOut',
        height: 6, margin: [0, 0, 2, 0],
        decoration: { color: i < filled ? t.accent2 : t.border, borderRadius: 3 } } });
    }
    return { type: 'row', children: children };
  }

  function doneScreen(t) {
    return { type: 'safeArea', child: { type: 'column', crossAxisAlignment: 'stretch', children: [
      header(t, 'Workout complete', []),
      sceneBox(t, 250),
      { type: 'container', margin: [16, 10, 16, 0], padding: [18, 14, 18, 14], alignment: 'center',
        decoration: { color: t.surface, borderRadius: 16, border: { color: t.borderBright } },
        child: { type: 'column', mainAxisSize: 'min', crossAxisAlignment: 'center', children: [
          { type: 'svg', data: SVG.trophy, width: 36, color: t.accent2 },
          { type: 'sizedBox', height: 8 },
          { type: 'text', data: 'Great job!', style: { color: t.text, fontSize: 17, fontWeight: 'w700' } },
          { type: 'sizedBox', height: 4 },
          { type: 'text', data: 'session ' + state.stats.sessions + ' · ' + fmt(state.stats.seconds) + ' of training',
            style: { color: t.muted, fontSize: 12 } }
        ] } },
      { type: 'padding', padding: [16, 14, 16, 0], child: bigButton(t, 'GO AGAIN', 'play_arrow', 'start', true) },
      { type: 'padding', padding: [16, 8, 16, 0], child: bigButton(t, 'HOME', 'close', 'quit', false) }
    ] } };
  }

  function render() {
    exportNow();
    var t = jsr.theme;
    if (state.screen === 'workout') return jsr.render(workoutScreen(t));
    if (state.screen === 'done') return jsr.render(doneScreen(t));
    return jsr.render(homeScreen(t));
  }

  jsr.onEvent(function(name) {
    if (name === 'start') return startWorkout();
    if (name === 'pause') return togglePause();
    if (name === 'skip') return advance();
    if (name === 'quit') return quit();
  });

  // ── scene + boot ───────────────────────────────────────────────────────

  // GLB scenes MUST declare the flame engine at create time: the 3d
  // dispatcher binds the scene to a host on the FIRST create (no src in
  // the config → flutter_cube), and a later .glb addModel into a
  // cube-bound scene dies trying to parse it as OBJ.
  jsr.scene3d.create(sceneId, {
    engine: 'flame',
    camera: { position: [0, 1.3, 3.2], target: [0, 0.85, 0], fov: 45 },
    light: { position: [3, 6, 4], color: '#ffffff', ambient: 0.6, diffuse: 0.8 }
  });
  jsr.scene3d.addModel(sceneId, {
    modelId: 'coach', src: MODEL_SRC,
    position: [0, 0, 0], scale: [1, 1, 1]
  });
  sceneReady = true;
  jsr.scene3d.playAnimation(sceneId, 'coach', { name: 'Idle', loop: true });

  jsr.storage.get('fitness_stats').then(function(saved) {
    if (saved && typeof saved === 'object') {
      state.stats = {
        sessions: saved.sessions || 0,
        seconds: saved.seconds || 0,
        lastDay: saved.lastDay || null
      };
    }
    render();
  });
  render();
})();
