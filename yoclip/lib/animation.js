// Shared animation helpers for the Fa promo (adapted from yoclip_about).

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

function cap01(v) { return clamp(v, 0, 1); }

function lerp(a, b, t) {
  return a + (b - a) * clamp(t, 0, 1);
}

function seg(frame, start, end) {
  if (end <= start) return frame >= end ? 1 : 0;
  return clamp((frame - start) / (end - start), 0, 1);
}

function ei3(t) { return t * t * t; }
function eo3(t) { var u = 1 - t; return 1 - u * u * u; }
function eio3(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
function eoExpo(t) { return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t); }
function eoBack(t) {
  var c1 = 1.70158;
  var c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
}

function ease(frame, start, end, fn) {
  return fn(seg(frame, start, end));
}

function presence(frame, fadeIn, hold, fadeOut) {
  var fin = seg(frame, 0, fadeIn);
  var fout = seg(frame, fadeIn + hold, fadeIn + hold + fadeOut);
  return fin * (1 - fout);
}

function fadeIn(frame, dur) { return eo3(seg(frame, 0, dur)); }

function fadeOut(frame, end, dur) { return 1 - eo3(seg(frame, end - dur, end)); }

function riseIn(frame, dur, from) {
  return from * (1 - eo3(seg(frame, 0, dur)));
}

function pop(frame, start, dur) {
  var t = seg(frame - start, 0, dur);
  return { scale: eoBack(t), opacity: eo3(t) };
}

function float(frame, amp, speed, phase) {
  return Math.sin(frame * (speed || 0.05) + (phase || 0)) * amp;
}

function shimmer(frame, period) {
  var p = period || 60;
  var x = (frame % p) / p;
  return 1 - Math.abs(x * 2 - 1);
}

// ---- Variants / theme -------------------------------------------------------

function yoclipVariantParams() {
  return (typeof yoclipVariant !== 'undefined' && yoclipVariant) || {};
}

function yoclipLang() {
  return yoclipVariantParams().lang || 'en';
}

function yoclipT(section) {
  var all = (typeof yoclipTexts !== 'undefined' && yoclipTexts) || {};
  var dict = all[yoclipLang()] || all.en || {};
  return dict[section] || {};
}

function yoclipColor(key, fallback) {
  var t = (typeof yoclipTheme !== 'undefined' && yoclipTheme) || {};
  var c = t.colors || {};
  return c[key] || fallback;
}

function yoclipColorA(key, alpha, fallback) {
  var hex = yoclipColor(key, fallback || '#000000').replace('#', '');
  if (hex.length === 8) hex = hex.slice(2);
  var a = Math.max(0, Math.min(255, Math.round(alpha))).toString(16);
  if (a.length < 2) a = '0' + a;
  return '#' + a + hex;
}

function yoclipSize(key, fallback) {
  var t = (typeof yoclipTheme !== 'undefined' && yoclipTheme) || {};
  var s = t.sizes || {};
  return s[key] || fallback;
}

function yoclipFont() {
  var t = (typeof yoclipTheme !== 'undefined' && yoclipTheme) || {};
  var f = t.font || {};
  return f.family || 'Geneva';
}

function yoclipOrientation() {
  var f = (typeof yoclipFormat !== 'undefined' && yoclipFormat) || {};
  return f.orientation || 'landscape';
}

function yoclipIsPortrait() {
  return yoclipOrientation() === 'portrait';
}
