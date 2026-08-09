// v2 00 — Hook (0–60): a prompt pill types "Fa — build a game" on the dark
// stage, block caret riding the end, one glow pulse, then the pill LAUNCHES
// into the canvas (scale push + rise) and the game beat takes over. The pill
// is the video's input metaphor: separate prompt inputs on one canvas.

scene = {
  id: 'hook',
  duration: 60,
  description: 'Typewriter prompt pill on dark stage: types, glows, launches into the canvas.',
  timeline: { label: yoclipT('hook').timeline, color: '#818CF8', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('hook');
    var text = t.pill || 'Fa — build a game';
    var primary = yoclipColor('primary', '#818CF8');
    var accent = yoclipColor('accent', '#2DD4BF');
    var fg = yoclipColor('text', '#F4F6FB');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;

    var TYPE_START = 10;
    var CHARS_PER_FRAME = 1.0;
    var typeEnd = TYPE_START + Math.ceil(text.length / CHARS_PER_FRAME); // ~45
    var GLOW_AT = typeEnd + 2;
    var LAUNCH = GLOW_AT + 10;

    var n = Math.floor((frame - TYPE_START) * CHARS_PER_FRAME);
    n = clamp(n, 0, text.length);
    var typed = text.substring(0, n);
    var busy = frame >= TYPE_START && n < text.length;
    var caretOn = busy ? 1 : ((frame % 14) < 9 ? 1 : 0);

    // Pill geometry (portrait-first, centered slightly above middle).
    var fs = W * 0.052;

    // Glow pulse once the typing completes: teal ring flashes then settles.
    var glow = shimmer(clamp(frame - GLOW_AT, 0, 8), 8);
    var ringOp = frame < GLOW_AT ? 0 : (1 - seg(frame, GLOW_AT, GLOW_AT + 10)) * 0.9;

    // Launch zooms the pill TOWARD the viewer: yoclip container `scale` only
    // inflates the layout box (children render unscaled and the box grows
    // from the top-left anchor), so the zoom is done by scaling the driver —
    // font size, which proportionally scales width/height/radius/caret.
    var launch = ease(frame, LAUNCH, LAUNCH + 10, eoBack);
    var rise = -H * 0.06 * launch;
    var op = frame < 6 ? fadeIn(frame, 6) : 1 - seg(frame, LAUNCH + 8, LAUNCH + 12);

    var pill = promptPill(text, typed, caretOn === 1, {
      fs: fs * (1 + 0.55 * launch),
      color: fg,
      border: accent,
      bg: yoclipColor('surface', '#0E1420'),
      fontFamily: yoclipFont(),
      shadow: { color: accent, blur: 26 + 44 * glow, offsetY: 0 },
      offsetY: -H * 0.02 + rise,
      opacity: cap01(op),
    });

    return {
      type: 'stack', fit: 'expand',
      children: [
        // Dead-center launch target hint: a faint ring the pill dives into.
        {
          type: 'container',
          width: fs * 9, height: fs * 9, borderRadius: fs * 4.5,
          borderColor: accent, borderWidth: 2,
          alignment: 'center',
          offsetY: H * 0.06,
          opacity: cap01(0.25 * seg(frame, GLOW_AT, GLOW_AT + 6) * (1 - launch)),
        },
        // The soft glow ring flare right after typing.
        {
          type: 'container',
          width: fs * (6 + 6 * (1 - ringOp)), height: fs * (6 + 6 * (1 - ringOp)),
          borderRadius: fs * 99,
          borderColor: accent, borderWidth: 3,
          alignment: 'center', offsetY: -H * 0.02,
          opacity: cap01(ringOp),
        },
        pill,
      ],
    };
  },
};
