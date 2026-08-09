// v2 04 — Homework (444–570): white flash back to the dark stage; the chat
// capture slides up; a python3 tool chip pops and pulses once ("real tools
// at work"); caption; next pill types.

scene = {
  id: 'homework',
  duration: 126,
  description: 'Dark stage: chat capture with the solved homework slides up, python3 chip pulses, caption, next prompt pill.',
  timeline: { label: yoclipT('homework').timeline, color: '#2DD4BF', lane: 'video' },
  render: function(frame) {
    var t = yoclipT('homework');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var accent = yoclipColor('accent', '#2DD4BF');
    var primary = yoclipColor('primary', '#818CF8');
    var fg = yoclipColor('text', '#F4F6FB');
    var muted = yoclipColor('textMuted', '#8A93A8');

    // ---- theme wipe (dark bound) --------------------------------------------------
    var FLASH = 6;
    var flashOp = frame < FLASH ? seg(frame, 0, FLASH) : 1 - seg(frame, FLASH, FLASH * 2);

    // ---- chat card (dark capture, tall crop) ---------------------------------------
    var cw = W * 0.80;
    var ch = cw * (540 / 820);
    var rise = ease(frame, FLASH + 2, FLASH + 22, eio3);
    var floatY = float(frame, H * 0.008, 0.02, 4);

    var card = {
      type: 'container',
      width: cw, height: ch,
      borderRadius: W * 0.04,
      color: yoclipColor('bezel', '#0A0E18'),
      borderColor: yoclipColor('panel', '#26304A'), borderWidth: 2,
      shadow: { color: yoclipColorA('primary', 0x55), blur: 70, offsetY: 30 },
      clip: true,
      alignment: 'center',
      offsetY: H * 0.02 + (1 - rise) * H * 0.35 + floatY,
      opacity: cap01(seg(frame, FLASH + 2, FLASH + 10)),
      child: {
        type: 'image',
        source: 'external:promo_chat',
        fit: 'cover', width: cw, height: ch,
        alignment: 'topCenter',
      },
    };

    // ---- python3 tool chip pops + one glow pulse ------------------------------------
    var CHIP_AT = FLASH + 18;
    var chipPop = ease(frame, CHIP_AT, CHIP_AT + 12, eoBack);
    var pulse = shimmer(clamp(frame - (CHIP_AT + 12), 0, 10), 10);
    var chipText = t.chip || 'python3';
    var chipFs = W * 0.032;
    var chip = {
      type: 'container',
      width: chipText.length * chipFs * 0.66 + chipFs * 2.6, height: chipFs * 2.3,
      borderRadius: chipFs * 0.8,
      color: yoclipColor('surface', '#0E1420'),
      borderColor: accent, borderWidth: 2,
      shadow: { color: accent, blur: 20 + 40 * pulse, offsetY: 8 },
      alignment: 'topLeft',
      offsetX: W * 0.08,
      offsetY: H * 0.325 + floatY,
      scale: chipPop,
      opacity: cap01(chipPop),
      child: {
        type: 'row', mainAxisSize: 'min', alignment: 'center', children: [
          { type: 'container', width: chipFs * 0.5, height: chipFs * 0.5, borderRadius: chipFs * 0.25, color: accent, margin: [0, 0, chipFs * 0.4, 0] },
          { type: 'text', text: chipText, style: { color: accent, fontSize: chipFs, fontWeight: 700, fontFamily: yoclipFont() } },
        ],
      },
    };

    // ---- caption ---------------------------------------------------------------------
    var caption = {
      type: 'text',
      text: t.caption || 'homework? solved, shown',
      style: { color: muted, fontSize: W * 0.040, fontWeight: 600, fontFamily: yoclipFont() },
      alignment: 'center',
      offsetY: H * 0.38,
      opacity: cap01(seg(frame, CHIP_AT + 14, CHIP_AT + 26)),
    };

    // ---- next prompt pill ---------------------------------------------------------------
    var pillText = t.pill || 'Fa — watch my stocks';
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

    var children = [card, chip, caption];
    if (pill != null) children.push(pill);
    children.push({
      type: 'container', color: '#FFFFFF',
      opacity: frame < FLASH * 2 ? cap01(flashOp) : 0,
    });
    return { type: 'stack', fit: 'expand', children: children };
  },
};
