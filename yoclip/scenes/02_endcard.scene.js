// End card — the Fa mark pops on with a glow, wordmark and tagline rise in.

scene = {
  id: 'endcard',
  duration: 126,
  from: 444,
  description: 'Phone hands off to the Fa icon (eoBack pop + glow), ' +
    '"Fa — AI Agent" wordmark and tagline rise underneath; gentle end fade.',
  voicePrompts: {
    en: 'Fa — AI Agent.',
    ru: 'Fa — ваш AI-агент.',
  },
  timeline: {
    label: yoclipT('endcard').timeline || 'End card',
    color: yoclipColor('accent', '#2DD4BF'),
    lane: 'video',
  },
  render: function(frame) {
    var T = yoclipT('endcard');
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var portrait = yoclipIsPortrait();
    var font = yoclipFont();

    var life = cap01(presence(frame, 10, 96, 20));

    // Icon pop + breathe.
    var pp = pop(frame, 6, 30);
    var s = portrait ? W * 0.30 : 250;
    var iconScale = pp.scale * (1 + 0.012 * shimmer(Math.max(0, frame - 36), 70));
    var glow = 0x66 + Math.round(0x22 * shimmer(frame, 70));

    var titleOp = cap01(eo3(seg(frame, 18, 36)));
    var titleRise = riseIn(Math.max(0, frame - 18), 22, 30);
    var tagOp = cap01(eo3(seg(frame, 30, 48)));
    var tagRise = riseIn(Math.max(0, frame - 30), 22, 24);

    var titleFs = portrait ? W * 0.078 : 88;
    var tagFs = portrait ? W * 0.030 : 34;

    return {
      type: 'stack', fit: 'expand',
      opacity: life,
      children: [
        // Glow halo behind the icon.
        {
          type: 'container',
          width: s * 2.4, height: s * 2.4, borderRadius: s * 1.2,
          gradient: {
            type: 'radial', center: 'center', radius: 0.5,
            colors: [yoclipColorA('primary', glow), '#00000000'],
          },
          alignment: 'center',
          offsetY: portrait ? -H * 0.06 : -H * 0.04,
          opacity: cap01(pp.opacity),
        },
        {
          type: 'column',
          mainAxisAlignment: 'center',
          crossAxisAlignment: 'center',
          alignment: 'center',
          offsetY: portrait ? -H * 0.02 : 0,
          children: [
            {
              type: 'container',
              width: s, height: s,
              borderRadius: s * 0.235,
              clip: true,
              shadow: { color: yoclipColorA('primary', 0x88), blur: 70, offsetY: 22 },
              scale: iconScale,
              opacity: cap01(pp.opacity),
              alignment: 'center',
              child: {
                type: 'image', source: 'external:icon',
                fit: 'cover', width: s, height: s,
              },
            },
            { type: 'container', height: H * 0.035 },
            {
              type: 'text',
              text: T.title || 'Fa — AI Agent',
              offsetY: titleRise,
              opacity: titleOp,
              style: {
                fontSize: titleFs, color: yoclipColor('text', '#F4F6FB'),
                fontFamily: font, fontWeight: 700,
              },
            },
            { type: 'container', height: 18 },
            {
              type: 'text',
              text: T.tag || 'on your hardware, under your rules',
              offsetY: tagRise,
              opacity: tagOp,
              style: {
                fontSize: tagFs, color: yoclipColor('textMuted', '#8A93A8'),
                fontFamily: font, fontWeight: 400,
              },
            },
          ],
        },
      ],
    };
  },
};
