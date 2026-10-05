// Unit proof for the deadline-poll engine (`pollUntil`) behind
// `waitForText`/`waitForScreen` — top-level and pure so the timing
// semantics are provable without a PTY (same convention as
// `maskedValueRow` / `frameContentLines`). Runs in the DEFAULT suite
// (no integration tag).
//
// Regression (CI 2026-10-05, PTY/CLI integration shard 2/3 on pr-1255):
// `Fa CLI integration boot shows banner and status line` threw
// `TimeoutException after 0:01:30: Timed out waiting for "[Model]"` while
// the exception's own `--- screen ---` dump CONTAINED `[Model]` — the boot
// frame painted during the final 50 ms poll sleep, after the last
// `matched` check but before the throw. A match that lands in that
// post-deadline window must return, not throw.
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('pollUntil', () {
    test('a match landing between the last poll and the deadline returns '
        'instead of throwing (CI 2026-10-05 fa_cli boot regression)', () async {
      // Fully injected clock: `delay` advances fake time, no real sleeping.
      var t = DateTime(2026, 10, 5, 15, 50, 56);
      const timeout = Duration(seconds: 90);
      final deadline = t.add(timeout);
      const marker = '[Model]';
      // The screen only carries the marker once the deadline has passed —
      // exactly the CI shape: the banner painted inside the final poll
      // interval, after the last in-loop check.
      String screen() =>
          t.isBefore(deadline) ? 'booting...' : '$marker\n  test-model';
      var polls = 0;

      final output = await pollUntil(
        matched: () {
          polls++;
          return screen().contains(marker);
        },
        onHit: () => 'raw-output',
        screenText: screen,
        rawTail: () => 'raw-tail',
        what: '"$marker" in output',
        timeout: timeout,
        pollInterval: const Duration(milliseconds: 50),
        now: () => t,
        delay: (d) async {
          t = t.add(d);
        },
      );

      expect(output, 'raw-output');
      // The regression is precisely about the post-deadline window: the
      // clock must have run past the deadline, and the marker must be on
      // screen at the moment the old code threw.
      expect(t.isBefore(deadline), isFalse);
      expect(screen(), contains(marker));
      expect(polls, greaterThan(0));
    });

    test(
      'a genuine timeout still throws with the screen and raw-tail dump',
      () async {
        var t = DateTime(2026, 10, 5, 15, 50, 56);
        const timeout = Duration(milliseconds: 500);

        await expectLater(
          pollUntil(
            matched: () => false,
            onHit: () => 'raw-output',
            screenText: () => 'nothing here',
            rawTail: () => 'tail-bytes',
            what: '"[Model]" in output',
            timeout: timeout,
            pollInterval: const Duration(milliseconds: 50),
            now: () => t,
            delay: (d) async {
              t = t.add(d);
            },
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Timed out waiting for "[Model]" in output'),
                contains('nothing here'),
                contains('tail-bytes'),
              ),
            ),
          ),
        );
      },
    );

    test('waitForScreen semantics: onHit returns the snapshot that matched, '
        'not a re-read', () async {
      var t = DateTime(2026, 10, 5, 15, 50, 56);
      var frame = 'partial';
      String screen() => frame;
      // waitForScreen's anchoring shape: capture the snapshot INSIDE
      // matched, return the capture from onHit (gh-1049).
      var hit = '';

      final anchored = await pollUntil(
        matched: () {
          hit = screen();
          return hit.contains('done');
        },
        onHit: () => hit,
        screenText: screen,
        rawTail: () => '',
        what: '"done" on screen',
        timeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 50),
        now: () => t,
        delay: (d) async {
          t = t.add(d);
          frame = 'done';
        },
      );
      expect(anchored, 'done');

      // The screen drifts after the match — the anchor must not.
      frame = 'done + drifted';
      expect(anchored, 'done');
    });
  });
}
