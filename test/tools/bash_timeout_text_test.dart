// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1444 UT-timeout-text (AC5): the bash timeout renderer tells the truth —
// the model's cap when passed, the shell's effective cap when the model
// passed none, and NEVER the "unknown seconds" lie or the "uncaught
// exception" mislabel.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('timeoutSecondsFromMessage', () {
    test('parses the shell timeout shape (H:MM:SS)', () {
      expect(timeoutSecondsFromMessage('timeout: 0:00:30'), 30);
      expect(timeoutSecondsFromMessage('timeout: 0:02:00'), 120);
      expect(timeoutSecondsFromMessage('ExecError: timeout: 0:01:05.123'), 65);
    });

    test('sub-second caps round up to 1', () {
      expect(timeoutSecondsFromMessage('timeout: 0:00:00.500'), 1);
    });

    test('returns null for messages without a duration', () {
      expect(timeoutSecondsFromMessage('aborted'), isNull);
      expect(timeoutSecondsFromMessage(''), isNull);
    });
  });

  group('bashTimeoutStatus', () {
    test('the model cap wins verbatim', () {
      expect(
        bashTimeoutStatus(timeoutArg: 45),
        'Command timed out after 45 seconds',
      );
      expect(
        bashTimeoutStatus(timeoutArg: 0.5),
        'Command timed out after 0.5 seconds',
      );
    });

    test('a shell default parses from the exec error message', () {
      expect(
        bashTimeoutStatus(
          errorMessage: 'timeout: 0:00:30',
        ),
        'Command timed out after 30 seconds',
      );
    });

    test('a job-recorded effective timeout renders its seconds', () {
      expect(
        bashTimeoutStatus(effectiveTimeout: const Duration(minutes: 2)),
        'Command timed out after 120 seconds',
      );
    });

    test('no recoverable cap states the timeout without a number', () {
      final text = bashTimeoutStatus();
      expect(text, 'Command timed out');
      expect(text.contains('unknown'), isFalse);
    });

    test('never renders the forbidden strings (AC5)', () {
      for (final text in [
        bashTimeoutStatus(),
        bashTimeoutStatus(errorMessage: 'weird shape'),
        bashTimeoutStatus(timeoutArg: null, effectiveTimeout: Duration.zero),
      ]) {
        expect(text.contains('unknown seconds'), isFalse);
        expect(text.contains('uncaught exception'), isFalse);
      }
    });
  });
}
