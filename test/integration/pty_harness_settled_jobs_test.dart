// Unit proof for the background-shell-job settle proof set
// (`settledJobNumbers`, the drained-wait predicate behind the #573-review
// countdown suite) — top-level and pure so the predicate is provable
// without a PTY (same convention as `maskedValueRow` / `pollUntil`). Runs
// in the DEFAULT suite (no integration tag).
//
// Regression (CI 2026-10-06, tag v1.0.520, PTY/CLI integration shard 2/3 —
// issue #1337): the drained wait was a silence settle
// (`waitForOutput(settleMs: 500)` returns on ~1 s of raw-stream quiet)
// while the scenario staggers its ten sleeps exactly 1 s apart — a
// stretched inter-notice gap satisfied the silence rule and returned the
// capture mid-drain with only {1..7} settled. The wait now polls
// `settledJobNumbers(raw).length == 10`, so the predicate itself is the
// load-bearing logic pinned here.
@TestOn('vm')
library;

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('settledJobNumbers', () {
    test('one distinct number per settle notice; repaint re-emits do not '
        'inflate the set', () {
      final raw = [
        for (var i = 1; i <= 10; i++) '[bash] sh-$i-abc$i exited(0)',
        // A frame repaint re-emits already-counted notices into the raw
        // stream — the proof is the DISTINCT set, not the match count.
        '[bash] sh-3-abc3 exited(0)',
        '[bash] sh-10-abc10 exited(0)',
      ].join('\n');

      expect(settledJobNumbers(raw), {for (var i = 1; i <= 10; i++) '$i'});
    });

    test('a mid-id fragmentation (CI-load cursor escapes) still counts by '
        'number prefix', () {
      const raw = '[bash] sh-10-…xqo\x1b[11;29H5\x1b[11;31H exited(0)';
      expect(settledJobNumbers(raw), {'10'});
    });

    test('the drained-wait predicate rejects a truncated capture (the '
        'v1.0.520 {1..7} shape) and accepts only the full set', () {
      String notices(int from, int to) => [
        for (var i = from; i <= to; i++) '[bash] sh-$i-abc$i exited(0)',
      ].join('\n');
      bool settled(String raw) => settledJobNumbers(raw).length == 10;

      expect(settled(notices(1, 7)), isFalse, reason: 'jobs 8-10 unlanded');
      expect(settled(notices(1, 9)), isFalse, reason: 'job 10 unlanded');
      expect(settled(notices(1, 10)), isTrue);
    });
  });
}
