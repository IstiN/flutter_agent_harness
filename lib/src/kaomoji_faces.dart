// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The thinking indicator's shared kaomoji data (issue #1374): the eight
/// owner-approved two-tone faces, the brand palette and the random swap
/// cadence as ONE pure-Dart source — `dart:math` is the only import, so
/// the core stays pure Dart. Hosts render it: the CLI TUI styles the
/// text runs through the TUI theme, the app draws the approved SVG
/// sprite frames, and the web TUI paints the text runs as colored spans.
///
/// Design (owner-approved v3): asymmetric two-eye faces, the content
/// scaled to fill ~90% of the 24-grid (1.45×, stroke 1.4), a RANDOM
/// frame every ~0.9 s while the agent thinks — never a fixed rotation.
library;

import 'dart:math';

/// One styled run of a kaomoji face: the text and whether it is a mouth
/// (blue #70a0e0) — everything else is an eye/face stroke (teal
/// #60d0d0), per the approved SVG sprite's `.t`/`.b` classes.
typedef KaomojiRun = (String text, bool mouth);

/// One kaomoji face: the primary text runs plus the ASCII-safe fallback
/// runs (narrow terminals, fonts without ◕‿¬), and the approved sprite
/// frame ([svg], the face group's inner shape content with the sprite's
/// `.t`/`.b` classes intact — [kaomojiFaceSvg] resolves them to inline
/// strokes). Faces whose primary text is already ASCII carry the same
/// runs twice.
final class KaomojiFace {
  const KaomojiFace(this.id, this.runs, this.fallbackRuns, this.svg);

  /// The approved sprite's group id (`f->o` … `f-hm`).
  final String id;

  final List<KaomojiRun> runs;

  final List<KaomojiRun> fallbackRuns;

  /// The face's shape content, verbatim from the approved sprite.
  final String svg;

  List<KaomojiRun> runsFor(bool ascii) => ascii ? fallbackRuns : runs;

  /// The face's plain primary text (`>_o`) — its exact cell count; every
  /// glyph is one BMP code unit.
  String get text => [for (final (text, _) in runs) text].join();
}

/// Eyes/face strokes: the brand teal (launcher icon).
const String kKaomojiEyeHex = '60d0d0';

/// Mouths: the brand blue (launcher icon).
const String kKaomojiMouthHex = '70a0e0';

/// [kKaomojiEyeHex] as an ARGB int — Flutter hosts build `Color`s from
/// it without importing anything beyond this file.
const int kKaomojiEyeArgb = 0xFF60D0D0;

/// [kKaomojiMouthHex] as an ARGB int.
const int kKaomojiMouthArgb = 0xFF70A0E0;

/// The face swap cadence for timer-based hosts: the issue's ~0.9 s.
const Duration kKaomojiSwapPeriod = Duration(milliseconds: 900);

/// The same cadence in the CLI's spinner ticks (9 × 100 ms chain).
const int kKaomojiSwapTicks = 9;

/// The eight approved faces, in the issue's order. Segmentation mirrors
/// the sprite: `¬_¬`'s ASCII fallback `-_/` flattens both eyes to
/// strokes and the tilted stroke becomes the mouth; `o_o?`'s fallback
/// drops the curious `?`.
const List<KaomojiFace> kKaomojiFaces = [
  KaomojiFace(
    'f->o',
    [('>', false), ('_', true), ('o', false)],
    [('>', false), ('_', true), ('o', false)],
    '<path class="t" d="M5 9.5l2.6 1.7L5 12.9"/>'
        '<circle class="t" cx="16.8" cy="11" r="1.8"/>'
        '<path class="b" d="M9.5 14.8h3"/>',
  ),
  KaomojiFace(
    'f---',
    [('-', false), ('_', true), ('-', false)],
    [('-', false), ('_', true), ('-', false)],
    '<path class="t" d="M5 11h3.6"/><path class="t" d="M14 11h3.6"/>'
        '<path class="b" d="M9.5 15h5"/>',
  ),
  KaomojiFace(
    'f-oo',
    [('o', false), ('_', true), ('o', false)],
    [('o', false), ('_', true), ('o', false)],
    '<circle class="t" cx="6.8" cy="10.6" r="2.1"/>'
        '<circle class="t" cx="16.8" cy="11.2" r="1.3"/>'
        '<path class="b" d="M10.4 15h3.2"/>',
  ),
  KaomojiFace(
    'f-><',
    [('>', false), ('_', true), ('<', false)],
    [('>', false), ('_', true), ('<', false)],
    '<path class="t" d="M5 9.6l2.6 1.7L5 13"/>'
        '<path class="t" d="M18.6 9.6L16 11.3l2.6 1.7"/>'
        '<path class="b" d="M10 15.2h4.2"/>',
  ),
  KaomojiFace(
    'f-o<',
    [('o', false), ('_', true), ('<', false)],
    [('o', false), ('_', true), ('<', false)],
    '<circle class="t" cx="6.8" cy="10.8" r="2"/>'
        '<path class="t" d="M14.2 9.8l2.8 1.5-2.8 1.5"/>'
        '<path class="b" d="M10 15.4c.9.9 2.4.9 3.3 0"/>',
  ),
  KaomojiFace(
    'f-sm',
    [('◕', false), ('‿', true), ('◕', false)],
    [('^', false), ('.', true), ('^', false)],
    '<circle class="t" cx="6.8" cy="10.4" r="1.7"/>'
        '<circle class="t" cx="16.8" cy="10.9" r="1.1"/>'
        '<path class="b" d="M8.4 14.4c1 1.3 2.3 2 3.6 2s2.6-.7 3.6-2"/>',
  ),
  KaomojiFace(
    'f-nt',
    [('¬', false), ('_', true), ('¬', false)],
    [('-', false), ('_', false), ('/', true)],
    '<path class="t" d="M5 9.4v1.7h2.3"/>'
        '<path class="t" d="M14.8 10.4h3.2"/>'
        '<path class="b" d="M9.6 15.8l4.8-.7"/>',
  ),
  KaomojiFace(
    'f-hm',
    [('o', false), ('_', true), ('o', false), ('?', true)],
    [('o', false), ('_', true), ('o', false)],
    '<circle class="t" cx="6.8" cy="10.6" r="2"/>'
        '<circle class="t" cx="16.8" cy="11.3" r="1.2"/>'
        '<path class="b" d="M10.2 15.9c.5-1.3 1.3-2 1.8-2.7"/>',
  ),
];

/// Uniform over every face EXCEPT [current]: a swap that lands back on
/// the same face reads as a frozen row, so the raw [pick] (which must be
/// uniform over `0…kKaomojiFaces.length - 2`) skips over [current]'s
/// index. The single seam both the CLI's injected picker and
/// [KaomojiFacePicker] share.
int kaomojiNextFaceIndex(int Function(int max) pick, int current) {
  final raw = pick(kKaomojiFaces.length - 1);
  return raw >= current ? raw + 1 : raw;
}

/// The random face picker: seed it with a [Random] for deterministic
/// tests; the default seeds from the process entropy. A swap NEVER
/// repeats the showing face ([kaomojiNextFaceIndex]).
final class KaomojiFacePicker {
  KaomojiFacePicker([Random? random]) : _random = random ?? Random();

  final Random _random;

  int _current = -1;

  /// The visual-fixture seam (the CLI's `FA_KAOMOJI_FACE` pin mirrors
  /// it): when non-null, every draw returns this face — clamped into the
  /// set, swaps frozen — so golden frames are deterministic. Production
  /// leaves it null (the random cadence).
  static int? debugPin;

  /// The face a fresh run opens on: uniform over all eight.
  KaomojiFace first() =>
      kKaomojiFaces[_current = _draw(kKaomojiFaces.length)];

  /// The face a swap boundary shows next: uniform over the other seven.
  KaomojiFace next() {
    if (_current < 0) return first();
    if (debugPin != null) return kKaomojiFaces[_current];
    _current = kaomojiNextFaceIndex(_random.nextInt, _current);
    return kKaomojiFaces[_current];
  }

  int _draw(int max) {
    final pin = debugPin;
    return pin == null ? _random.nextInt(max) : pin.clamp(0, max - 1);
  }
}

/// The approved sprite frame for [face]: the 24-grid root (round caps
/// and joins, no fills) wrapping the face group with its 1.45× content
/// scale and 1.4 stroke. The sprite's `.t`/`.b` classes resolve to
/// inline strokes in the brand palette — flutter_svg renders no
/// `<style>` blocks.
String kaomojiFaceSvg(KaomojiFace face) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
    'fill="none" stroke-linecap="round" stroke-linejoin="round">'
    '<g transform="translate(12 12) scale(1.45) translate(-12 -12)" '
    'stroke-width="1.4">${_stroked(face.svg)}</g></svg>';

/// Resolves the sprite's palette classes to inline stroke attributes.
String _stroked(String shapes) => shapes
    .replaceAll('class="t"', 'stroke="#$kKaomojiEyeHex"')
    .replaceAll('class="b"', 'stroke="#$kKaomojiMouthHex"');
