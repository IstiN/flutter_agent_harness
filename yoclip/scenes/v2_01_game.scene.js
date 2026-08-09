// v2 01 — Game (54–210): the phone frame ASSEMBLES around a LIVE 3D scene —
// Kenney GLB cars (flame_3d, offscreen-captured in headless export) driving
// on a synthwave grid road (software mesh layer under the flame layer, the
// same camera fed to both so they composite aligned — the sample-proven
// pattern from big_idea_v2 scene 08). Code chips stagger from the side,
// caption rises. Ends with the next prompt pill typing in the corner
// ("Fa — build my fitness trainer") that launches into the white wipe of
// the fitness beat.

scene = {
  id: 'game',
  duration: 156,
  description: 'Phone frame with a live flame_3d car scene on a software-grid road assembles on the dark stage; code chips stagger; next prompt pill types.',
  timeline: { label: yoclipT('game').timeline, color: '#2DD4BF', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('game');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var primary = yoclipColor('primary', '#818CF8');
    var accent = yoclipColor('accent', '#2DD4BF');
    var fg = yoclipColor('text', '#F4F6FB');
    var muted = yoclipColor('textMuted', '#8A93A8');

    // ---- phone assembly -------------------------------------------------------
    var pw = W * 0.52;
    var ph = pw * (2796 / 1290);
    var bezel = pw * 0.035;
    var radius = pw * 0.09;

    var phoneOp = ease(frame, 4, 16, eoBack);
    var screenOp = seg(frame, 12, 22);
    var settle = 1.12 - 0.12 * ease(frame, 4, 34, eio3); // zoom-in settle
    var floatY = float(frame, H * 0.008, 0.02, 1);

    // ---- shared 3D camera (software grid + flame cars use the SAME camera
    // map so both renderers composite in alignment — sample pattern) --------
    // The camera gently follows the hero's weave so the car never leaves the
    // narrow portrait frame.
    var weave = Math.sin(frame * 0.04);
    var camSway = Math.sin(frame * 0.03) * 0.15;
    var camPush = ease(frame, 0, 50, eio3) * 1.6;
    var cam = {
      position: [0.9 + weave * 0.35 + camSway, 2.3, 4.8 - camPush],
      target: [weave * 0.4, 0.3, -1.6],
      fov: 55,
    };

    // ---- software mesh layer: ground + scrolling synthwave grid -------------
    function quad(x1, z1, x2, z2, y, color) {
      return {
        vertices: [[x1, y, z1], [x2, y, z1], [x2, y, z2], [x1, y, z2]],
        faces: [[0, 2, 1], [0, 3, 2]],
        color: color,
      };
    }
    var meshes = [
      // Ground slab — deep night blue.
      quad(-30, -70, 30, 12, -0.03, '#0A0E18'),
      // Side rails.
      quad(-2.75, -70, -2.55, 12, 0, '#3D3D6E'),
      quad(2.55, -70, 2.75, 12, 0, '#3D3D6E'),
    ];
    // Dashes + cross lines scrolling toward the camera = speed.
    var SPAN = 55;
    var scroll = (frame * 0.55) % 5;
    for (var i = 0; i < 12; i++) {
      var z = -SPAN + i * 5 + scroll;
      if (z > 10) continue;
      // Center lane dash.
      meshes.push(quad(-0.09, z, 0.09, z + 2.2, 0, '#2DD4BF'));
      // Full-width cross line — the synthwave grid.
      meshes.push(quad(-2.55, z, 2.55, z + 0.12, -0.01, '#26315A'));
    }

    var gridLayer = {
      type: 'scene3d',
      width: pw, height: ph,
      meshes: meshes,
      camera: cam,
      light: { direction: [0, -1, 0] },
      opacity: cap01(screenOp),
    };

    // ---- flame layer: GLB cars ------------------------------------------------
    var cars = {
      type: 'scene3d',
      engine: 'flame',
      id: 'v2-game-cars',
      width: pw, height: ph,
      time: frame / 30,
      camera: cam,
      light: { ambient: 0.6, diffuse: 1.25, position: [4, 8, 4] },
      opacity: cap01(screenOp),
      models: [
        { // Hero — weaving race car, subtle suspension bob.
          modelId: 'hero',
          src: 'models/race.glb',
          position: [weave * 0.35, Math.abs(Math.sin(frame * 0.35)) * 0.015, 0],
          rotation: [0, 180 + weave * 4, 0],
          scale: [0.8, 0.8, 0.8],
        },
        { // Traffic left — hatchback pulling away.
          modelId: 'traffic-l',
          src: 'models/hatchback-sports.glb',
          position: [-1.1, Math.abs(Math.sin(frame * 0.31 + 2)) * 0.012, -4.5 - frame * 0.045],
          rotation: [0, 180, 0],
          scale: [0.7, 0.7, 0.7],
        },
        { // Traffic right — sedan slightly behind the left one.
          modelId: 'traffic-r',
          src: 'models/sedan.glb',
          position: [1.1, Math.abs(Math.sin(frame * 0.29 + 4)) * 0.012, -7.5 - frame * 0.035],
          rotation: [0, 180, 0],
          scale: [0.7, 0.7, 0.7],
        },
      ],
    };

    var phone = {
      type: 'container',
      width: pw + bezel * 2, height: ph + bezel * 2,
      borderRadius: radius,
      color: yoclipColor('bezel', '#0A0E18'),
      borderColor: yoclipColor('panel', '#26304A'),
      borderWidth: 2,
      shadow: { color: yoclipColorA('primary', 0x55), blur: 90, offsetY: 34 },
      clip: true,
      alignment: 'center',
      offsetX: -W * 0.12,
      offsetY: floatY,
      scale: phoneOp * settle,
      opacity: cap01(phoneOp),
      child: {
        type: 'stack',
        fit: 'expand',
        children: [gridLayer, cars],
      },
    };

    // ---- code chips stagger in from the right ---------------------------------
    var chipDefs = [
      { text: 'scene3d.create()', d: 0 },
      { text: "addModel('sedan.glb')", d: 1 },
      { text: 'flame_3d engine', d: 2 },
    ];
    var chips = [];
    for (var i = 0; i < chipDefs.length; i++) {
      var start = 22 + chipDefs[i].d * 9;
      var op = seg(frame, start, start + 8);
      if (op <= 0) continue;
      var chipFs = W * 0.028;
      chips.push({
        type: 'container',
        width: chipDefs[i].text.length * chipFs * 0.62 + chipFs * 1.8,
        height: chipFs * 2.1,
        borderRadius: chipFs,
        color: yoclipColor('surface', '#0E1420'),
        borderColor: accent, borderWidth: 1,
        alignment: 'topLeft',
        offsetX: W * 0.60 + (1 - ease(frame, start, start + 12, eo3)) * W * 0.10,
        offsetY: H * (0.30 + chipDefs[i].d * 0.11),
        opacity: cap01(op),
        child: { type: 'row', alignment: 'center', mainAxisSize: 'min', children: [
          { type: 'text', text: chipDefs[i].text, style: { color: accent, fontSize: chipFs, fontWeight: 600, fontFamily: yoclipFont() } },
        ] },
      });
    }

    // ---- caption ---------------------------------------------------------------
    var capOp = seg(frame, 40, 52);
    var caption = {
      type: 'text',
      text: t.caption || 'apps built by chat',
      style: { color: fg, fontSize: W * 0.042, fontWeight: 700, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.38,
      opacity: cap01(capOp),
    };

    // ---- next prompt pill (corner typewriter → launch) -------------------------
    // Steady 1 char/frame cadence — the sample-style typing rhythm.
    var pillText = t.pill || 'Fa — build my fitness trainer';
    var TYPE_AT = 96;
    var LAUNCH_AT = 140;
    var n = clamp(Math.floor((frame - TYPE_AT) * 1.0), 0, pillText.length);
    var typed = frame < TYPE_AT ? '' : pillText.substring(0, n);
    var launch = ease(frame, LAUNCH_AT, LAUNCH_AT + 12, eo3);
    var fs = W * 0.036;
    var pill = typed.length === 0 ? null : {
      type: 'container',
      padding: [fs * 1.1, fs * 0.55, fs * 1.1, fs * 0.55],
      borderRadius: fs * 1.6,
      color: yoclipColor('surface', '#0E1420'),
      borderColor: accent, borderWidth: 2,
      alignment: 'bottomRight',
      offsetX: -W * 0.06 - launch * W * 0.4,
      offsetY: -H * 0.05 - launch * H * 0.5,
      scale: 1 + 0.4 * launch,
      opacity: cap01(seg(frame, TYPE_AT, TYPE_AT + 4) * (1 - seg(frame, LAUNCH_AT + 10, LAUNCH_AT + 14))),
      child: { type: 'text', text: typed, style: { color: fg, fontSize: fs, fontWeight: 600, fontFamily: yoclipFont() } },
    };

    var children = [phone, caption].concat(chips);
    if (pill != null) children.push(pill);
    return { type: 'stack', fit: 'expand', children: children };
  },
};
