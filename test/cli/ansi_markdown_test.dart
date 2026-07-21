import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('AnsiMarkdown', () {
    test('h1 renders bold+underline indigo without the # prefix', () {
      final out = AnsiMarkdown().formatLine('# Title');
      expect(out, contains('\x1b[1m'));
      expect(out, contains('\x1b[4m'));
      expect(out, contains('\x1b[38;2;129;140;248m'));
      expect(out, contains('Title'));
      expect(out, isNot(contains('# Title')));
    });

    test('h3 keeps the literal ### prefix', () {
      final out = AnsiMarkdown().formatLine('### Sub');
      expect(out, contains('### Sub'));
    });

    test('inline bold, italic, strike and code spans get SGR styles', () {
      final md = AnsiMarkdown();
      expect(md.formatLine('a **b** c'), contains('\x1b[1mb\x1b[0m'));
      expect(md.formatLine('a *b* c'), contains('\x1b[3mb\x1b[0m'));
      expect(md.formatLine('a ~~b~~ c'), contains('\x1b[9mb\x1b[0m'));
      expect(
        md.formatLine('a `b` c'),
        contains('\x1b[38;2;94;234;212mb\x1b[0m'),
      );
    });

    test('partial emphasis from an in-flight stream stays unstyled', () {
      expect(AnsiMarkdown().formatLine('a **bol'), 'a **bol');
    });

    test('unordered and ordered list markers become accent bullets', () {
      final md = AnsiMarkdown();
      final bullet = md.formatLine('- item');
      expect(bullet, contains('•'));
      expect(bullet, contains('item'));
      final numbered = md.formatLine('3. item');
      expect(numbered, contains('\x1b[38;2;94;234;212m3.\x1b[0m'));
    });

    test('task list items keep a styled checkbox', () {
      expect(AnsiMarkdown().formatLine('- [x] done'), contains('[✓]'));
      expect(AnsiMarkdown().formatLine('- [ ] todo'), contains('[ ]'));
    });

    test('code fences toggle verbatim indented content', () {
      final md = AnsiMarkdown();
      expect(md.formatLine('```dart'), contains('```dart'));
      final code = md.formatLine('final **x** = 1;');
      // Inside a fence the markdown markers stay literal and unstyled.
      expect(code, '  final **x** = 1;');
      expect(md.formatLine('```'), contains('```'));
      // After the fence closes, markdown works again.
      expect(md.formatLine('a **b**'), contains('\x1b[1mb\x1b[0m'));
    });

    test('blockquote gets a bar and dim italic body', () {
      final out = AnsiMarkdown().formatLine('> quoted');
      expect(out, contains('│'));
      expect(out, contains('quoted'));
    });

    test('horizontal rule renders as a dim full-width rule capped at 80', () {
      final out = AnsiMarkdown(width: 120).formatLine('---');
      expect(out, contains('─' * 80));
    });

    test('links underline the text and dim the url', () {
      final out = AnsiMarkdown().formatLine('see [docs](https://x.dev)');
      expect(out, contains('\x1b[4mdocs\x1b[0m'));
      expect(out, contains('(https://x.dev)'));
    });

    test('pre-styled background lines are padded to the current width', () {
      const line = '\x1b[48;2;30;34;42mhello **world**\x1b[0m';
      final out = AnsiMarkdown(width: 40).formatLine(line);
      // No markdown formatting inside, but the background spans the width.
      expect(out, contains('hello **world**'));
      expect(out.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').length, 40);
    });

    test('stored full-width rules re-render at the current width', () {
      final stored = '\x1b[2m${'─' * 200}\x1b[0m';
      final out = AnsiMarkdown(width: 80).formatLine(stored);
      expect(out.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''), '─' * 80);
    });

    group('wrapAnsiLine', () {
      test('never cuts inside an SGR escape at the wrap boundary', () {
        // A styled inline-code span straddling the wrap column: the escape
        // must stay whole on one side (dart_tui's wrap leaks e.g. `212m`).
        const teal = '\x1b[38;2;94;234;212m';
        const reset = '\x1b[0m';
        final line = '${'x' * 8}(${teal}lsp$reset): text';
        final rows = wrapAnsiLine(line, 10);
        for (final row in rows) {
          final visible = row.replaceAll(AnsiMarkdown.ansiSgrPattern, '');
          expect(visible.length, lessThanOrEqualTo(10));
          // No stray escape fragments: every \x1b starts a complete SGR.
          expect(row.contains(RegExp(r'\x1b(?!\[[0-9;]*m)')), isFalse);
        }
        // Reassembled visible text is unchanged.
        expect(
          rows.join().replaceAll(AnsiMarkdown.ansiSgrPattern, ''),
          line.replaceAll(AnsiMarkdown.ansiSgrPattern, ''),
        );
      });

      test('short lines pass through unwrapped', () {
        expect(wrapAnsiLine('hello', 10), ['hello']);
      });

      test('wraps long lines at the width', () {
        final rows = wrapAnsiLine('x' * 25, 10);
        expect(rows, ['x' * 10, 'x' * 10, 'x' * 5]);
      });
    });

    group('tables', () {
      final table = [
        '| № | Название | Описание |',
        '|:--- | :--- | :--- |',
        '| 1 | **Инструменты** | Использование `ls` |',
        '| 2 | AI/LSP | Диагностика |',
      ];

      test('renders a compact box grid with a dim separator', () {
        final out = AnsiMarkdown(width: 80).formatAll(table);
        expect(out, hasLength(table.length)); // 1:1 line mapping
        // Header row: bold, padded to column width, │ cell separators.
        expect(out[0], contains('\x1b[1m'));
        expect(out[0], contains('│'));
        // Separator row: dim box-drawing.
        expect(out[1], contains('┼'));
        expect(out[1], contains('─'));
        // Data rows keep inline formatting (bold/cyan code).
        expect(out[2], contains('\x1b[1mИнструменты\x1b[0m'));
        expect(out[2], contains('\x1b[38;2;94;234;212mls\x1b[0m'));
        expect(out[3], contains('AI/LSP'));
        // The grid is rectangular: every row has the same visible length and
        // the │ separators land in the same visible columns on every row
        // (inline markers like `code` backticks must not skew the widths).
        final ansi = RegExp(r'\x1b\[[0-9;]*m');
        final visible = [for (final l in out) l.replaceAll(ansi, '')];
        final lengths = visible.map((l) => l.length).toSet();
        expect(lengths, hasLength(1));
        List<int> columnsOf(String line, String char) => [
          for (var i = 0; i < line.length; i++)
            if (line[i] == char) i,
        ];
        final headerColumns = columnsOf(visible[0], '│');
        // Data rows share the header's │ columns; the separator's ┼ columns
        // line up with them too.
        for (final row in visible.skip(2)) {
          expect(columnsOf(row, '│'), headerColumns);
        }
        expect(columnsOf(visible[1], '┼'), headerColumns);
      });

      test('falls back to raw lines when the table does not fit', () {
        final out = AnsiMarkdown(width: 20).formatAll(table);
        for (var i = 0; i < table.length; i++) {
          expect(out[i], contains('|'));
        }
      });

      test('malformed tables (no separator row) pass through raw', () {
        final out = AnsiMarkdown().formatAll(['| a | b |', '| 1 | 2 |']);
        expect(out[0], contains('| a | b |'));
      });
    });
  });
}
