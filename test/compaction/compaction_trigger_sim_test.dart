// gh-2098 rework — the standalone bench sim's numeric CLI guard.
//
// The review NIT: the `--window`/`--scale` loop used bare `int.parse` /
// `double.parse`, so junk numerics (`--window abc`) died with an uncaught
// FormatException (stack trace, exit 255) instead of the usage message +
// exit 2 every other input mistake gets (missing file, empty curve), and
// a trailing `--window` with no value was silently skipped (exit 0, the
// defaults ran). The sim now tryParses its numerics and answers every
// bad flag with the usage line + exit 2.
//
// Runs the REAL script (`dart bench/compaction_trigger_sim.dart ...`)
// over a tiny recorded-session fixture — the run-the-enforcing-script
// pattern of test/ci_2030_extension_size_floor_test.dart (the guard
// cannot rot between static-gate runs).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  const usage = 'usage: dart bench/compaction_trigger_sim.dart';

  /// A 3-request recorded curve (observed context 10k → 30k tokens),
  /// enough for the sim to report fire points on any window below them.
  File fixture(Directory dir) {
    final file = File('${dir.path}/session.jsonl');
    file.writeAsStringSync(
      [
        '{"type":"message","message":{"usage":{"input":10000,"cacheRead":0}}}',
        '{"type":"message","message":{"usage":{"input":15000,"cacheRead":5000}}}',
        '{"type":"message","message":{"usage":{"input":25000,"cacheRead":5000}}}',
      ].join('\n'),
    );
    return file;
  }

  ProcessResult runSim(List<String> args) => Process.runSync(
    'dart',
    ['bench/compaction_trigger_sim.dart', ...args],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  void expectUsage(ProcessResult r, String flag, String value) {
    expect(r.exitCode, 2, reason: '$flag $value');
    expect(r.stderr, contains(usage), reason: '$flag $value');
    expect(
      r.stderr,
      isNot(contains('FormatException')),
      reason: '$flag $value',
    );
    expect(r.stdout, isEmpty, reason: '$flag $value');
  }

  group('bench/compaction_trigger_sim.dart numeric args', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('trigger-sim-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('junk --window gets the usage line + exit 2, not a stack trace', () {
      final r = runSim([fixture(dir).path, '--window', 'abc']);
      expectUsage(r, '--window', 'abc');
    });

    test('junk --scale gets the usage line + exit 2, not a stack trace', () {
      final r = runSim([fixture(dir).path, '--scale', 'junk']);
      expectUsage(r, '--scale', 'junk');
    });

    test('a trailing flag with no value gets the usage line, not a '
        'silent skip', () {
      // `--window` as the LAST arg: the old `i < args.length - 1` loop
      // never visited it — the defaults ran with exit 0.
      final r = runSim([fixture(dir).path, '--window']);
      expectUsage(r, '--window', '(no value)');
      final s = runSim([fixture(dir).path, '--scale']);
      expectUsage(s, '--scale', '(no value)');
    });

    test('junk numerics do not run the curve (no partial output)', () {
      final r = runSim([
        fixture(dir).path,
        '--window',
        '128000',
        '--window',
        'abc',
      ]);
      expectUsage(r, '--window', 'abc after a valid 128000');
    });

    test('valid args still run the curve (exit 0, fire points reported)', () {
      final r = runSim([
        fixture(dir).path,
        '--window',
        '20000',
        '--scale',
        '2',
      ]);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('window 20000'));
      expect(r.stdout, contains('0.75'));
    });
  });
}
