// v2 07 — End card (774–900): flash to OFF-WHITE; the tiles exit
// directional; the Fa mark POPS (eoBack overshoot), the wordmark rises, the
// tagline settles, meta line at 70%; hold to 30.0 exactly.

scene = {
  id: 'end',
  duration: 126,
  description: 'Off-white end card: tiles fly out, Fa mark pops with overshoot, wordmark + tagline + meta, hold.',
  timeline: { label: yoclipT('end').timeline, color: '#818CF8', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('end');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var paper = '#F5F4F1';
    var ink = '#0B0F16';
    var primary = yoclipColor('primary', '#818CF8');
    var accent = yoclipColor('accent', '#2DD4BF');

    // ---- off-white world (flash in fast, like the theme wipes) ----------------------
    var FLASH = 6;
    var flashOp = frame < FLASH ? seg(frame, 0, FLASH) : 1 - seg(frame, FLASH, FLASH * 2);

    // ---- tiles exit (last frames of the constellation, flying out up-left/up-right) --
    var exitT = ease(frame, 2, 16, ei3);
    var tileSrcs = ['promo_game', 'promo_fitness', 'promo_teacher', 'promo_chat', 'promo_stocks', 'promo_providers'];
    var tiles = [];
    for (var i = 0; i < tileSrcs.length && exitT < 1; i++) {
      var tw = W * 0.16;
      var dir = i % 2 === 0 ? -1 : 1;
      tiles.push({
        type: 'container',
        width: tw, height: tw * 1.6,
        borderRadius: W * 0.02,
        clip: true,
        alignment: 'center',
        offsetX: dir * exitT * W * 0.9,
        offsetY: -exitT * H * 0.35 + H * (0.18 + (i % 3) * 0.2),
        rotateZ: dir * exitT * 14,
        opacity: cap01(1 - exitT * 1.2),
        child: {
          type: 'image',
          source: 'external:' + tileSrcs[i],
          fit: 'cover', width: tw, height: tw * 1.6,
          alignment: 'topCenter',
        },
      });
    }

    // ---- Fa mark pop (eoBack overshoot) -------------------------------------------------
    var POP_AT = 14;
    var pop = ease(frame, POP_AT, POP_AT + 16, eoBack);
    var markSize = W * 0.30;
    var mark = {
      type: 'container',
      width: markSize, height: markSize,
      alignment: 'center',
      offsetY: -H * 0.10,
      scale: pop,
      opacity: cap01(seg(frame, POP_AT, POP_AT + 4)),
      child: {
        type: 'image',
        source: 'external:fa_icon',
        fit: 'contain', width: markSize, height: markSize,
        alignment: 'center',
      },
    };

    // ---- wordmark + tagline --------------------------------------------------------------
    var titleOp = seg(frame, POP_AT + 12, POP_AT + 24);
    var title = {
      type: 'text',
      text: t.title || 'Describe it. Fa builds it.',
      style: { color: ink, fontSize: W * 0.062, fontWeight: 800, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.085 + riseIn(clamp(frame - (POP_AT + 12), 0, 12), 12, H * 0.02),
      opacity: cap01(titleOp),
    };

    var metaOp = seg(frame, POP_AT + 24, POP_AT + 36);
    var meta = {
      type: 'text',
      text: t.meta || 'one agent harness · every device',
      style: { color: '#5A6472', fontSize: W * 0.030, fontWeight: 600, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.145,
      opacity: cap01(metaOp) * 0.7,
    };

    // ---- gradient underline accent under the wordmark -------------------------------------
    var lineOp = seg(frame, POP_AT + 18, POP_AT + 30);
    var line = {
      type: 'container',
      width: W * 0.30 * ease(frame, POP_AT + 18, POP_AT + 32, eo3),
      height: W * 0.010, borderRadius: W * 0.005,
      gradient: {
        type: 'linear', begin: 'centerLeft', end: 'centerRight',
        colors: [primary, accent],
      },
      alignment: 'center',
      offsetY: H * 0.115,
      opacity: cap01(lineOp),
    };

    // stack: paper world at the bottom, content, white flash overlay on top.
    var children = [{ type: 'container', color: paper }];
    children = children.concat(tiles, [mark, title, line, meta]);
    children.push({
      type: 'container', color: '#FFFFFF',
      opacity: cap01(flashOp),
    });
    return { type: 'stack', fit: 'expand', children: children };
  },
};
