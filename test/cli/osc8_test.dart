import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/osc8.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart'
    show tuiTextWidth;
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

/// OSC 8 hyperlinks (issue #808): mode resolution, emission, fallback,
/// stripping, zero-width behavior in the width walker and the wrap pass.
void main() {
  tearDown(() {
    osc8LinksMode = Osc8LinksMode.auto;
    osc8ProfileUsable = false;
  });

  group('resolveOsc8Links', () {
    test('mode mapping: off/auto/always; unknown and null fall back to auto', () {
      resolveOsc8Links('off', ColorProfile.trueColor);
      expect(osc8LinksMode, Osc8LinksMode.off);
      resolveOsc8Links('always', ColorProfile.trueColor);
      expect(osc8LinksMode, Osc8LinksMode.always);
      resolveOsc8Links('auto', ColorProfile.trueColor);
      expect(osc8LinksMode, Osc8LinksMode.auto);
      resolveOsc8Links('sometimes', ColorProfile.trueColor);
      expect(osc8LinksMode, Osc8LinksMode.auto);
      resolveOsc8Links(null, ColorProfile.trueColor);
      expect(osc8LinksMode, Osc8LinksMode.auto);
    });

    test('auto capability: truecolor/256 only; legacy and none are not usable',
        () {
      resolveOsc8Links(null, ColorProfile.trueColor);
      expect(osc8ProfileUsable, isTrue);
      resolveOsc8Links(null, ColorProfile.ansi256);
      expect(osc8ProfileUsable, isTrue);
      resolveOsc8Links(null, ColorProfile.ansi);
      expect(osc8ProfileUsable, isFalse);
      resolveOsc8Links(null, null);
      expect(osc8ProfileUsable, isFalse);
    });

    test('osc8Active truth table', () {
      osc8LinksMode = Osc8LinksMode.off;
      osc8ProfileUsable = true;
      expect(osc8Active, isFalse);
      osc8LinksMode = Osc8LinksMode.always;
      osc8ProfileUsable = false;
      expect(osc8Active, isTrue);
      osc8LinksMode = Osc8LinksMode.auto;
      osc8ProfileUsable = true;
      expect(osc8Active, isTrue);
      osc8ProfileUsable = false;
      expect(osc8Active, isFalse);
    });
  });

  group('osc8Wrap', () {
    test('off degrades to the plain text', () {
      osc8LinksMode = Osc8LinksMode.off;
      osc8ProfileUsable = true;
      expect(osc8Wrap('text', 'http://x'), 'text');
    });

    test('active emits BEL-terminated pairs around the visible text', () {
      osc8LinksMode = Osc8LinksMode.always;
      expect(
        osc8Wrap('text', 'http://x'),
        '\x1b]8;;http://x\x07text\x1b]8;;\x07',
      );
    });

    test('the url cannot break out of the sequence (ESC/BEL sanitized)', () {
      osc8LinksMode = Osc8LinksMode.always;
      final out = osc8Wrap('t', 'http://x\x1b]8;;evil\x07y');
      expect(out, '\x1b]8;;http://x]8;;evily\x07t\x1b]8;;\x07');
    });
  });

  group('stripOsc8', () {
    test('removes BEL- and ST-terminated spans, keeps visible text', () {
      expect(
        stripOsc8('a\x1b]8;;http://x\x07t\x1b]8;;\x07b'),
        'atb',
      );
      expect(
        stripOsc8('a\x1b]8;;http://x\x1b\\t\x1b]8;;\x1b\\b'),
        'atb',
      );
      expect(stripOsc8('no links here'), 'no links here');
    });
  });

  group('width walker (zero-width escapes)', () {
    test('a linked label measures exactly like its bare text', () {
      osc8LinksMode = Osc8LinksMode.always;
      expect(tuiTextWidth(osc8Wrap('ab', 'http://x')), 2);
      expect(tuiTextWidth(osc8Wrap('a中文c', 'http://x')), 6);
      // Long URLs cost nothing.
      expect(tuiTextWidth(osc8Wrap('ab', 'h' * 200)), 2);
      osc8LinksMode = Osc8LinksMode.off;
      expect(tuiTextWidth('ab'), 2);
    });
  });

  group('wrap balancing', () {
    test('a row cut inside a link closes and re-opens it', () {
      osc8LinksMode = Osc8LinksMode.always;
      final label = 'word ' * 12; // 60 cells
      final linked = osc8Wrap(label.trimRight(), 'http://example.com/x');
      final rows = wrapAnsiLine(linked, 20);
      expect(rows.length, greaterThan(1));
      for (final row in rows) {
        expect(tuiTextWidth(row), lessThanOrEqualTo(20));
      }
      // Every continuation row re-opens the link; every cut row closes it.
      for (var i = 0; i < rows.length; i++) {
        final opens = '\x1b]8;;'.allMatches(rows[i]).length;
        final closes = '\x1b]8;;\x07'.allMatches(rows[i]).length;
        if (i < rows.length - 1) {
          expect(closes, greaterThanOrEqualTo(1), reason: 'row $i');
        }
        if (i > 0) {
          expect(opens, greaterThanOrEqualTo(1), reason: 'row $i');
        }
      }
      // Stripped rows reproduce the bare wrapped text.
      final bare = wrapAnsiLine(label.trimRight(), 20);
      expect(
        [for (final r in rows) stripOsc8(r)],
        bare,
      );
    });

    test('links stay balanced even when the wrap is unneeded', () {
      osc8LinksMode = Osc8LinksMode.always;
      final linked = osc8Wrap('short', 'http://x');
      final rows = wrapAnsiLine('see $linked here', 40);
      expect(rows.single, contains('\x1b]8;;http://x\x07short\x1b]8;;\x07'));
    });
  });
}
