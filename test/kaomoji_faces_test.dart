// The shared kaomoji thinking-indicator data (issue #1374): the eight
// owner-approved faces, the two-tone brand palette, the ~0.9 s random
// swap cadence and the seedable face picker — ONE pure-Dart source the
// CLI TUI (ANSI runs), the app (SVG frames) and the web TUI (text spans)
// all render from.
//
// All randomness routes through the seeded [Random] seam — no test
// depends on a process-random sequence.
library;

import 'dart:math';

import 'package:flutter_agent_harness/src/kaomoji_faces.dart';

import 'package:test/test.dart';

void main() {
  test('AC spec: the eight approved faces, in the issue order', () {
    expect(
      [for (final face in kKaomojiFaces) face.text],
      ['>_o', '-_-', 'o_o', '>_<', 'o_<', '◕‿◕', '¬_¬', 'o_o?'],
    );
    expect(
      [for (final face in kKaomojiFaces) face.id],
      ['f->o', 'f---', 'f-oo', 'f-><', 'f-o<', 'f-sm', 'f-nt', 'f-hm'],
    );
    // Every glyph is one BMP code unit, and the widest face (`o_o?`) fits
    // the CLI's 4-cell face zone.
    for (final face in kKaomojiFaces) {
      expect(face.text.length, lessThanOrEqualTo(4), reason: face.text);
    }
  });

  test('ASCII-safe fallbacks for the non-ASCII faces', () {
    // ◕‿◕ → ^.^ ; ¬_¬ → -_/ (mouth = the tilted stroke) ; o_o? → o_o.
    expect(
      kKaomojiFaces[5].runsFor(true).map((r) => r.$1).join(),
      '^.^',
    );
    expect(
      kKaomojiFaces[6].runsFor(true).map((r) => r.$1).join(),
      '-_/',
    );
    expect(
      kKaomojiFaces[7].runsFor(true).map((r) => r.$1).join(),
      'o_o',
    );
    // The primary set is already ASCII-safe for the plain faces: same
    // run content either way.
    expect(kKaomojiFaces[0].runsFor(true), kKaomojiFaces[0].runs);
    // The mouth tone segmentation matches the sprite's `.b` class: the
    // `¬_¬` fallback's tilted stroke is the mouth, the flat ones are not.
    expect(
      kKaomojiFaces[6].runsFor(true).where((r) => r.$2).map((r) => r.$1),
      ['/'],
    );
    expect(
      kKaomojiFaces[6].runsFor(false).where((r) => r.$2).map((r) => r.$1),
      ['_'],
    );
  });

  test('two-tone brand palette (from the launcher icon)', () {
    expect(kKaomojiEyeHex, '60d0d0', reason: 'eyes/face strokes teal');
    expect(kKaomojiMouthHex, '70a0e0', reason: 'mouth blue');
    expect(kKaomojiEyeArgb, 0xFF60D0D0);
    expect(kKaomojiMouthArgb, 0xFF70A0E0);
  });

  test('AC spec: ~0.9 s random swap cadence (9 × 100 ms CLI ticks)', () {
    expect(kKaomojiSwapPeriod, const Duration(milliseconds: 900));
    expect(kKaomojiSwapTicks, 9);
  });

  test('AC spec: every SVG frame is the approved 24-grid sprite content',
      () {
    for (final face in kKaomojiFaces) {
      final svg = kaomojiFaceSvg(face);
      expect(svg, contains('viewBox="0 0 24 24"'), reason: svg);
      // 1.45× content scale + 1.4 stroke: the approved group attrs.
      expect(
        svg,
        contains('transform="translate(12 12) scale(1.45) '
            'translate(-12 -12)"'),
        reason: svg,
      );
      expect(svg, contains('stroke-width="1.4"'), reason: svg);
      expect(svg, contains('stroke="#60d0d0"'), reason: svg);
      expect(svg, contains('stroke="#70a0e0"'), reason: svg);
      // The sprite's `.t`/`.b` classes are resolved to inline strokes —
      // flutter_svg renders no `<style>` blocks.
      expect(svg, isNot(contains('class=')), reason: svg);
      expect(svg, contains('stroke-linecap="round"'), reason: svg);
    }
    // The two-tone split lands on the sprite's shape kinds: the `>_o`
    // frame strokes both eyes teal and the mouth blue.
    final gtO = kaomojiFaceSvg(kKaomojiFaces[0]);
    expect(
      gtO,
      contains('<path stroke="#60d0d0" d="M5 9.5l2.6 1.7L5 12.9"/>'),
    );
    expect(
      gtO,
      contains('<circle stroke="#60d0d0" cx="16.8" cy="11" r="1.8"/>'),
    );
    expect(gtO, contains('<path stroke="#70a0e0" d="M9.5 14.8h3"/>'));
  });

  test('seeded picker: deterministic sequence, replayable', () {
    List<String> sequence() {
      final picker = KaomojiFacePicker(Random(42));
      return [
        for (var i = 0; i < 50; i++)
          (i == 0 ? picker.first() : picker.next()).text,
      ];
    }

    expect(sequence(), sequence(), reason: 'same seed → same faces');
  });

  test('picker picks stay in range and never repeat the showing face', () {
    final picker = KaomojiFacePicker(Random(7));
    var current = picker.first();
    for (var i = 0; i < 500; i++) {
      final next = picker.next();
      expect(
        kKaomojiFaces.indexOf(next),
        inInclusiveRange(0, kKaomojiFaces.length - 1),
      );
      expect(next, isNot(current), reason: 'swap $i');
      current = next;
    }
  });

  test('a seeded 200-swap run visits every face', () {
    final picker = KaomojiFacePicker(Random(7));
    final seen = <KaomojiFace>{picker.first()};
    for (var i = 0; i < 200; i++) {
      seen.add(picker.next());
    }
    expect(seen.length, kKaomojiFaces.length, reason: 'seen $seen');
  });

  test('debugPin: pinned draws freeze the face — deterministic goldens',
      () {
    addTearDown(() => KaomojiFacePicker.debugPin = null);
    KaomojiFacePicker.debugPin = 3;
    final picker = KaomojiFacePicker();
    expect(picker.first(), same(kKaomojiFaces[3]));
    for (var i = 0; i < 5; i++) {
      expect(picker.next(), same(kKaomojiFaces[3]),
          reason: 'the pin freezes the face across swap boundaries');
    }
    // Out-of-range pins clamp into the face set.
    KaomojiFacePicker.debugPin = 99;
    expect(KaomojiFacePicker().first(), same(kKaomojiFaces[7]));
  });

  test('kaomojiNextFaceIndex: the skip-over seam the CLI pick injects into',
      () {
    // raw 0 with current 0 skips to 1; raw >= current shifts +1; raw <
    // current passes through.
    expect(kaomojiNextFaceIndex((max) {
      expect(max, kKaomojiFaces.length - 1);
      return 0;
    }, 0), 1);
    expect(kaomojiNextFaceIndex((max) => 5, 3), 6);
    expect(kaomojiNextFaceIndex((max) => 5, 6), 5);
    // For EVERY current, every legal raw lands off current, in range.
    for (var current = 0; current < kKaomojiFaces.length; current++) {
      for (var raw = 0; raw < kKaomojiFaces.length - 1; raw++) {
        final next = kaomojiNextFaceIndex((max) {
          expect(max, kKaomojiFaces.length - 1);
          return raw;
        }, current);
        expect(next, inInclusiveRange(0, kKaomojiFaces.length - 1));
        expect(next, isNot(current), reason: 'current $current raw $raw');
      }
    }
  });
}
