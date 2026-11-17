// gh-2237 REG-1 — unit tests for the start-without-terminal-receipt
// signature detector (see lib/src/compaction/receipt_scan.dart).

library;

import 'package:flutter_agent_harness/src/compaction/receipt_scan.dart';
import 'package:test/test.dart';

void main() {
  group('compactionStartWithoutTerminalReceipt', () {
    test('the field signature (six starts, zero terminals) fires', () {
      const lines = [
        '19:17:31 auto-compact start sid=01a1ddb2 tokens=378745',
        '19:20:12 auto-compact start sid=01a1ddb2 tokens=381902',
        '19:23:02 auto-compact start sid=01a1ddb2 tokens=387654',
        '19:26:44 auto-compact start sid=01a1ddb2 tokens=391203',
        '19:30:58 auto-compact start sid=01a1ddb2 tokens=397110',
        '19:34:41 auto-compact start sid=01a1ddb2 tokens=402619',
      ];
      expect(compactionStartWithoutTerminalReceipt(lines), isTrue);
    });

    test('healthy runs: every start is closed by a terminal receipt', () {
      const lines = [
        'auto-compact start sid=a tokens=40000',
        'auto-compact pass 1 sid=a tokens 40000→8000 ok=true',
        'auto-compact done sid=a passes=1 tokens=8000',
        'auto-compact start sid=a tokens=9500',
        'auto-compact done sid=a passes=1 tokens=3000',
      ];
      expect(compactionStartWithoutTerminalReceipt(lines), isFalse);
    });

    test('the fixed zero-pass shape: done passes=0 closes the start', () {
      const lines = [
        'auto-compact start sid=a tokens=49320',
        'auto-compact done sid=a passes=0 '
            '(no-op: basis 49320 below trigger 37500 at the run gate)',
        'auto-compact start sid=a tokens=49320',
        'auto-compact done sid=a passes=0 '
            '(no-op: basis 49320 below trigger 37500 at the run gate)',
      ];
      expect(compactionStartWithoutTerminalReceipt(lines), isFalse);
    });

    test('a pass receipt between starts counts as intervening speech', () {
      const lines = [
        'auto-compact start sid=a tokens=40000',
        'auto-compact pass 1 FAILED sid=a tokens 40000→40000 error=x',
        'auto-compact start sid=a tokens=40000',
        'auto-compact pass 1 no-op sid=a',
        'auto-compact start sid=a tokens=40000',
        'compact retry sid=a attempt=1/3 backoff=2s error=y',
        'auto-compact start sid=a tokens=40000',
        'auto-compact pass 1 local-trim sid=a tokens 40000→2000',
      ];
      expect(compactionStartWithoutTerminalReceipt(lines), isFalse);
    });

    test('a trailing start at end-of-log fires (silence is the defect)', () {
      const lines = [
        'auto-compact start sid=a tokens=40000',
        'auto-compact done sid=a passes=1 tokens=8000',
        'auto-compact start sid=a tokens=9500',
      ];
      expect(compactionStartWithoutTerminalReceipt(lines), isTrue);
    });

    test('no starts — nothing to flag', () {
      const lines = ['run start sid=a', 'run end sid=a'];
      expect(compactionStartWithoutTerminalReceipt(lines), isFalse);
      expect(compactionStartWithoutTerminalReceipt(const <String>[]), isFalse);
    });

    test('unrelated lines between a start and its done do not close it', () {
      const lines = [
        'auto-compact start sid=a tokens=40000',
        'run end sid=a',
        'some other diagnostic',
        'auto-compact start sid=a tokens=41000',
      ];
      expect(compactionStartWithoutTerminalReceipt(lines), isTrue);
    });
  });
}
