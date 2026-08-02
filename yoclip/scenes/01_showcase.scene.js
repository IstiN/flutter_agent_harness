// Showcase — the hero shot. A floating phone holds five real product screens
// (the App Store goldens) while kinetic headline pairs land each beat.
// The phone persists across beats; only the screen content crossfades.

var PHASE_STARTS = [0, 84, 180, 276, 372];
var PHASE_IMGS = ['apps', 'chat', 'inapp', 'media', 'providers'];
var SCENE_END = 456;

scene = {
  id: 'showcase',
  duration: SCENE_END,
  from: 0,
  description: 'Phone turns in on the live-widget dashboard, then the screen ' +
    'morphs through chat-built apps, in-app chat, media and providers while ' +
    'two-line kinetic headlines land per beat.',
  voicePrompts: {
    en: 'A dashboard that is truly yours. Your own apps, built by chat. ' +
      'Fa lives inside every app you create. It draws, speaks and plays. ' +
      'Any provider — your keys never leave the Keychain.',
    ru: 'Дашборд, который по-настоящему ваш. Свои приложения — созданные в ' +
      'чате. Fa живёт внутри каждого приложения. Он рисует, говорит и играет. ' +
      'Любой провайдер — ключи остаются в Keychain.',
  },
  timeline: {
    label: yoclipT('showcase').timeline || 'Showcase',
    color: yoclipColor('primary', '#818CF8'),
    lane: 'video',
  },
  render: function(frame) {
    var T = yoclipT('showcase');
    var phases = T.phases || [];
    var lang = yoclipLang();
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var portrait = yoclipIsPortrait();
    var font = yoclipFont();

    // ---- phone geometry -----------------------------------------------------
    // Portrait splits by aspect: app preview (taller than 2:1) has no platform
    // UI and gets a bigger phone; social 9:16 keeps the phone higher/smaller
    // so it clears the TikTok/Reels caption and right-rail zones.
    var tall = H / W > 2.0;
    var ph = portrait ? H * (tall ? 0.545 : 0.50) : H * 0.86;
    var pw = ph * (1154 / 2186);
    var bezel = Math.max(8, pw * 0.024);
    var radius = pw * 0.045 + bezel;

    // ---- phone motion -------------------------------------------------------
    var turn = eo3(seg(frame, 0, 55));
    var rotY = lerp(-24, -6, turn) + float(frame, 1.2, 0.02, 0);
    var rotX = lerp(8, 2, turn);
    var phoneScale = lerp(1.15, 1.0, eo3(seg(frame, 0, 60)));
    var floatY = float(frame, 7, 0.05, 0) * turn;
    var phoneOp = cap01(fadeIn(frame, 14));

    // ---- current / previous screen ------------------------------------------
    var idx = 0;
    for (var i = 0; i < PHASE_STARTS.length; i++) {
      if (frame >= PHASE_STARTS[i]) idx = i;
    }
    var pStart = PHASE_STARTS[idx];
    var pEnd = idx + 1 < PHASE_STARTS.length ? PHASE_STARTS[idx + 1] : SCENE_END;
    var local = frame - pStart;
    var pLen = pEnd - pStart;

    var curSrc = 'external:screen_' + PHASE_IMGS[idx] + '_' + lang;
    // Fade-through-dim (not a full crossfade): the outgoing screen is gone
    // before the incoming one rises, so the midpoint reads as a quick blink
    // on the bezel instead of two readable UIs ghosting over each other.
    var outOp = 1 - seg(local, 0, 8);
    var inOp = seg(local, 7, 15);
    var push = 1 + 0.045 * eo3(seg(local, 0, pLen));

    var screenChildren = [];
    if (idx > 0 && outOp > 0) {
      screenChildren.push({
        type: 'image',
        source: 'external:screen_' + PHASE_IMGS[idx - 1] + '_' + lang,
        fit: 'cover', width: pw, height: ph,
        opacity: cap01(outOp),
        alignment: 'center',
      });
    }
    screenChildren.push({
      type: 'image',
      source: curSrc,
      fit: 'cover', width: pw, height: ph,
      opacity: idx === 0 ? 1 : cap01(inOp),
      scale: push,
      alignment: 'center',
    });

    var phone = {
      type: 'container',
      width: pw + bezel * 2, height: ph + bezel * 2,
      borderRadius: radius,
      color: yoclipColor('bezel', '#0A0E18'),
      borderColor: yoclipColor('panel', '#26304A'),
      borderWidth: 2,
      shadow: { color: yoclipColorA('primary', 0x55), blur: 80, offsetY: 30 },
      clip: true,
      alignment: portrait ? 'topCenter' : 'centerRight',
      offsetX: portrait ? 0 : -(W * 0.10),
      offsetY: portrait ? H * (tall ? 0.345 : 0.36) + floatY : floatY + H * 0.01,
      opacity: phoneOp,
      rotateY: rotY, rotateX: rotX,
      scale: phoneScale,
      child: {
        type: 'stack', fit: 'expand',
        children: screenChildren,
      },
    };

    // ---- kinetic headlines ----------------------------------------------------
    var fs = portrait ? W * 0.064 : 76;
    var kickFs = portrait ? W * 0.023 : 26;
    var textKids = [];
    for (var p = 0; p < phases.length; p++) {
      var ps = PHASE_STARTS[p];
      var pe = p + 1 < PHASE_STARTS.length ? PHASE_STARTS[p + 1] : SCENE_END;
      var pl = pe - ps;
      var lf = frame - ps; // local phase frame
      if (lf < -14 || lf > pl) continue;
      var ph0 = phases[p];

      var inOp = eo3(seg(lf, 2, 16));
      var outOp = 1 - eo3(seg(lf, pl - 10, pl));
      var op = cap01(inOp * outOp);
      if (op <= 0) continue;

      var rise1 = riseIn(Math.max(0, lf - 2), 18, 26);
      var rise2 = riseIn(Math.max(0, lf - 7), 18, 26);

      var col = {
        type: 'column',
        crossAxisAlignment: portrait ? 'center' : 'start',
        // Column sizes to the full stack height (mainAxisSize.max), so the
        // portrait block must anchor its children to the start — 'center'
        // would drop the headline to mid-frame over the phone.
        mainAxisAlignment: portrait ? 'start' : 'center',
        alignment: portrait ? 'topCenter' : 'centerLeft',
        offsetX: portrait ? 0 : W * 0.075,
        offsetY: portrait ? H * (tall ? 0.085 : 0.115) : 0,
        opacity: op,
        children: [
          {
            type: 'text', text: ph0.kicker || '',
            style: {
              fontSize: kickFs, color: yoclipColor('primary', '#818CF8'),
              fontFamily: font, fontWeight: 600, letterSpacing: 3,
            },
          },
          { type: 'container', height: fs * 0.34 },
          {
            type: 'text', text: ph0.line1 || '',
            offsetY: rise1,
            style: {
              fontSize: fs, color: yoclipColor('text', '#F4F6FB'),
              fontFamily: font, fontWeight: 700,
            },
          },
          { type: 'container', height: fs * 0.10 },
          {
            type: 'text', text: ph0.line2 || '',
            offsetY: rise2,
            style: {
              fontSize: fs, color: '#FFFFFF', fontFamily: font, fontWeight: 700,
              gradient: {
                colors: [yoclipColor('primary', '#818CF8'), yoclipColor('accent', '#2DD4BF')],
                begin: 'centerLeft', end: 'centerRight',
              },
            },
          },
        ],
      };
      textKids.push(col);
    }

    var children = [phone].concat(textKids);
    return {
      type: 'stack', fit: 'expand',
      opacity: cap01(fadeOut(frame, SCENE_END, 12)),
      children: children,
    };
  },
};
