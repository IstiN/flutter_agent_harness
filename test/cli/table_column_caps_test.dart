import 'dart:io';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// Column-sizing contracts for box-grid tables (issue #686).
///
/// The overflow distribution used to seed every column at the 6-cell floor
/// and hand the spare budget to whatever column needed the most beyond it —
/// one long-text column out-voted every cheap column and short labels
/// wrapped onto 2+ physical lines. The rule now is fit-preserving
/// water-filling: each column may claim an equal fair share of the budget;
/// columns that fit their share keep their FULL natural width, the freed
/// budget is re-shared among the rest, and the remaining oversized columns
/// split the pool proportionally to natural width (floored at 6).
void main() {
  /// Grid overhead: ' cell ' per column plus ' │ ' joiners plus the
  /// leading/trailing space — mirrors _flushTable's budget math.
  int overhead(int columns) => (columns - 1) * 3 + 2;

  group('columnCaps — sizing invariants (issue #686)', () {
    test('UT-1: caps never overflow the frame (sum + overhead ≤ width)', () {
      const shapes = [
        ([8, 120], 60),
        ([8, 120], 80),
        ([8, 120], 100),
        ([8, 120], 120),
        ([10, 12, 200], 72),
        ([21, 66], 55),
        ([6, 200], 40),
        ([7, 7, 7], 30),
        ([2, 40, 9, 90], 50),
      ];
      for (final (natural, width) in shapes) {
        // The caller (_flushTable) hands the caps function the frame
        // width MINUS the joiner/padding overhead; the invariant is that
        // the caps spend at most that budget.
        final budget = width - overhead(natural.length);
        final caps = AnsiMarkdown.columnCaps(natural, budget)!;
        expect(
          caps.fold<int>(0, (a, b) => a + b) + overhead(natural.length),
          lessThanOrEqualTo(width),
          reason: 'natural=$natural width=$width → caps=$caps',
        );
      }
    });

    test('UT-2: floor — caps never drop below min(6, natural)', () {
      const shapes = [
        ([6, 200], 40),
        ([7, 7, 7], 18),
        ([2, 40, 9, 90], 50),
        ([2, 300], 40),
      ];
      for (final (natural, budget) in shapes) {
        final caps = AnsiMarkdown.columnCaps(natural, budget)!;
        for (var c = 0; c < natural.length; c++) {
          expect(
            caps[c],
            greaterThanOrEqualTo(min(6, natural[c])),
            reason: 'natural=$natural budget=$budget → caps=$caps',
          );
        }
      }
    });

    test('UT-3: no stretching — caps never exceed the natural width', () {
      const shapes = [
        ([2, 40, 9, 90], 50),
        ([2, 300], 40),
        ([6, 200], 40),
        ([10, 12, 200], 72),
      ];
      for (final (natural, budget) in shapes) {
        final caps = AnsiMarkdown.columnCaps(natural, budget)!;
        for (var c = 0; c < natural.length; c++) {
          expect(
            caps[c],
            lessThanOrEqualTo(natural[c]),
            reason: 'natural=$natural budget=$budget → caps=$caps',
          );
        }
      }
      // The old rule seeded EVERY column at 6 — a 2-cell column came out
      // stretched to 6. Regression: it keeps its 2 cells.
      expect(AnsiMarkdown.columnCaps([2, 300], 40), [2, 38]);
    });

    test('UT-4: fit preservation — short columns keep their full natural '
        'width (the report repro, AC1)', () {
      // Worked examples from the card, asserted verbatim:
      // old rule → [6, 54] for [8, 120]@60; fit-preserving → [8, 52].
      expect(AnsiMarkdown.columnCaps([8, 120], 60), [8, 52]);
      expect(AnsiMarkdown.columnCaps([10, 12, 200], 72), [10, 12, 50]);
      expect(AnsiMarkdown.columnCaps([6, 200], 40), [6, 34]);
      // The real-user fixture traced in the card: natural [21, 66],
      // budget 55 — old caps [7, 48] wrapped every first-column cell;
      // now the first column keeps all 21 cells, single-line.
      expect(AnsiMarkdown.columnCaps([21, 66], 55), [21, 34]);
      // The report shape at normal terminal widths: the short column
      // keeps 8 cells, the text column takes exactly what is left.
      expect(AnsiMarkdown.columnCaps([8, 120], 80), [8, 72]);
      expect(AnsiMarkdown.columnCaps([8, 120], 100), [8, 92]);
      expect(AnsiMarkdown.columnCaps([8, 120], 120), [8, 112]);
    });

    test('UT-5: deterministic; ties resolved left-to-right', () {
      const natural = [8, 120, 8, 40, 120];
      final first = AnsiMarkdown.columnCaps(natural, 90)!;
      for (var i = 0; i < 25; i++) {
        expect(AnsiMarkdown.columnCaps(natural, 90), first);
      }
      // Truncation leftovers are repaid widest-first, so among two equal
      // 7-cell columns sharing a 13-cell budget the LEFT one gets the
      // odd cell.
      expect(AnsiMarkdown.columnCaps([7, 7], 13), [7, 6]);
    });

    test('UT-6: degenerate budget (below n·6) → null (raw fallback)', () {
      expect(AnsiMarkdown.columnCaps([6, 6, 6, 6], 18), isNull);
      expect(AnsiMarkdown.columnCaps([200], 5), isNull);
      // Budget exactly at the floor sum still renders.
      expect(AnsiMarkdown.columnCaps([6, 6, 6, 6], 24), [6, 6, 6, 6]);
    });

    test('water-filling re-fairs after fitting: a late-fitting column '
        'keeps its natural width too', () {
      // Round 1 (fair 50): only the 40-cell column fits; the freed pool
      // re-fairs to 55 in round 2, which the 55-cell column exactly
      // fits — only the 200-cell column splits what is left.
      expect(AnsiMarkdown.columnCaps([40, 55, 200], 150), [40, 55, 55]);
    });

    test('proportional floor clamp reclaims from the widest column', () {
      // One dominant column truncates its neighbor's share below the
      // floor: the neighbor is clamped UP to 6 and the dominant column
      // pays for it (deterministically, widest-first).
      final caps = AnsiMarkdown.columnCaps([61, 100000], 120)!;
      expect(caps[0], 6);
      expect(caps.fold<int>(0, (a, b) => a + b), 120);
    });
  });

  group('table goldens (.ans, issue #686)', () {
    // The real user reply from the report (clipboard 2026-08-27): a
    // [short labels, long text] table that used to floor the first
    // column to 7 cells.
    const reportDoc = [
      '| Гейт | Результат |',
      '|---|---|',
      '| Сьюты форка | +697 passed, вкл. новый fps-тест и дроп-кадровый троттлинг рендера |',
      '| fa-сьюты поверх форка | +139 passed |',
    ];
    // The report's shape: short labels + one long-text column, at the
    // normal terminal widths where sum(natural) > budget.
    const shortLongDoc = [
      '| Компонент | Состояние | Детали |',
      '| --- | --- | --- |',
      '| auth | done | переехала на новый провайдер с полной обратной совместимостью端 и без единого ручного шага для пользователя |',
      '| ui | wip | таблицы в транскрипте больше не схлопывают короткие колонки в суп из переносов строк |',
      '| cli | todo | нужен ручной прогон сценария resume на узком терминале перед следующим релизом |',
    ];
    // REG anchor: an all-narrow FITTING table — renders byte-identically
    // before and after the fix (only the overflow path changed).
    const narrowFitDoc = [
      '| name | qty |',
      '| ---- | --- |',
      '| alpha | 12 |',
      '| beta | 345 |',
    ];
    // REG anchor: degenerate budget → raw markdown fallback, unchanged.
    const degenerateDoc = [
      '| c1 | c2 | c3 | c4 |',
      '| -- | -- | -- | -- |',
      '| aa | bb | cc | dd |',
    ];

    const cases = <(String, int, List<String>)>[
      ('table_report_fixture_60', 60, reportDoc),
      ('table_short_long_80', 80, shortLongDoc),
      ('table_short_long_100', 100, shortLongDoc),
      ('table_short_long_120', 120, shortLongDoc),
      ('table_narrow_fit_80', 80, narrowFitDoc),
      ('table_raw_fallback_18', 18, degenerateDoc),
    ];

    for (final (name, width, doc) in cases) {
      test('golden $name', () {
        final rendered = AnsiMarkdown(width: width).formatAll(doc).join('\n');
        final file = File('test/cli/goldens/$name.ans');
        if (Platform.environment.containsKey('FA_UPDATE_TABLE_GOLDENS')) {
          file.writeAsStringSync('$rendered\n');
          return;
        }
        expect('$rendered\n', file.readAsStringSync());
      });
    }
  });
}

// Local min to keep this test file dependency-light.
int min(int a, int b) => a < b ? a : b;
