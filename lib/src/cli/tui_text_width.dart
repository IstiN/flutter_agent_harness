/// Grapheme-cluster cell widths for the TUI, matching the dart_tui
/// renderer's own measurement (`dart_tui/lib/src/grapheme_width.dart`).
///
/// The TUI pre-wraps and pads ANSI-styled rows to the terminal width; the
/// renderer then places those rows cell by cell using ITS width math. The
/// two must agree exactly: a row we believe fits but the renderer measures
/// wider overflows its row and desyncs the frame (visible as smeared or
/// duplicated output after emoji/CJK text). UTF-16 `String.length` is wrong
/// on both sides of that contract — an emoji like ✅ occupies 2 terminal
/// cells while counting as 1 code unit.
///
/// Keep the classification tables in sync with dart_tui's grapheme_width.
library;

import 'package:characters/characters.dart';

/// Terminal cells occupied by one grapheme cluster (0, 1, or 2).
int tuiGraphemeWidth(String grapheme) {
  if (grapheme.isEmpty) return 0;
  var hasNonZero = false;
  for (final rune in grapheme.runes) {
    if (_isZeroWidth(rune)) continue;
    hasNonZero = true;
    if (_isWide(rune)) return 2;
  }
  return hasNonZero ? 1 : 0;
}

/// Terminal-cell width of [text]: the sum of its grapheme clusters' widths.
///
/// Two acceleration layers over the table walk, both pure-function safe:
/// a printable-ASCII fast path (every unit in `[0x20, 0x7e]` is exactly one
/// cell — no grapheme iteration, no table lookups) and a bounded whole-line
/// memo, since incremental wrapping re-measures the same rows many times.
int tuiTextWidth(String text) {
  final cached = _widthCache[text];
  if (cached != null) return cached;
  var width = 0;
  var i = 0;
  final units = text.codeUnits;
  while (i < units.length) {
    final unit = units[i];
    if (unit < 0x20 || unit > 0x7e) break;
    i++;
    width++;
  }
  if (i < units.length) {
    // The prefix consumed only single-unit ASCII, so [i] is a char boundary.
    for (final grapheme in text.substring(i).characters) {
      width += tuiGraphemeWidth(grapheme);
    }
  }
  // Memo short lines only (rows are what gets re-measured); insertion-order
  // map evicts the oldest entry when full.
  if (text.length <= 512) {
    if (_widthCache.length >= _widthCacheCapacity) {
      _widthCache.remove(_widthCache.keys.first);
    }
    _widthCache[text] = width;
  }
  return width;
}

/// Bounded memo for [tuiTextWidth]. Widths are pure functions of their
/// string, so entries never go stale.
final _widthCache = <String, int>{};
const _widthCacheCapacity = 8192;

/// Pads [text] with spaces to [width] terminal cells (no-op when already
/// wider). Width-aware: `String.padRight` counts UTF-16 units, so a row
/// padded with it renders short whenever wide characters are present and
/// stale cells survive on the right.
String tuiPadRight(String text, int width) {
  final pad = width - tuiTextWidth(text);
  return pad <= 0 ? text : '$text${' ' * pad}';
}

/// Truncates [text] to at most [maxWidth] terminal cells, appending an
/// ellipsis when content was cut (never for an already-fitting text).
String tuiFitWidth(String text, int maxWidth) {
  if (tuiTextWidth(text) <= maxWidth) return text;
  if (maxWidth <= 0) return '';
  const ellipsis = '…';
  final budget = maxWidth - tuiTextWidth(ellipsis);
  var width = 0;
  final out = StringBuffer();
  for (final grapheme in text.characters) {
    final w = tuiGraphemeWidth(grapheme);
    if (width + w > budget) break;
    out.write(grapheme);
    width += w;
  }
  // Every fitted cluster keeps `width + w <= budget`, so result + ellipsis
  // never exceeds [maxWidth].
  return '${out.toString()}$ellipsis';
}

/// Wide-class data (emoji + regional indicators + East Asian Wide) and
/// zero-width data, as singleton sets plus inclusive ranges. Table-driven
/// on purpose: the equivalent boolean chains carry CRAP >= CC even at full
/// coverage, while these lookups keep every predicate at CC <= 4.
const _wideSingletons = <int>{
  0x00a9, 0x00ae, // © ®
  0x203c, 0x2049, 0x2122, 0x2139,
  0x2328, 0x23cf,
  0x2329, 0x232a, // East Asian brackets
};

const _wideRanges = <(int, int)>[
  (0x1100, 0x115f), // Hangul Jamo
  (0x2194, 0x2199), (0x21a9, 0x21aa), // arrows
  (0x231a, 0x231b),
  (0x23e9, 0x23f3), (0x23f8, 0x23fa),
  (0x25aa, 0x25ab), (0x25b6, 0x25c0), (0x25fb, 0x25fe),
  (0x2600, 0x27bf), // misc symbols + dingbats (✅ lives here)
  (0x2934, 0x2935),
  (0x2b05, 0x2b55),
  (0x2e80, 0x303e), (0x3040, 0xa4cf), // CJK (0x303f excluded, dart_tui)
  (0xac00, 0xd7a3), // Hangul syllables
  (0xf900, 0xfaff), // CJK compat ideographs
  (0xfe10, 0xfe19), (0xfe30, 0xfe6f),
  (0xff00, 0xff60), (0xffe0, 0xffe6), // fullwidth forms
  (0x3030, 0x303d), (0x3297, 0x3299),
  (0x1f000, 0x1faff), // emoji planes (✅ 🎉 …)
  (0x1f1e6, 0x1f1ff), // regional indicators (flags)
  (0x20000, 0x3fffd), // CJK extension B+
];

const _zeroWidthSingletons = <int>{0x200c, 0x200d};

const _zeroWidthSingles = <int>{0x05bf, 0x0670, 0x093a, 0x093c};

const _zeroWidthRanges = <(int, int)>[
  (0x0000, 0x001f), (0x007f, 0x009f), // controls
  (0x0300, 0x036f), (0x0483, 0x0489), // combining marks
  (0x0591, 0x05bd), (0x05c1, 0x05c2),
  (0x0610, 0x061a), (0x064b, 0x065f),
  (0x06d6, 0x06ed),
  (0x0900, 0x0902), (0x0941, 0x0948), (0x0951, 0x0957),
  (0x1ab0, 0x1aff), (0x1dc0, 0x1dff), (0x20d0, 0x20ff),
  (0xfe00, 0xfe0f), (0xfe20, 0xfe2f), // variation selectors
  (0xe0100, 0xe01ef), (0x1f3fb, 0x1f3ff), // skin tones
];

bool _inRanges(int rune, List<(int, int)> ranges) {
  for (final (lo, hi) in ranges) {
    if (rune >= lo && rune <= hi) return true;
  }
  return false;
}

bool _isWide(int rune) =>
    _wideSingletons.contains(rune) || _inRanges(rune, _wideRanges);

bool _isZeroWidth(int rune) =>
    _zeroWidthSingletons.contains(rune) ||
    _zeroWidthSingles.contains(rune) ||
    _inRanges(rune, _zeroWidthRanges);
