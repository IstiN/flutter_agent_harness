// Unit proof for the gh-1244 review thread: `FaCliHarness.waitForOutput`
// returns the accumulated buffer SILENTLY when its deadline expires
// without two consecutive stable polls, so a caller that asserts on the
// painted screen afterwards may read a mid-repaint frame (e.g. 13 of 15
// bullets) and fail spuriously on a loaded runner. The verified-settle
// contract (`requireSettledOutput`) demands a second byte-identical
// settle window and throws otherwise. Top-level and pure (like
// `frameContentLines`) so the never-settles case is provable without a
// PTY. Runs in the DEFAULT suite (no integration tag).
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('requireSettledOutput', () {
    test('two byte-identical settle windows verify quiescent', () {
      const settled = 'frame1\r\nframe2\r\n';
      expect(requireSettledOutput(settled, settled), settled);
    });

    test('two empty windows verify quiescent (nothing ever painted)', () {
      expect(requireSettledOutput('', ''), '');
    });

    test('a buffer that grew across the windows throws with a quiescence '
        'diagnosis', () {
      expect(
        () => requireSettledOutput('frame1\r\n', 'frame1\r\nframe2\r\n'),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('quiescence'),
          ),
        ),
      );
    });

    test('same length but different bytes still throws — the check is '
        'content, not length', () {
      // Cannot occur on the append-only PTY buffer, but a verifier that
      // only compared lengths would silently pass a swapped buffer.
      expect(
        () => requireSettledOutput('frame-A\r\n', 'frame-B\r\n'),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
