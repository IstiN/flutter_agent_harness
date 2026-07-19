import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('xxHash32', () {
    // Reference vectors: spec values for short inputs, cross-checked against
    // an independent from-spec implementation for the rest. Lengths cover
    // every code path: empty, <16, exactly 16 (stripe boundary), and >16.
    final specVectors = <String, int>{
      '': 0x02CC5D05,
      'a': 0x550D7456,
      'abc': 0x32D153FF,
      'abcd': 0xA3643705,
      'test': 1042293711,
      'hello world': 3468387874,
      '0123456789abcde': 498989583,
      '0123456789abcdef': 3267648361,
      'abcdefghijklmnopqrstuvwxyz': 1671515487,
      'The quick brown fox jumps over the lazy dog': 3898516702,
    };

    specVectors.forEach((input, expected) {
      test('xxh32(${jsonEncode(input)}) matches the reference value', () {
        expect(xxHash32(utf8.encode(input)), expected);
      });
    });

    test('hashes bytes, not characters (UTF-8 input)', () {
      // A non-ASCII string must hash its UTF-8 encoding.
      final hash = xxHash32(utf8.encode('héllo'));
      expect(hash, isNot(xxHash32(utf8.encode('hello'))));
    });

    test('seed changes the result', () {
      final data = utf8.encode('abc');
      expect(xxHash32(data, 1), isNot(xxHash32(data)));
    });
  });

  group('computeFileHash', () {
    // Ground truth from oh-my-pi's own test suite (snapshots.test.ts, issue
    // #4075): under Bun.hash.xxHash32 both texts tag as `1D84`. This pins the
    // whole pipeline — normalization, UTF-8 encoding, xxHash32 seed 0, low 16
    // bits, uppercase hex — to omp behavior.
    test('matches Bun ground-truth collision pair', () {
      expect(computeFileHash('line one 263\nline two 4471\n'), '1D84');
      expect(computeFileHash('line one 410\nline two 6970\n'), '1D84');
    });

    test('is a 4-character uppercase hex tag', () {
      for (final text in ['', 'x', 'foo\nbar\n', 'a' * 1000]) {
        expect(computeFileHash(text), matches(RegExp(r'^[0-9A-F]{4}$')));
      }
    });

    test('ignores trailing spaces, tabs, and CR line endings', () {
      final base = computeFileHash('foo\nbar\n');
      expect(computeFileHash('foo  \nbar\t\n'), base);
      expect(computeFileHash('foo\r\nbar\r\n'), base);
      expect(computeFileHash('foo \t \nbar\n'), base);
    });

    test('is content-sensitive', () {
      expect(
        computeFileHash('foo\nbar\n'),
        isNot(computeFileHash('foo\nbaz\n')),
      );
      expect(computeFileHash('foo\nbar'), isNot(computeFileHash('foo\nbar\n')));
    });
  });

  group('format helpers', () {
    test('formatHashlineHeader', () {
      expect(formatHashlineHeader('a/b.ts', '1A2B'), '[a/b.ts#1A2B]');
    });

    test('formatNumberedLine(s)', () {
      expect(formatNumberedLine(3, 'x'), '3:x');
      expect(formatNumberedLines('a\nb', 5), '5:a\n6:b');
    });

    test('describeAnchorExamples', () {
      expect(describeAnchorExamples(), '"160", "42", "7"');
      expect(describeAnchorExamples('119'), '"119", "112", "7"');
      expect(describeAnchorExamples('1'), '"1", "42", "7"');
    });
  });
}
