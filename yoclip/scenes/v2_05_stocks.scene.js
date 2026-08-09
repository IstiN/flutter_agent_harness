// v2 05 — Stocks (564–690): pan down onto the ticker card; rows are already
// inside the capture, so the motion lives in a sparkline that DRAWS itself
// over the beat and a "live" pulse dot; caption; next pill types (the trust
// one, launching into the zoom-out).

scene = {
  id: 'stocks',
  duration: 126,
  description: 'Dark stage: stocks ticker card with a self-drawing sparkline overlay and live pulse, caption, next prompt pill.',
  timeline: { label: yoclipT('stocks').timeline, color: '#2DD4BF', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('stocks');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var accent = yoclipColor('accent', '#2DD4BF');
    var fg = yoclipColor('text', '#F4F6FB');
    var muted = yoclipColor('textMuted', '#8A93A8');

    // ---- ticker card ------------------------------------------------------------------
    var cw = W * 0.86;
    var ch = cw * (480 / 1290);
    var pan = ease(frame, 2, 20, eio3);
    var floatY = float(frame, H * 0.008, 0.02, 5);

    var card = {
      type: 'container',
      width: cw, height: ch,
      borderRadius: W * 0.04,
      color: yoclipColor('bezel', '#0A0E18'),
      borderColor: yoclipColor('panel', '#26304A'), borderWidth: 2,
      shadow: { color: yoclipColorA('primary', 0x55), blur: 70, offsetY: 30 },
      clip: true,
      alignment: 'center',
      offsetY: -H * 0.03 + (1 - pan) * H * 0.22 + floatY,
      opacity: cap01(seg(frame, 2, 10)),
      child: {
        type: 'image',
        source: 'external:promo_stocks',
        fit: 'cover', width: cw, height: ch,
        alignment: 'topCenter',
      },
    };

    // ---- live pulse dot (ticker is alive) ----------------------------------------------
    var pulseOp = 0.5 + 0.5 * Math.sin(frame * 0.35);
    var pulse = {
      type: 'container',
      width: W * 0.022, height: W * 0.022, borderRadius: W * 0.011,
      color: accent,
      alignment: 'topRight',
      offsetX: -W * 0.085,
      offsetY: H * 0.30 + floatY,
      opacity: 0.45 + 0.55 * pulseOp,
      scale: 0.9 + 0.35 * pulseOp,
    };

    // ---- sparkline draws itself (SVG path, progress 0→1) -------------------------------
    var sparkPath = 'M 0 26 L 14 22 L 28 24 L 42 16 L 56 19 L 70 11 L 84 13 L 98 6 L 112 2';
    var spark = {
      type: 'path',
      path: sparkPath,
      progress: ease(frame, 14, 44, eio3),
      color: accent, strokeWidth: 2.5, cap: 'round', join: 'round',
      width: W * 0.42, height: W * 0.10,
      alignment: 'center',
      offsetY: H * 0.145,
      opacity: cap01(seg(frame, 14, 20)),
    };

    // ---- caption -------------------------------------------------------------------------
    var caption = {
      type: 'text',
      text: t.caption || 'it keeps watch for you',
      style: { color: muted, fontSize: W * 0.040, fontWeight: 600, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.24,
      opacity: cap01(seg(frame, 40, 52)),
    };

    // ---- next prompt pill (trust → zoom-out) ----------------------------------------------
    var pillText = t.pill || 'Fa — keys stay mine';
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
      color: yoclipColor('surface', '#0E1420'),
      borderColor: accent, borderWidth: 2,
      alignment: 'bottomRight',
      offsetX: -W * 0.06 - launch * W * 0.4,
      offsetY: -H * 0.05 - launch * H * 0.5,
      opacity: cap01(seg(frame, TYPE_AT, TYPE_AT + 4) * (1 - seg(frame, LAUNCH_AT + 10, LAUNCH_AT + 14))),
      child: { type: 'text', text: typed, style: { color: fg, fontSize: fs, fontWeight: 600, fontFamily: yoclipFont() } },
    };

    var children = [card, pulse, spark, caption];
    if (pill != null) children.push(pill);
    return { type: 'stack', fit: 'expand', children: children };
  },
};
