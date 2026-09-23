import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/code_highlight.dart';
import 'package:flutter_agent_harness/src/cli/osc8.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:dart_tui/src/bubbles/style.dart' show RgbColor, Style;
import 'package:test/test.dart';

/// Markdown-parity surface (issue #808): md* role mapping, fenced-code
/// highlighting through the S1 syntax seam, streaming fence state, and
/// the raw/plain mode contracts.
void main() {
  tearDown(() {
    FaThemeController.instance.profile = null;
    FaThemeController.instance.reset();
    osc8LinksMode = Osc8LinksMode.auto;
    osc8ProfileUsable = false;
  });

  group('md* palette mapping', () {
    test('headings ride the accent role (not accent2)', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      final out = AnsiMarkdown(width: 80).formatAll(const ['# Title']);
      expect(out.join(), contains(tuiAccentSoftSgr()));
      expect(out.join(), isNot(contains(tuiAccent2SoftSgr())));
    });

    test('inline code uses the mdCode hex (#E5C1FF), not the accent', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      final out =
          AnsiMarkdown(width: 80).formatAll(const ['run `make all` now'])
              .join();
      final mdCode = tuiSgr(
        Style(foregroundRgb: const RgbColor(0xE5, 0xC1, 0xFF)),
      );
      expect(out, contains(mdCode));
      expect(out, contains('make all'));
    });

    test('light themes trade mdCode for the readable Light+ purple', () {
      final controller = FaThemeController.instance;
      controller
        ..reset()
        ..profile = ColorProfile.trueColor;
      controller.switchTo('ohmypi-light');
      final out =
          AnsiMarkdown(width: 80).formatAll(const ['run `make all` now'])
              .join();
      expect(
        out,
        contains(tuiSgr(
          Style(foregroundRgb: const RgbColor(0x6F, 0x42, 0xC1)),
        )),
      );
    });

    test('markdown links: colored label + dim url suffix, shape kept', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      final out =
          AnsiMarkdown(width: 80).formatAll(const ['see [docs](http://d.x)'])
              .join();
      expect(out, contains('docs'));
      expect(out, contains('(http://d.x)'));
    });
  });

  group('fenced code', () {
    test('known language: fence markers dim, content highlighted', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      final out = AnsiMarkdown(width: 80)
          .formatAll(const ['```dart', 'final x = 1;', '```', 'after'])
          .join('\n');
      // Tokens are individually styled — compare escape-free text.
      final plain = out.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
      expect(out, contains(codeTokenSgr(CodeTokenKind.keyword)));
      expect(plain, contains('final x = 1;'));
      expect(plain, contains('after'));
    });

    test('unknown language: legacy verbatim shape (no syntax SGR)', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      final out = AnsiMarkdown(width: 80)
          .formatAll(const ['```perl', r'my $x = 1;', '```'])
          .join();
      expect(out, contains(r'my $x = 1;'));
      expect(out, isNot(contains(codeTokenSgr(CodeTokenKind.variable))));
    });

    test('NO_COLOR profile: fence content degrades to the plain line', () {
      FaThemeController.instance.profile = null;
      final out = AnsiMarkdown(width: 80)
          .formatAll(const ['```dart', 'final x = 1;', '```'])
          .join();
      expect(out, contains('final x = 1;'));
      expect(out.contains('\x1b[38;2;'), isFalse);
    });

    test('streaming across a fence re-lexes exactly (commit boundary inside)',
        () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      const lines = [
        'before',
        '```python',
        'def f(x):',
        '    s = """open',
        'still open"""',
        '    return x  # done',
        '```',
        'after',
      ];
      // Incremental: one line per flush (worst-case commit boundaries).
      // sync() resumes only when handed the SAME growing list (the
      // boundary sentinel is identity-based, like the TUI's transcript
      // buffer) — a fresh per-line list takes the rebuild path.
      final src = <String>[];
      final tx = TranscriptMarkdown(width: 80);
      var outs = const <String>[];
      for (final line in lines) {
        src.add(line);
        outs = tx.sync(src);
      }
      final reference = TranscriptMarkdown(width: 80).sync([...lines]);
      expect(outs, reference);
      // And the whole document highlights like a one-shot format.
      expect(reference, AnsiMarkdown(width: 80).formatAll(lines));
    });
  });

  group('OSC 8 links in markdown', () {
    test('mode auto/off: colored label + dim suffix, no escape pairs', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      osc8LinksMode = Osc8LinksMode.off;
      final out =
          AnsiMarkdown(width: 80).formatAll(const ['[docs](http://d.x)'])
              .join();
      expect(out.contains('\x1b]8;;'), isFalse);
    });

    test('mode always: label rides the hyperlink pair', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      osc8LinksMode = Osc8LinksMode.always;
      osc8ProfileUsable = true;
      final out = AnsiMarkdown(width: 80)
          .formatAll(const ['see [docs](http://d.x) end'])
          .join();
      expect(out, contains('\x1b]8;;http://d.x\x07'));
      expect(out, contains('docs'));
    });

    test('bare URLs autolink without re-matching the rendered suffix', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      osc8LinksMode = Osc8LinksMode.always;
      osc8ProfileUsable = true;
      final out = AnsiMarkdown(width: 80)
          .formatAll(const ['go to https://a.b/c now'])
          .join();
      expect(out, contains('\x1b]8;;https://a.b/c\x07'));
      // Exactly one pair for the one URL.
      expect('\x1b]8;;https://a.b/c\x07'.allMatches(out).length, 1);
    });
  });

  group('surface mode contracts (line-mode/headless byte parity)', () {
    const doc = '# H\n\n**bold** and [l](http://x) plus `c`.\n';

    test('raw passthrough is byte-identical input, links or not', () {
      osc8LinksMode = Osc8LinksMode.always;
      osc8ProfileUsable = true;
      FaThemeController.instance.profile = ColorProfile.trueColor;
      expect(
        const MarkdownSurface(mode: MarkdownSurfaceMode.raw).render(doc),
        doc,
      );
    });

    test('plain strips every escape byte even with links active', () {
      osc8LinksMode = Osc8LinksMode.always;
      osc8ProfileUsable = true;
      FaThemeController.instance.profile = ColorProfile.trueColor;
      const fenced = '```dart\nfinal x = 1;\n```\n[l](http://x)\n';
      final out =
          const MarkdownSurface(mode: MarkdownSurfaceMode.plain).render(fenced);
      expect(out.contains('\x1b'), isFalse);
      expect(out, contains('final x = 1;'));
      expect(out, contains('l'));
    });
  });
}
