// v2 06 — Zoom-out (684–780): the lock glyph clicks shut over the providers
// card, then the BIG camera zoom-out — every station of the video shrinks
// into a tile constellation, platform pills fly in one-by-one, headline
// rises: "One agent. Every device."

scene = {
  id: 'zoomout',
  duration: 96,
  description: 'Lock clicks over the providers card; big zoom-out to the tile constellation; platform pills fly in; headline.',
  timeline: { label: yoclipT('zoomout').timeline, color: '#818CF8', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('zoomout');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var accent = yoclipColor('accent', '#2DD4BF');
    var primary = yoclipColor('primary', '#818CF8');
    var fg = yoclipColor('text', '#F4F6FB');
    var muted = yoclipColor('textMuted', '#8A93A8');

    // ---- phase 1 (0–30): providers card + lock click ----------------------------------
    var LOCK_AT = 20;
    var cardOp = seg(frame, 0, 8) * (1 - seg(frame, 34, 46));
    var pw = W * 0.62;
    var pch = pw * (900 / 1290);
    var provCard = cardOp <= 0 ? null : {
      type: 'container',
      width: pw, height: pch,
      borderRadius: W * 0.035,
      color: yoclipColor('bezel', '#0A0E18'),
      borderColor: yoclipColor('panel', '#26304A'), borderWidth: 2,
      shadow: { color: yoclipColorA('primary', 0x55), blur: 60, offsetY: 26 },
      clip: true,
      alignment: 'center',
      offsetY: -H * 0.02,
      opacity: cap01(cardOp),
      child: {
        type: 'image',
        source: 'external:promo_providers',
        fit: 'cover', width: pw, height: pch,
        alignment: 'topCenter',
      },
    };

    var lockPop = ease(frame, LOCK_AT, LOCK_AT + 10, eoBack);
    var lockOp = cardOp;
    var lockSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2.5"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/><circle cx="12" cy="16" r="1.4" fill="currentColor"/></svg>';
    var lock = lockOp <= 0 ? null : {
      type: 'container',
      width: W * 0.14, height: W * 0.14, borderRadius: W * 0.07,
      color: accent,
      shadow: { color: '#2DD4BF66', blur: 30, offsetY: 10 },
      alignment: 'center',
      offsetY: -H * 0.02,
      scale: lockPop * (1 + 0.12 * shimmer(clamp(frame - (LOCK_AT + 10), 0, 8), 8)),
      opacity: cap01(lockOp),
      child: { type: 'svg', data: lockSvg, width: W * 0.07, color: '#06211C' },
    };
    var lockText = lockOp <= 0 ? null : {
      type: 'text',
      text: t.lock || 'your keys stay in the Keychain',
      style: { color: muted, fontSize: W * 0.034, fontWeight: 600, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.10,
      opacity: cap01(lockOp * seg(frame, LOCK_AT + 6, LOCK_AT + 14)),
    };

    // ---- phase 2 (34–96): zoom-out constellation + platform pills + headline -----------
    var zoom = ease(frame, 34, 62, eio3);
    // A loose ring around the headline zone (y≈0.33): two tiles top, three
    // bottom — the center stays clear for the headline.
    var tileDefs = [
      { src: 'promo_game', x: 0.26, y: 0.085, w: 0.22 },
      { src: 'promo_fitness', x: 0.74, y: 0.085, w: 0.22 },
      { src: 'promo_chat', x: 0.20, y: 0.56, w: 0.22 },
      { src: 'promo_providers', x: 0.50, y: 0.62, w: 0.24 },
      { src: 'promo_stocks', x: 0.80, y: 0.56, w: 0.22 },
      { src: 'promo_teacher', x: 0.50, y: 0.030, w: 0.20 },
    ];
    var tiles = [];
    for (var i = 0; i < tileDefs.length; i++) {
      var d = tileDefs[i];
      var appear = ease(frame, 34 + i * 3, 44 + i * 3, eoBack);
      if (appear <= 0) continue;
      var tw = W * d.w;
      tiles.push({
        type: 'container',
        width: tw, height: tw * 1.6,
        borderRadius: W * 0.02,
        color: yoclipColor('bezel', '#0A0E18'),
        borderColor: yoclipColor('panel', '#26304A'), borderWidth: 1,
        clip: true,
        alignment: 'topLeft',
        offsetX: W * d.x - tw / 2 + float(frame, W * 0.004, 0.015, i),
        offsetY: H * d.y + float(frame, H * 0.005, 0.017, i + 2),
        scale: appear * (0.55 + 0.45 * zoom),
        opacity: cap01(appear),
        rotateZ: (i % 2 === 0 ? -1 : 1) * (1 - zoom) * 8,
        child: {
          type: 'image',
          source: 'external:' + d.src,
          fit: 'cover', width: tw, height: tw * 1.6,
          alignment: 'topCenter',
        },
      });
    }

    // Platform pills: two rows so long labels never collide.
    var pillRows = [
      { names: ['iOS', 'Android', 'Web', 'macOS'], y: 0.845, xs: [0.14, 0.36, 0.55, 0.75], at: 58 },
      { names: ['Windows', 'Linux', 'CLI'], y: 0.895, xs: [0.28, 0.50, 0.70], at: 66 },
    ];
    var pills = [];
    for (var r = 0; r < pillRows.length; r++) {
      var row = pillRows[r];
      for (var j = 0; j < row.names.length; j++) {
        var ps = row.at + j * 3;
        var pOp = ease(frame, ps, ps + 7, eoBack);
        if (pOp <= 0) continue;
        var label = row.names[j];
        var pfs = W * 0.026;
        pills.push({
          type: 'container',
          width: label.length * pfs * 0.66 + pfs * 1.6, height: pfs * 2.1,
          borderRadius: pfs * 1.05,
          color: yoclipColor('surface', '#0E1420'),
          borderColor: j % 2 === 0 ? accent : primary, borderWidth: 1,
          alignment: 'topLeft',
          offsetX: W * row.xs[j] - (label.length * pfs * 0.66 + pfs * 1.6) / 2,
          offsetY: H * row.y + (1 - pOp) * H * 0.04,
          opacity: cap01(pOp),
          child: { type: 'row', alignment: 'center', mainAxisSize: 'min', children: [
            { type: 'text', text: label, style: { color: fg, fontSize: pfs, fontWeight: 700, fontFamily: yoclipFont() } },
          ] },
        });
      }
    }

    var headOp = seg(frame, 66, 80);
    var headline = {
      type: 'column', mainAxisSize: 'min', crossAxisAlignment: 'center',
      alignment: 'center',
      offsetY: H * 0.27 + riseIn(clamp(frame - 66, 0, 14), 14, H * 0.03),
      opacity: cap01(headOp),
      children: [
        { type: 'text', text: t.headline1 || 'One agent.', style: { color: fg, fontSize: W * 0.075, fontWeight: 800, fontFamily: yoclipFont() } },
        { type: 'text', text: t.headline2 || 'Every device.', style: { color: accent, fontSize: W * 0.075, fontWeight: 800, fontFamily: yoclipFont() } },
      ],
    };

    var children = tiles.concat(pills);
    children.push(headline);
    if (provCard != null) children.push(provCard);
    if (lock != null) children.push(lock);
    if (lockText != null) children.push(lockText);
    return { type: 'stack', fit: 'expand', children: children };
  },
};
