// v2 03 — English teacher (324–450): same light stage, a slide right swaps
// the fitness card for the english-teacher card; the flashcard inside FLIPS
// apple → яблоко mid-beat (scale-swap overlay mirroring the app's flip);
// caption; next pill types.

scene = {
  id: 'teacher',
  duration: 126,
  description: 'Light stage: english teacher card slides in, flashcard flips apple→яблоко, caption, next prompt pill.',
  timeline: { label: yoclipT('teacher').timeline, color: '#818CF8', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('teacher');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var paper = '#F4F6FB';
    var ink = '#0B0F16';
    var primary = yoclipColor('primary', '#818CF8');
    var accent = yoclipColor('accent', '#2DD4BF');

    // ---- slide: fitness card exits left, teacher card enters right --------------
    var cw = W * 0.86;
    var ch = cw * (500 / 1290);
    var slideIn = ease(frame, 2, 18, eio3);
    var floatY = float(frame, H * 0.006, 0.02, 3);

    var card = {
      type: 'container',
      width: cw, height: ch,
      borderRadius: W * 0.045,
      color: '#FFFFFF',
      shadow: { color: '#0B0F1626', blur: 60, offsetY: 26 },
      clip: true,
      alignment: 'center',
      offsetX: (1 - slideIn) * W * 0.55,
      offsetY: -H * 0.04 + floatY,
      opacity: cap01(seg(frame, 2, 8)),
      child: {
        type: 'image',
        source: 'external:promo_teacher',
        fit: 'cover', width: cw, height: ch,
        alignment: 'topCenter',
      },
    };

    // ---- flashcard flip overlay: apple → яблоко (the app's flip, mirrored) ------
    var FLIP_AT = 46;
    var flip = seg(frame, FLIP_AT, FLIP_AT + 8);
    var fs = W * 0.056;
    var frontOp = 1 - seg(frame, FLIP_AT, FLIP_AT + 5);
    var backOp = seg(frame, FLIP_AT + 3, FLIP_AT + 8);
    var flipScale = 0.9 + 0.1 * Math.abs(1 - 2 * flip);

    var flipCard = {
      type: 'container',
      width: cw * 0.72, height: H * 0.052,
      borderRadius: W * 0.04,
      color: '#FFFFFF',
      borderColor: '#D8DEE9', borderWidth: 2,
      shadow: { color: '#0B0F161A', blur: 36, offsetY: 16 },
      alignment: 'center',
      offsetY: -H * 0.06 + floatY,
      scale: flipScale * ease(frame, 30, 42, eoBack),
      child: {
        type: 'stack', fit: 'expand', children: [
          {
            type: 'container', alignment: 'center',
            child: { type: 'text', text: 'apple', style: { color: ink, fontSize: fs, fontWeight: 700, fontFamily: yoclipFont() } },
            opacity: cap01(frontOp),
          },
          {
            type: 'container', alignment: 'center',
            child: { type: 'text', text: 'яблоко', style: { color: primary, fontSize: fs, fontWeight: 700, fontFamily: yoclipFont() } },
            opacity: cap01(backOp),
          },
        ],
      },
    };

    // ---- progress dots fill one more ---------------------------------------------
    var total = 12;
    var learned = 4 + (frame >= FLIP_AT + 8 ? 1 : 0);
    var dotChildren = [];
    for (var i = 0; i < total; i++) {
      dotChildren.push({
        type: 'container',
        width: i === learned - 1 ? W * 0.034 : W * 0.016,
        height: W * 0.016, borderRadius: W * 0.008,
        color: i < learned ? primary : '#D8DEE9',
        margin: [0, 0, W * 0.008, 0],
      });
    }
    var dots = {
      type: 'row', mainAxisSize: 'min', alignment: 'center',
      offsetY: H * 0.10,
      opacity: cap01(seg(frame, 34, 44)),
      children: dotChildren,
    };

    // ---- caption ------------------------------------------------------------------
    var caption = {
      type: 'text',
      text: t.caption || 'a tutor that adapts',
      style: { color: '#5A6472', fontSize: W * 0.040, fontWeight: 600, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.20,
      opacity: cap01(seg(frame, 40, 52)),
    };

    // ---- next prompt pill -----------------------------------------------------------
    var pillText = t.pill || 'Fa — help with my homework';
    var TYPE_AT = 74;
    var LAUNCH_AT = 112;
    var n = clamp(Math.floor((frame - TYPE_AT) * 1.0), 0, pillText.length);
    var typed = frame < TYPE_AT ? '' : pillText.substring(0, n);
    var launch = ease(frame, LAUNCH_AT, LAUNCH_AT + 12, eo3);
    var pfs = W * 0.036 * (1 + 0.4 * launch); // fs-driven launch zoom
    var pill = typed.length === 0 ? null : {
      type: 'container',
      padding: [pfs * 1.1, pfs * 0.55, pfs * 1.1, pfs * 0.55],
      borderRadius: pfs * 1.6,
      color: '#FFFFFF',
      borderColor: accent, borderWidth: 2,
      alignment: 'bottomRight',
      offsetX: -W * 0.06 - launch * W * 0.4,
      offsetY: -H * 0.05 - launch * H * 0.5,
      opacity: cap01(seg(frame, TYPE_AT, TYPE_AT + 4) * (1 - seg(frame, LAUNCH_AT + 10, LAUNCH_AT + 14))),
      child: { type: 'text', text: typed, style: { color: ink, fontSize: pfs, fontWeight: 600, fontFamily: yoclipFont() } },
    };

    var children = [
      { type: 'container', color: paper },
      card, flipCard, dots, caption,
    ];
    if (pill != null) children.push(pill);
    return { type: 'stack', fit: 'expand', children: children };
  },
};
