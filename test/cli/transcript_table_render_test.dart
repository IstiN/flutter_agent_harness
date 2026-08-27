import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// Table-rendering contracts for the incremental transcript formatter.
///
/// Historical user-visible bugs were tables "falling apart" while a run
/// streams: rows misaligned, half-open tables flashing raw markdown, wide
/// glyphs (CJK/emoji) shifting borders. These tests pin the incremental
/// path (`TranscriptMarkdown.sync`) byte-exactly to the one-shot
/// `AnsiMarkdown.formatAll` at EVERY sync step — including when the source
/// ends mid-table — plus structural checks that survive ANSI stripping
/// (borders stay vertically aligned regardless of cell glyph widths).

final class _Strip {
  /// Removes SGR/graphic escape sequences so assertions see the glyphs the
  /// terminal draws.
  static String ansi(String s) =>
      s.replaceAll(RegExp('\x1B\\[[0-9;]*[A-Za-z]'), '');

  static List<String> all(List<String> lines) =>
      lines.map(ansi).toList(growable: false);
}

void main() {
  setUp(TranscriptMarkdown.resetDebugCounters);

  /// Feeds [doc] one line per sync (the live-stream cadence: a delta burst
  /// every ~50 ms). At every step the published view must equal a fresh
  /// one-shot formatAll of the SAME prefix — including prefixes ending
  /// mid-table.
  void expectSteppedParity(List<String> doc, int width, {String reason = ''}) {
    final session = TranscriptMarkdown(width: width);
    for (var n = 1; n <= doc.length; n++) {
      final actual = session.sync(doc.sublist(0, n));
      expect(
        actual,
        AnsiMarkdown(width: width).formatAll(doc.sublist(0, n)),
        reason: '${reason}stepped prefix [1..$n] diverged',
      );
    }
  }

  /// Structural eyeball check ON TOP of byte parity: consecutive rows of
  /// one rendered grid must repeat identical bar columns — borders stay
  /// aligned no matter what glyphs (CJK/emoji) the cells hold.
  void expectGridsAligned(List<String> rendered) {
    final stripped = _Strip.all(rendered);
    var prevIdx = -10;
    var gridBars = <List<int>>[];
    void closeGrid() {
      if (gridBars.length >= 2) {
        for (var r = 1; r < gridBars.length; r++) {
          expect(
            gridBars[r],
            gridBars.first,
            reason:
                'grid borders drift between rows:\n'
                '${gridBars.map((b) => b.join(',')).join('\n')}',
          );
        }
      }
      gridBars = [];
    }

    for (var i = 0; i < stripped.length; i++) {
      final line = stripped[i];
      if (!line.contains('|')) {
        if (i != prevIdx + 1) closeGrid();
        prevIdx = i;
        continue;
      }
      if (i != prevIdx + 1 && gridBars.isNotEmpty) closeGrid();
      gridBars.add([
        for (var c = 0; c < line.length; c++)
          if (line[c] == '|') c,
      ]);
      prevIdx = i;
    }
    closeGrid();
  }

  group('streamed GFM tables — incremental ≡ one-shot', () {
    test('classic table, one row per sync, closed by trailing prose', () {
      expectSteppedParity([
        '| name | qty |',
        '| ---- | --- |',
        '| alpha | 12 |',
        '| beta | 345 |',
        'done.',
      ], 60);
    });

    test('column width grows AFTER early rows would have been committed '
        '(narrow header, long body)', () {
      // While the table stays open its rendering is provisional: commit
      // points only exist once the pending-table buffer is empty, so late
      // wide cells cannot poison already-shown frames.
      expectSteppedParity([
        '| a | b |',
        '| - | - |',
        '| short | x |',
        '| this cell is much wider than the header | y |',
        '| pad | z |',
        'after',
      ], 70);
    });

    test('CJK + emoji cells keep box-grid alignment (display widths)', () {
      final doc = [
        '| 名前 | 説明 | status |',
        '| :--- | ---: | :-: |',
        '| 中文テスト | короткая 🚀 | ok |',
        '| x | 説明が長いセルです | 🎉 |',
        'after table prose',
      ];
      expectSteppedParity(doc, 60);
      expectSteppedParity(doc, 40, reason: 'narrow terminal ');
      expectGridsAligned(
        AnsiMarkdown(width: 60).formatAll(doc.take(doc.length - 1).toList()),
      );
    });

    test('escaped pipes and inline spans inside cells', () {
      expectSteppedParity([
        r'| expr | meaning |',
        '| ---- | ------- |',
        r'| `a \| b` | union (**bold**) |',
        '| x | ~~strike~~ [l](u) |',
        'tail',
      ], 60);
    });

    test('malformed table (no separator) falls back to raw rows', () {
      expectSteppedParity([
        '| just | pipes |',
        '| and | more |',
        'prose resume',
      ], 60);
    });

    group('wide tables WRAP cell content instead of collapsing to raw', () {
      // Regression from a real rendered reply: a two-column GFM table whose
      // second column held a full sentence overflowed the terminal width,
      // and the whole table fell back to raw markdown — pipes printed
      // literally, layout gone (user screenshot, clipboard 2026-08-27).
      const wideDoc = [
        '| Гейт | Результат |',
        '|---|---|',
        '| Сьюты форка | +697 passed, вкл. новый fps-тест и дроп-кадровый троттлинг рендера |',
        '| fa-сьюты поверх форка | +139 passed |',
        'tail prose',
      ];

      test('overflowing table renders a real box grid (never raw pipes)', () {
        final out = AnsiMarkdown(width: 60).formatAll(wideDoc);
        final stripped = _Strip.all(out);
        // The signature of the OLD bug: the markdown delimiter row and raw
        // pipe rows printed literally.
        expect(stripped.join('\n'), isNot(contains('|--')));
        // A real grid: the dim separator drawn with box-drawing glyphs…
        expect(stripped.join('\n'), contains('┼'));
        // …and aligned borders across EVERY physical grid row (continuation
        // lines included).
        expectGridsAligned(out);
      });

      test('long cells physically continue on follow-up grid rows', () {
        final out = AnsiMarkdown(width: 60).formatAll(wideDoc);
        final stripped = _Strip.all(out);
        final gridRows = stripped.where((l) => l.contains('│')).length;
        // Header + 2 logical rows would be 3 single-line grid rows; the
        // overflowing sentence forces at least one continuation line.
        expect(gridRows, greaterThan(3));
        // Nothing lost: the longest cell's tail still shows up somewhere.
        expect(stripped.where((l) => l.contains('fps-тест')), isNotEmpty);
      });

      test('stepped incremental sync stays byte-equal to one-shot', () {
        expectSteppedParity(wideDoc, 60);
        expectSteppedParity(wideDoc, 44, reason: 'narrower terminal ');
      });

      test('degenerate budget (tiny width, many columns) stays raw', () {
        final out = AnsiMarkdown(width: 18).formatAll([
          '| c1 | c2 | c3 | c4 |',
          '| -- | -- | -- | -- |',
          '| aa | bb | cc | dd |',
          'after',
        ]);
        final stripped = _Strip.all(out);
        // Floor kicks in: no grid attempt (no ┼), raw delimiter visible.
        expect(stripped.join('\n'), isNot(contains('┼')));
        expect(stripped.join('\n'), contains('--'));
      });
    });

    test('oversized table falls back to raw rows at tiny width', () {
      expectSteppedParity([
        '| col-one | col-two | col-three | col-four |',
        '| ------- | ------- | --------- | -------- |',
        '| aaaaaaa | bbbbbbb | ccccccc | ddddddd |',
        'after',
      ], 24);
    });

    test('fence right after open table flushes it; new table post-fence', () {
      expectSteppedParity([
        '| h1 | h2 |',
        '| -- | -- |',
        '```',
        'not | a | table | inside | fence',
        '```',
        '| h3 | h4 |',
        '| -- | -- |',
        '| r1 | r2 |',
        'end',
      ], 60);
    });

    test('blank line splits one table into two independent tables', () {
      expectSteppedParity([
        '| a | b |',
        '| - | - |',
        '',
        '| c | d |',
        '| - | - |',
        '| 1 | 2 |',
        'fin',
      ], 50);
    });

    test('separator arrives alone in its own sync step', () {
      expectSteppedParity(['| x | y |', '| --- | --- |', '| p | q |', 'z'], 60);
    });

    test(
      'source ENDS mid-table: exposed view still equals formatAll(prefix)',
      () {
        expectSteppedParity(['intro', '| h | i |', '| - | - |'], 60);
      },
    );

    for (final chunk in const [2, 3, 7]) {
      test('multi-line bursts (chunk=$chunk) across mixed table doc', () {
        final doc = [
          '# Report',
          'prose lead',
          '| kpi | v | note |',
          '| --- | -: | ---- |',
          '| 見出し | 42 | ok 🚀 |',
          r'| other | -7 | `x \| y` |',
          '',
          '| t1 | t2 |',
          '| -- | -- |',
          'trailer **b**',
        ];
        final session = TranscriptMarkdown(width: 60);
        for (var i = 0; i < doc.length; i += chunk) {
          final end = i + chunk > doc.length ? doc.length : i + chunk;
          final src = doc.sublist(0, end);
          expect(
            session.sync(src),
            AnsiMarkdown(width: 60).formatAll(src),
            reason: 'chunked prefix [1..$end] diverged',
          );
        }
      });
    }

    test('front-trim WHILE a table is open crosses the sentinel safely', () {
      // Simulates the 2000-line history cap trimming the head between two
      // flushes, with a HALF-OPEN table near the surviving head: the
      // boundary sentinels change identity, forcing the documented safe
      // full rebuild — result must still be byte-exact vs formatAll.
      final growing = [
        'old intro A',
        'old intro B',
        '| h | g |',
        '| - | - |',
        '| 1 | 2 |',
      ];
      final session = TranscriptMarkdown(width: 60);
      session.sync(growing);

      // Head trimmed by two lines; table STILL unfinished below.
      final trimmedOpen = [...growing.skip(2), '| r3 | long-cell-value |'];
      var out = session.sync(trimmedOpen);
      expect(out, AnsiMarkdown(width: 60).formatAll(trimmedOpen));

      // Continue normally afterwards.
      final resumed = [...trimmedOpen, '| r4 | v |', 'close.'];
      out = session.sync(resumed);
      expect(out, AnsiMarkdown(width: 60).formatAll(resumed));

      // …and replace-tail callers take the rebuild path exactly once per
      // boundary break, resuming incrementally afterwards.
      expect(TranscriptMarkdown.debugFullRebuilds, greaterThanOrEqualTo(1));
      final beforeRebuilds = TranscriptMarkdown.debugFullRebuilds;
      session.sync([...resumed, 'appendix']);
      expect(TranscriptMarkdown.debugFullRebuilds, beforeRebuilds);
    });

    test(
      'live-frame sequence while table is open shows no stale ghost rows',
      () {
        // Reproduces the historical flicker: watching intermediate frames
        // (what the user SEES at each flush), earlier table rows must never
        // reappear after the table closes and must not be duplicated when
        // later cells widen columns (provisional re-render, not append).
        final session = TranscriptMarkdown(width: 60);
        String strip(List<String> l) => _Strip.all(l).join('\n');

        final f1 = session.sync(['| h1 | h2 |']);
        // A lone buffered header falls back to its raw row IMMEDIATELY
        // (1:1 line-count-preserving contract, pinned by probe): the
        // frame must equal one-shot formatAll of the same prefix.
        expect(
          f1,
          AnsiMarkdown(width: 60).formatAll(const ['| h1 | h2 |']),
          reason: 'open buffered table tail must still match formatAll',
        );

        session.sync(['| h1 | h2 |', '| -- | -- |']);
        final f3 = session.sync(['| h1 | h2 |', '| -- | -- |', '| a | b |']);
        expect(strip(f3), contains('│'), reason: 'box grid drew');
        final f4 = session.sync([
          '| h1     | h2     |',
          '| ------ | ------ |',
          '| alpha  | beta   |',
        ]);
        // Provisional frame REPLACES the draft grid, never stacks a copy.
        expect(
          '│'.allMatches(strip(f4)).length,
          lessThanOrEqualTo('│'.allMatches(strip(f3)).length),
          reason: 'interim frame should not accumulate duplicate grids',
        );
        expectGridsAligned(_Strip.all(f4));
      },
    );
  });
}
