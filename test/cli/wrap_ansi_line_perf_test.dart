import 'dart:math';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// Perf contracts for [wrapAnsiLine] (gh-1496): the transcript wrap pass
/// was the #1 self-time hotspot — 1084s self over 84 profiled calls,
/// mean 12.9s (instrumented) — because the tokenizer paid a regex match,
/// a String allocation and a width measurement PER VISIBLE CELL. The
/// rewrite batches same-width rune runs into single tokens (one substring
/// + one carried width per run, SGR state machine unchanged) and drops the
/// double width measurement in flushWord.
///
/// Bounds follow the gh-1357 rule: absolute budgets carry generous
/// headroom over local medians (CI runners jitter; a bound the fix sits
/// at is noise, not a gate), and the growth-shape asserts are the real
/// regression guard — a per-row rescan or per-cell allocation coming back
/// shows up as a superlinear doubling ratio long before any absolute
/// budget trips.
final _rng = Random(1496);

const _words = [
  'lorem',
  'ipsum',
  'dolor',
  'sit',
  'amet',
  'consectetur',
  'adipiscing',
  'elit',
  'sed',
  'do',
  'eiusmod',
  'tempor',
  'incididunt',
  'ut',
  'labore',
  'et',
  'dolore',
  'magna',
  'aliqua',
];

/// [_cells] visible cells of ASCII prose (the dominant transcript shape).
String asciiProse(int cells) {
  final buf = StringBuffer();
  while (buf.length < cells) {
    buf.write(_words[_rng.nextInt(_words.length)]);
    buf.write(' ');
  }
  return buf.toString().substring(0, cells);
}

/// [_cells] cells of CJK prose (every rune 2 cells, exercises the rune
/// classification path — no ASCII batching possible).
String cjkProse(int cells) {
  final buf = StringBuffer();
  final half = cells ~/ 2;
  var i = 0;
  while (i < half) {
    buf.writeCharCode(0x4e00 + _rng.nextInt(2000));
    i++;
    if (i % 17 == 0) buf.write(' ');
  }
  return buf.toString();
}

/// [_cells] cells in ONE word (exercises the hard-cut slice path).
String oneGiantWord(int cells) => 'x' * cells;

/// Median wrap time over [runs] executions (one untimed warm-up first).
double medianWrapMs(String line, int width, {int runs = 5}) {
  wrapAnsiLine(line, width); // JIT warm-up, untimed
  final times = List<double>.filled(runs, 0);
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    wrapAnsiLine(line, width);
    sw.stop();
    times[i] = sw.elapsedMicroseconds / 1000.0;
  }
  times.sort();
  return times[runs ~/ 2];
}

/// Growth-shape contract: doubling the input must not more than [maxRatio]
/// the median time. Linear wraps measure ~2x here; the old quadratic
/// candidates (re-scan per emitted row) measure ~4x+. 3.2 sits between
/// with room for CI scheduler jitter on both sides.
void expectLinearGrowth(
  String Function(int cells) build,
  int baseCells,
  String label,
) {
  final small = medianWrapMs(build(baseCells), 80);
  final doubled = medianWrapMs(build(baseCells * 2), 80);
  final ratio = doubled / small;
  expect(
    ratio,
    lessThan(3.2),
    reason:
        '$label wrap is superlinear in input size: '
        '$baseCells cells = ${small.toStringAsFixed(2)}ms, '
        '${baseCells * 2} cells = ${doubled.toStringAsFixed(2)}ms '
        '(ratio ${ratio.toStringAsFixed(2)}x)',
  );
}

void main() {
  test('1M visible ASCII cells wrap in < 100ms (median, warm VM)', () {
    // The gh-1496 acceptance bar. Pre-fix this measured ~117ms (6.9x the
    // post-fix median) — the bound pins the constant-factor win, not just
    // the absence of quadratic growth.
    final ms = medianWrapMs(asciiProse(1000000), 80);
    expect(ms, lessThan(100), reason: 'took ${ms.toStringAsFixed(1)}ms');
  });

  test('1M-cell single word hard-cuts in < 100ms (median, warm VM)', () {
    // The hard-cut slice path (a word longer than the width).
    final ms = medianWrapMs(oneGiantWord(1000000), 80);
    expect(ms, lessThan(100), reason: 'took ${ms.toStringAsFixed(1)}ms');
  });

  test('wrap time grows linearly: ASCII prose, 2x input <= 3.2x time', () {
    expectLinearGrowth(asciiProse, 100000, 'ASCII prose');
  });

  test('wrap time grows linearly: CJK prose, 2x input <= 3.2x time', () {
    // CJK walks the wide-rune tables per rune — no ASCII batching — so a
    // regression that re-measures or re-scans per emitted row would show
    // here first.
    expectLinearGrowth(cjkProse, 100000, 'CJK prose');
  });

  test('wrap time grows linearly: hard-cut single word, 2x <= 3.2x', () {
    expectLinearGrowth(oneGiantWord, 100000, 'single word');
  });

  test('wrapped output stays contract-clean at scale', () {
    // Cheap correctness anchor next to the timings: rows never exceed the
    // width in visible cells and reassemble to the source (the properties
    // ansi_markdown_test.dart pins on small inputs, checked once on a
    // large one so a fast-but-wrong rewrite cannot pass this file).
    final line = asciiProse(200000);
    final rows = wrapAnsiLine(line, 80);
    var reassembled = 0;
    for (final row in rows) {
      expect(row.length, lessThanOrEqualTo(80));
      reassembled += row.length;
    }
    // Reassembly reproduces the visible text minus dropped edge spaces.
    expect(reassembled, greaterThanOrEqualTo(line.length - rows.length));
  });
}
