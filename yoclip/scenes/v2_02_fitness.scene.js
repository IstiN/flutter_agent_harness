// v2 02 — Fitness (204–330): a white-flash wipe takes the canvas to the
// LIGHT stage; the prompt lands as the fitness-trainer card pops in; a live
// reps chip ticks beside it ("the counter runs"); caption; the next pill
// types in the corner and launches.

scene = {
  id: 'fitness',
  duration: 126,
  description: 'White-flash wipe to the light stage: fitness trainer card pops, reps chip ticks, next prompt pill types.',
  timeline: { label: yoclipT('fitness').timeline, color: '#818CF8', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('fitness');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var paper = '#F4F6FB';
    var ink = '#0B0F16';
    var accent = yoclipColor('accent', '#2DD4BF');
    var primary = yoclipColor('primary', '#818CF8');

    // ---- theme wipe: scale-glow white flash (the ONLY hard cut) ----------------
    var FLASH = 6;
    var flashOut = seg(frame, 0, FLASH);          // in
    var flashIn = 1 - seg(frame, FLASH, FLASH * 2); // out
    var flashOp = frame < FLASH ? flashOut : cap01(flashIn);

    // ---- card ------------------------------------------------------------------
    var cw = W * 0.86;
    var ch = cw * (560 / 1290); // fitness_crop.png (1290x560)
    var pop = ease(frame, FLASH + 4, FLASH + 18, eoBack);
    var floatY = float(frame, H * 0.006, 0.02, 2);

    var card = {
      type: 'container',
      width: cw, height: ch,
      borderRadius: W * 0.045,
      color: '#FFFFFF',
      shadow: { color: '#0B0F1626', blur: 60, offsetY: 26 },
      clip: true,
      alignment: 'center',
      offsetY: -H * 0.04 + floatY,
      scale: pop,
      opacity: cap01(pop),
      child: {
        type: 'image',
        source: 'external:promo_fitness',
        fit: 'cover', width: cw, height: ch,
        alignment: 'topCenter',
      },
    };

    // ---- live reps chip (the counter runs over the beat) ------------------------
    var reps = 8 + Math.floor(clamp(frame - (FLASH + 20), 0, 40) / 10);
    var chipPop = ease(frame, FLASH + 20, FLASH + 30, eoBack);
    var chipFs = W * 0.034;
    var chip = {
      type: 'container',
      width: chipFs * 7.4, height: chipFs * 2.2,
      borderRadius: chipFs * 1.1,
      color: ink,
      alignment: 'topRight',
      offsetX: -W * 0.10,
      offsetY: H * 0.325 + floatY,
      scale: chipPop,
      opacity: cap01(chipPop),
      child: {
        type: 'row', mainAxisSize: 'min', alignment: 'center', children: [
          { type: 'container', width: chipFs * 0.47, height: chipFs * 0.47, borderRadius: chipFs * 0.24, color: accent, margin: [0, 0, chipFs * 0.35, 0] },
          { type: 'text', text: reps + ' / 15', style: { color: '#FFFFFF', fontSize: chipFs, fontWeight: 700, fontFamily: yoclipFont() } },
        ],
      },
    };

    // ---- caption ---------------------------------------------------------------
    var capOp = seg(frame, FLASH + 26, FLASH + 38);
    var caption = {
      type: 'text',
      text: t.caption || 'your coach, in a tap',
      style: { color: '#5A6472', fontSize: W * 0.040, fontWeight: 600, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.20,
      opacity: cap01(capOp),
    };

    // ---- next prompt pill --------------------------------------------------------
    var pillText = t.pill || 'Fa — teach me English';
    var TYPE_AT = 74;
    var LAUNCH_AT = 112;
    var n = clamp(Math.floor((frame - TYPE_AT) * 1.0), 0, pillText.length);
    var typed = frame < TYPE_AT ? '' : pillText.substring(0, n);
    var launch = ease(frame, LAUNCH_AT, LAUNCH_AT + 12, eo3);
    var fs = W * 0.036 * (1 + 0.4 * launch); // fs-driven launch zoom (container scale is box-only)
    var pill = typed.length === 0 ? null : {
      type: 'container',
      padding: [fs * 1.1, fs * 0.55, fs * 1.1, fs * 0.55],
      borderRadius: fs * 1.6,
      color: '#FFFFFF',
      borderColor: primary, borderWidth: 2,
      alignment: 'bottomRight',
      offsetX: -W * 0.06 - launch * W * 0.4,
      offsetY: -H * 0.05 - launch * H * 0.5,
      opacity: cap01(seg(frame, TYPE_AT, TYPE_AT + 4) * (1 - seg(frame, LAUNCH_AT + 10, LAUNCH_AT + 14))),
      child: { type: 'text', text: typed, style: { color: ink, fontSize: fs, fontWeight: 600, fontFamily: yoclipFont() } },
    };

    var children = [
      // light stage (opacity 1 from frame 0 — the dark layer never bleeds)
      { type: 'container', color: paper },
      card, chip, caption,
    ];
    if (pill != null) children.push(pill);
    // the wipe flash on top
    children.push({
      type: 'container',
      color: '#FFFFFF',
      opacity: frame < FLASH * 2 ? cap01(frame < FLASH ? flashOut : flashIn) : 0,
    });

    return { type: 'stack', fit: 'expand', children: children };
  },
};
