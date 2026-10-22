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
/// budget trips. The growth asserts take several independent attempts and
/// gate on the min ratio (gh-1532), with each attempt sampling each size
/// at its fastest run (PR #1635 validation red ×2): contention can only
/// ADD wall time, so the per-size min approaches the uncontended ratio
/// even when a steal window spans most of an attempt's runs, and the min
/// across attempts covers windows longer than one attempt — a scheduler
/// preemption on a loaded runner can no longer flake the gate.
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

/// Elapsed microseconds for running [body] — a real Stopwatch by default,
/// or an injected fake (see [contendedClock]) so the gh-1532 contention
/// scenario is reproduced deterministically instead of by CI luck.
typedef ElapsedUs = int Function(void Function() body);

int _stopwatchUs(void Function() body) {
  final sw = Stopwatch()..start();
  body();
  sw.stop();
  return sw.elapsedMicroseconds;
}

/// Deterministic stand-in for a contended runner: delegates to a real
/// stopwatch but adds [spikeMs] of fake preemption time to the timed
/// measurements whose 1-based index is in [spiked] — a runner steal
/// spanning several timed runs, the shape that flaked gh-1532 live.
///
/// [calls] exposes how many measurements the fake has timed. The
/// preemption test asserts the expected total (attempts × sizes ×
/// runs) so a future change to the measure loop's call layout turns
/// the index-based [spiked] addressing into a LOUD failure instead of
/// silently shifting the spikes onto the wrong measurements (where
/// they could depress the ratio and leave the test green while
/// asserting nothing).
final class ContendedClock {
  ContendedClock({required this._spiked, this.spikeMs = 30});

  final Set<int> _spiked;

  /// Fake preemption time added to each spiked measurement.
  final double spikeMs;

  /// Number of measurements timed so far (1-based [spiked] addressing).
  var calls = 0;

  /// Times [body] like [ElapsedUs], adding the spike when spiked.
  int call(void Function() body) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    calls++;
    return sw.elapsedMicroseconds +
        (_spiked.contains(calls) ? (spikeMs * 1000).round() : 0);
  }
}

/// Median wrap time over [runs] executions (one untimed warm-up first).
double medianWrapMs(
  String line,
  int width, {
  int runs = 5,
  ElapsedUs? elapsedUs,
}) {
  final measure = elapsedUs ?? _stopwatchUs;
  wrapAnsiLine(line, width); // JIT warm-up, untimed
  final times = List<double>.filled(runs, 0);
  for (var i = 0; i < runs; i++) {
    times[i] = measure(() => wrapAnsiLine(line, width)) / 1000.0;
  }
  times.sort();
  return times[runs ~/ 2];
}

/// Timed runs per size in one growth attempt (min-of-runs, gh-1532).
const _growthRuns = 5;

/// Independent doubling samples per growth assertion (gh-1532): the
/// superlinear guard is gated on the MIN ratio across the attempts —
/// contention can only ADD wall time, so the min approaches the
/// uncontended ratio. A genuine regression measures ~4x+ in every
/// attempt and still fails.
const _growthAttempts = 3;

/// Upper bound of the doubling ratio for a linear wrap: linear wraps
/// measure ~2x here; the old quadratic candidates (re-scan per emitted
/// row) measure ~4x+. 3.2 sits between with room for CI scheduler
/// jitter on both sides.
const _maxLinearRatio = 3.2;

/// Lower bound of the doubling ratio across the attempts (linear ≈ 2x):
/// the max must clear it so a degenerate flat measurement cannot pass
/// — the retry-min must not become a rubber stamp.
const _minGrowthRatio = 1.5;

/// Growth-shape contract: doubling the input must not more than
/// [_maxLinearRatio] the fastest wrap time — see the constants above for
/// the guard bounds and the gh-1532 rationale.
///
/// Sampling shape (PR #1783 validation red, run 39799009640): the sizes
/// are sampled in an INTERLEAVED order — one timed run of each size per
/// pair, [_growthRuns] pairs per attempt — never one size's whole block
/// followed by the other's. The growth assertions sample each size with
/// the MIN of its runs, not the median: scheduler steals and GC pauses
/// can only ADD wall time, so the fastest observed run is the
/// least-contaminated estimate of the true per-size cost (PR #1635
/// validation red ×2: a steal window spanning ≥3 of 5 runs of the
/// doubled size in every attempt inflated every attempt median — runs
/// 38824807299 and 38830911279). Interleaving adds weather parity: the
/// pre-fix harness measured all small runs, then all doubled runs, so
/// the doubled samples of the 3 attempts sat in three contiguous blocks
/// and one sustained contention phase inflated EVERY doubled minimum
/// (best ratio 3.24x at 500k cells) while the small minima stayed
/// clean — the cross-attempt min had nothing clean to rescue. With
/// alternating sizes, a phase of the same length strikes runs of BOTH
/// sizes, both per-size minima keep clean runs, and the ratio survives.
/// A genuine quadratic regression inflates every doubled run including
/// the fastest, so it still trips.
void expectLinearGrowth(
  String Function(int cells) build,
  int baseCells,
  String label, {
  ElapsedUs? elapsedUs,
}) {
  final measure = elapsedUs ?? _stopwatchUs;
  var minRatio = double.infinity;
  var maxRatio = 0.0;
  for (var a = 0; a < _growthAttempts; a++) {
    final smallLine = build(baseCells);
    final doubledLine = build(baseCells * 2);
    wrapAnsiLine(smallLine, 80); // JIT warm-up, untimed
    wrapAnsiLine(doubledLine, 80); // JIT warm-up, untimed
    var smallMin = double.infinity;
    var doubledMin = double.infinity;
    for (var i = 0; i < _growthRuns; i++) {
      final s = measure(() => wrapAnsiLine(smallLine, 80)) / 1000.0;
      if (s < smallMin) smallMin = s;
      final d = measure(() => wrapAnsiLine(doubledLine, 80)) / 1000.0;
      if (d < doubledMin) doubledMin = d;
    }
    final ratio = doubledMin / smallMin;
    if (ratio < minRatio) minRatio = ratio;
    if (ratio > maxRatio) maxRatio = ratio;
  }
  expect(
    minRatio,
    lessThan(_maxLinearRatio),
    reason:
        '$label wrap is superlinear in input size: best doubling ratio '
        'across $_growthAttempts attempts is ${minRatio.toStringAsFixed(2)}x '
        '($baseCells -> ${baseCells * 2} cells)',
  );
  expect(
    maxRatio,
    greaterThan(_minGrowthRatio),
    reason:
        '$label doubling ratio never exceeded ${_minGrowthRatio}x '
        '(${maxRatio.toStringAsFixed(2)}x across $_growthAttempts '
        'attempts) — the measurement is degenerate and asserts nothing',
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

  test('absolute median gate trips on a sustained contention window '
      '(PR #1785 hostile-env red, run 39864427289 — reproduced)', () {
    // The live red: the median-of-5 measured 118.03ms against the 100ms
    // budget — ~7x the file-header baseline (~17ms) — while the sibling
    // single-word gate and all three growth gates on the SAME run stayed
    // green: a runner contention phase spanned >=3 of the attempt's 5
    // timed runs. Fixed 17ms/119ms samples reproduce that shape with no
    // real timing involved: any 3 of the 5 timed runs slowed puts the raw
    // single-attempt median at 119ms — over the budget, wrap untouched.
    final oneContendedAttempt = ScriptedClock(slowed: {3, 4, 5});
    final rawMedian =
        medianWrapMs('x', 80, elapsedUs: oneContendedAttempt.call);
    expect(
      rawMedian,
      greaterThan(100),
      reason:
          'the live red shape must trip the raw single-attempt median '
          '(measured ${rawMedian.toStringAsFixed(1)}ms)',
    );
  });

  test('absolute budget gate survives a contention phase covering one '
      'whole attempt (gh-1785 rework fix)', () {
    // Attempt 1 slowed on EVERY timed run (worse than the live red), the
    // two follow-up attempts clean: the gate rides the clean attempt
    // medians via the min and passes — contention alone can no longer red
    // the leg, and the wrap itself needs no change (the live red was
    // weather, not regression — see the reproduced test above).
    final firstAttemptSlowed = ScriptedClock(slowed: {1, 2, 3, 4, 5});
    expectWrapUnderBudget(
      'x',
      80,
      100,
      '1M ASCII prose',
      elapsedUs: firstAttemptSlowed.call,
    );
    // Layout guard, gh-1532 style: 3 attempts x 5 timed runs = 15
    // measurement calls. If the attempt layout ever changes, the slowed
    // indices above silently land on the wrong calls — this turns that
    // into a loud failure.
    expect(
      firstAttemptSlowed.calls,
      15,
      reason: 'the slowed indices encode the attempt layout',
    );
  });

  test('hardened absolute gate still trips on a genuine regression '
      '(min-of-attempts is not a rubber stamp)', () {
    // Every attempt inflated — the shape a real constant-factor
    // regression produces (the pre-gh-1496 wrap measured ~117ms clean,
    // over the budget in EVERY attempt): the best of the attempt medians
    // is still over the budget and the gate must fail, the same
    // meaningfulness guard the growth asserts carry (degenerate-flat).
    final alwaysSlow = ScriptedClock(
      slowed: {for (var i = 1; i <= 15; i++) i},
    );
    expect(
      () => expectWrapUnderBudget(
        'x',
        80,
        100,
        '1M ASCII prose',
        elapsedUs: alwaysSlow.call,
      ),
      throwsA(isA<TestFailure>()),
    );
  });

  test('wrap time grows linearly: ASCII prose, 2x input <= 3.2x time', () {
    // 500k base cells, not 100k: at ~3ms per wrap the sample sits on the
    // scheduler-noise floor of a shared CI runner — the run at PR #1526
    // measured ratio 3.78x purely from jitter (one scheduling pause on the
    // doubled sample) and red-blocked the gate. At ~16ms per wrap the same
    // pause is proportionally ~5x smaller; the 3.2 threshold (linear ~2x,
    // quadratic candidates ~4x+) keeps its detection margin. The sibling
    // absolute tests already wrap 1M cells, so this scale is the intended
    // operating point of the fixture builders, not a new one.
    expectLinearGrowth(asciiProse, 500000, 'ASCII prose');
  });

  test('wrap time grows linearly: CJK prose, 2x input <= 3.2x time', () {
    // CJK walks the wide-rune tables per rune — no ASCII batching — so a
    // regression that re-measures or re-scans per emitted row would show
    // here first. 500k for the same scheduler-noise reason as ASCII.
    expectLinearGrowth(cjkProse, 500000, 'CJK prose');
  });

  test('wrap time grows linearly: hard-cut single word, 2x <= 3.2x', () {
    expectLinearGrowth(oneGiantWord, 500000, 'single word');
  });

  test('growth ratio is pause-proof (gh-1460 rework flake regression)', () {
    // Deterministic anchor for the CI run 38112524699 flake: the failing
    // leg measured small=3.31ms / doubled=12.09ms (ratio 3.65 against the
    // 3.2 bound) — a scheduling pause inflated the doubled-size median
    // while the wrap itself stayed linear. The sample sets below reproduce
    // that exact shape: the old median statistic trips on it, the
    // min-of-9 statistic expectLinearGrowth now uses does not, and a
    // genuinely superlinear pair still trips either way (real quadratic
    // work inflates both sizes, so the min-ratio keeps ~4x).
    const quietSmall = [3.4, 3.31, 3.35, 3.3, 3.42, 3.4, 3.38, 3.33, 3.4];
    const pausedDoubled = [6.8, 7.0, 12.09, 12.2, 11.9, 7.1, 6.9, 7.2, 7.0];
    final oldMedianRatio =
        pausedDoubled[4] / quietSmall[4]; // medians of the 9 samples
    expect(oldMedianRatio, greaterThan(3.2)); // the CI red, reproduced
    final newMinRatio =
        pausedDoubled.first / quietSmall.first; // mins of the 9 samples
    expect(newMinRatio, lessThan(3.2)); // the fix
    // Genuine superlinearity still trips the min-based ratio:
    const quadraticSmall = [3.3, 3.4, 3.2, 3.3, 3.4, 3.3, 3.2, 3.4, 3.3];
    const quadraticDoubled = [
      13.0,
      13.2,
      12.8,
      13.1,
      13.0,
      12.9,
      13.1,
      13.0,
      12.9,
    ];
    final minQuadraticRatio = quadraticDoubled.first / quadraticSmall.first;
    expect(minQuadraticRatio, greaterThan(3.2));
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

  test(
    'growth assertion survives a contended-runner preemption spike (gh-1532)',
    () {
      // gh-1532 live failure (fa run 38113730068): on a runner contended by
      // release windows a scheduler steal spanning several timed runs
      // inflated the one-shot doubling ratio past 3.2x on a ~4ms baseline.
      // 30ms of fake preemption across the first three timed runs of the
      // doubled measurement in attempt 1 was a ~9x MEDIAN ratio for that
      // attempt under the pre-gh-1532 harness; the per-size min (the
      // clean runs 4-5 pin the doubled sample) and the cross-attempt min
      // must both ride it out.
      // Measurement call order (interleaved, PR #1783 red): per attempt,
      // s,d,s,d,s,d,s,d,s,d — the doubled timed runs sit at calls
      // 2,4,6,8,10 within each attempt.
      final spike = ContendedClock(spiked: {2, 4, 6});
      expectLinearGrowth(
        asciiProse,
        100000,
        'ASCII prose',
        elapsedUs: spike.call,
      );
      // Layout guard: the spiked indices above encode the measure loop's
      // exact call layout (3 attempts × 2 sizes × 5 timed runs). If that
      // layout ever changes the spikes silently land on the wrong
      // measurements — this assertion turns that into a loud failure.
      expect(
        spike.calls,
        30,
        reason: 'the spiked indices encode the call layout',
      );
    },
  );

  test('growth assertion survives contention that poisons every attempt median '
      '(PR #1635 validation red ×2)', () {
    // The gh-1532 harness still red twice within one hour on the arm64
    // core shards (fa runs 38824807299 shard 0 and 38830911279 shard 3,
    // best ratios 3.35x/3.31x at 500k cells): a contention window long
    // enough to span ≥3 of the 5 timed runs of the doubled size in EVERY
    // attempt inflates every attempt MEDIAN, so the cross-attempt min
    // cannot rescue it. Model that shape deterministically: 3 of the 5
    // doubled runs spiked in each of the 3 attempts (the live-red
    // minimum: median-of-5 [c,c,s] is still a spiked value), small runs
    // untouched (the small samples were stable in both live reds —
    // exposure scales with run duration). Median-of-5 takes a spiked
    // value in every attempt and fails; a per-size min finds the two
    // clean doubled runs per attempt (~2x) and passes.
    //
    // Exactly one clean doubled run per attempt (4-of-5 spiked) was not
    // enough — that sample is timed in real wall clock, and real jitter
    // on it is the very shape being modeled: gh-1732 (fa run 39546301132,
    // shard 2) red at a 3.30x best ratio because the single clean
    // doubled sample of every attempt was inflated (~+60%) while the
    // real 500k growth tests on the same runner stayed green. Two clean
    // samples per attempt make the per-attempt min tolerate one
    // contaminated clean run; the cross-attempt min covers the rest.
    // Measurement call order (interleaved, PR #1783 red): per attempt,
    // s,d,s,d,s,d,s,d,s,d — the doubled timed runs sit at calls
    // 2,4,6,8,10 within each attempt (3 spiked per attempt below).
    final sustained = ContendedClock(spiked: {2, 4, 6, 12, 14, 16, 22, 24, 26});
    expectLinearGrowth(
      asciiProse,
      100000,
      'ASCII prose',
      elapsedUs: sustained.call,
    );
    // Same layout guard as the preemption test above: the spiked indices
    // encode the measure loop's exact call layout (3 attempts × 2 sizes
    // × 5 timed runs).
    expect(
      sustained.calls,
      30,
      reason: 'the spiked indices encode the call layout',
    );
  });

  test('growth assertion survives contention covering every doubled block '
      '(PR #1783 validation red, run 39799009640)', () {
    // The #1635/gh-1732 harness red once more on the hostile-env leg
    // (best doubling ratio 3.24x at 500k cells — EVERY attempt's doubled
    // minimum was over the 3.2 bound, so the cross-attempt min could not
    // rescue it). The layout that lost: all 5 small runs then all 5
    // doubled runs per attempt put the doubled samples of the 3 attempts
    // into three contiguous ~150ms blocks — a contention phase spanning
    // them inflates every doubled run while the short small runs between
    // the blocks stay clean (exposure scales with run duration, the
    // #1635 mechanism, extended across attempts). Model the shape under
    // the pre-fix sequential call layout: every doubled timed run of
    // every attempt spiked (calls 6-10, 16-20, 26-30 — small runs at
    // 1-5, 11-15, 21-25 untouched).
    //
    // The fix interleaves the sizes (s,d,s,d,… per attempt): the same
    // contention phase now lands on 3-of-5 doubled AND 2-of-5 small runs
    // per attempt, both per-size minima keep 2 clean samples, and the
    // doubling ratio — which symmetric weather inflates far less than a
    // one-sided block — stays linear. spikeMs 12 on the ~3.5ms/7ms
    // baselines at 100k cells: pre-fix doubled min ≈ 19ms → ratio ≈ 5x
    // in every attempt (a louder stand-in for the live 3.24x); post-fix
    // both minima are clean ≈2x.
    final blocks = ContendedClock(
      spiked: {6, 7, 8, 9, 10, 16, 17, 18, 19, 20, 26, 27, 28, 29, 30},
      spikeMs: 12,
    );
    expectLinearGrowth(
      asciiProse,
      100000,
      'ASCII prose',
      elapsedUs: blocks.call,
    );
    // Same layout guard as the contention tests above: the spiked
    // indices encode the measure loop's exact call layout (3 attempts ×
    // 2 sizes × 5 timed runs). If that layout ever changes the spikes
    // silently land on the wrong measurements — this assertion turns
    // that into a loud failure.
    expect(
      blocks.calls,
      30,
      reason: 'the spiked indices encode the call layout',
    );
  });

  test('growth assertion rejects a degenerate flat measurement (gh-1532)', () {
    // AC2: the guard must stay meaningful. A constant clock makes every
    // doubling "take" the same time (ratio 1.0) — the pre-fix assertion
    // let that pass, asserting nothing. The meaningful-growth lower bound
    // must reject it.
    expect(
      () => expectLinearGrowth(
        asciiProse,
        100000,
        'ASCII prose',
        elapsedUs: (_) => 5000,
      ),
      throwsA(isA<TestFailure>()),
    );
  });
}
