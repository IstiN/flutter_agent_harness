import 'package:flutter_agent_harness/src/cli/tool_rows.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

void main() {
  // Identity painters: the raw layout is what most tests assert on; the
  // styled variants only wrap segments with SGR.
  String id(String s) => s;

  group('UT-grammar (AC1)', () {
    test('ask renders the question text, never the JSON envelope', () {
      final detail = toolRowDetail('ask', {
        'questions': [
          {
            'question':
                'Как именно оформить миграцию схемы — разом или по шагам?',
            'options': [
              {'label': 'Разом'},
              {'label': 'По шагам'},
            ],
          },
        ],
      });
      expect(detail, contains('Как именно оформить миграцию'));
      expect(detail, isNot(contains('questions')));
      expect(detail, isNot(contains('{')));

      final row = layoutToolRow(
        ToolRowSegments(glyph: '•', label: 'ask', detail: detail),
        100,
      ).join();
      expect(row, startsWith('• ask · '));
      expect(row, contains('Как именно оформить миграцию'));
      expect(row, isNot(contains('"')));
      expect(row, isNot(contains('questions=')));
    });

    test('bash renders the command; a leading cd collapses to the tail', () {
      expect(
        toolRowDetail('bash', {
          'command': 'cd /home/user/work/repo && \nflutter test --coverage',
        }),
        'flutter test --coverage',
      );
      expect(
        toolRowDetail('bash', {'command': 'docker compose up -d --build'}),
        'docker compose up -d --build',
      );
    });

    test('read renders path:lines, write renders the path', () {
      expect(
        toolRowDetail('read', {
          'path': 'lib/src/cli/fa_tui.dart',
          'offset': 50,
          'limit': 150,
        }),
        'lib/src/cli/fa_tui.dart:50-150',
      );
      expect(
        toolRowDetail('write', {
          'path': 'notes.txt',
          'content': 'a whole file body\nthat must not appear',
        }),
        'notes.txt',
      );
    });

    test('end rows carry the elapsed in the trailing zone', () {
      expect(
        layoutToolRow(
          const ToolRowSegments(
            glyph: '✓',
            label: 'bash',
            detail: 'make -j8',
            elapsed: '3s',
          ),
          100,
        ).join(),
        '✓ bash · make -j8 3s',
      );
    });

    test('unknown tools degrade to their first string argument', () {
      expect(
        toolRowDetail('mcp__fs__stat', {'path': '/tmp/x', 'depth': 2}),
        '/tmp/x',
      );
      // No string argument at all → empty detail, E2 shape.
      final row = layoutToolRow(
        ToolRowSegments(
          glyph: '✓',
          label: 'inspect',
          detail: toolRowDetail('inspect', {'depth': 2}),
          elapsed: '1s',
        ),
        80,
      ).join();
      expect(row, '✓ inspect 1s');
      expect(row.contains('·'), isFalse, reason: 'no dangling separator (E2)');
    });
  });

  group('UT-budget (AC2)', () {
    const longQuestion =
        'Как именно оформить миграцию схемы, если релиз катится в десять '
        'окружений и откат дороже переноса — перечисли шаги и риски?';
    const compound = 'cd /work/repo && flutter analyze && flutter test';

    for (final width in const [60, 100, 160]) {
      test('width $width: label and elapsed always fully visible', () {
        for (final detail in const [longQuestion, compound]) {
          final text = layoutToolRow(
            ToolRowSegments(
              glyph: '•',
              label: 'ask',
              detail: detail,
              elapsed: '12s',
            ),
            width,
          ).join();
          expect(
            tuiTextWidth(text),
            lessThanOrEqualTo(width),
            reason: 'row overflows its budget: "$text"',
          );
          expect(
            text.startsWith('• ask'),
            isTrue,
            reason: 'label truncated: "$text"',
          );
          expect(text.endsWith('12s'), isTrue, reason: '"$text"');
        }
      });
    }

    test('ellipsis only when the budget is genuinely exceeded', () {
      const segments = ToolRowSegments(
        glyph: '•',
        label: 'bash',
        detail: compound,
        elapsed: '2s',
      );
      // Fits: no ellipsis, no loss.
      expect(layoutToolRow(segments, 160).join(), contains(compound));
      // Too narrow: the detail is cut WITH the ellipsis, still inside the
      // width, and the trailing zone survives.
      final cut = layoutToolRow(segments, 20).join();
      expect(cut, contains('…'), reason: 'cut detail is ellipsized');
      expect(cut.endsWith('2s'), isTrue);
      expect(tuiTextWidth(cut), lessThanOrEqualTo(20));
    });

    test('CJK and emoji never split mid-rune (E1)', () {
      const segments = ToolRowSegments(
        glyph: '•',
        label: 'bash',
        detail: 'echo 🎌🚀 プレビュー確認 ✅ 保持宽度',
        elapsed: '4s',
      );
      for (final width in const [20, 24, 60]) {
        final text = layoutToolRow(segments, width).join();
        expect(
          tuiTextWidth(text),
          lessThanOrEqualTo(width),
          reason: 'wide glyphs overflowed width $width: "$text"',
        );
      }
    });
  });

  group('UT-theme (AC3)', () {
    test('raw layout is palette-independent; paint follows the theme', () {
      const segments = ToolRowSegments(
        glyph: '•',
        label: 'read',
        detail: 'lib/main.dart:1-50',
        elapsed: '0s',
      );
      final rawDefault = layoutToolRow(segments, 100).join();

      FaThemeController.instance.switchTo('default');
      final paintedDefault = layoutToolRow(
        segments,
        100,
      ).style(glyph: tuiAccent2Soft, label: tuiAccent2, dim: tuiDim);

      FaThemeController.instance.switchTo('ohmypi-dark');
      final rawOhmypi = layoutToolRow(segments, 100).join();
      final paintedOhmypi = layoutToolRow(
        segments,
        100,
      ).style(glyph: tuiAccent2Soft, label: tuiAccent2, dim: tuiDim);

      expect(
        rawDefault,
        rawOhmypi,
        reason: 'layout never bakes palette',
      );
      expect(
        paintedDefault,
        isNot(paintedOhmypi),
        reason: 'the two packs repaint differently',
      );
      // Segments carry the palette (not a hardcoded SGR): the styled row
      // wraps each segment, the raw one has no escapes at all.
      expect(paintedDefault.contains('\x1b['), isTrue);
      expect(rawDefault.contains('\x1b['), isFalse);
      FaThemeController.instance.reset();
    });

    test('the fitter-appended ellipsis rides its segment at emit time', () {
      final painted = layoutToolRow(
        const ToolRowSegments(
          glyph: '•',
          label: 'bash',
          detail: 'a very long command that must be cut somewhere',
        ),
        24,
      ).style(glyph: id, label: id, dim: (s) => '<$s>');
      expect(painted, contains('…>'));
    });
  });

  group('briefPath (point 4)', () {
    test('project-relative under cwd, ~-collapsed under home', () {
      expect(
        briefPath('/work/repo/.fah/bash_jobs/sh-24-x.log', cwd: '/work/repo'),
        '.fah/bash_jobs/sh-24-x.log',
      );
      expect(briefPath('/home/u/notes.txt', home: '/home/u'), '~/notes.txt');
      expect(briefPath('/opt/other/x', cwd: '/work/repo'), '/opt/other/x');
    });
  });
}
