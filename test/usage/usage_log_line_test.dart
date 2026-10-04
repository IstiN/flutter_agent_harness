// AC7 / IT-7 (gh-1241): the segment-close `fa-tokens:` log line matches
// the documented format and the PINNED reporter regex.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  UsageSegment segment({UsageSource source = UsageSource.reported}) =>
      UsageSegment(
        index: 2,
        totals: const UsageModelTotals(
          requests: 58,
          input: 722300,
          output: 17600,
          cacheRead: 421100,
        ),
        byModel: const {'model-a': UsageModelTotals(requests: 58, input: 1)},
        source: source,
      );

  group('usageTokensLogLine', () {
    test('matches the documented example shape exactly', () {
      final line = usageTokensLogLine(sessionId: 'gh-1164', segment: segment());
      expect(
        line,
        'fa-tokens: {"sessionId":"gh-1164","segment":2,"input":722300,'
        '"output":17600,"cacheRead":421100,"requests":58,"source":"reported"}',
      );
    });

    test('parses with the pinned reporter regex (the IT-7 fixture)', () {
      for (final source in UsageSource.values) {
        final line = usageTokensLogLine(
          sessionId: 's-1',
          segment: segment(source: source),
        );
        expect(
          usageTokensLogPattern.hasMatch(line),
          isTrue,
          reason: source.name,
        );
      }
    });

    test('a greppable prefix precedes compact single-line JSON', () {
      final line = usageTokensLogLine(sessionId: 's-1', segment: segment());
      expect(line.startsWith(usageTokensLogPrefix), isTrue);
      expect(line.contains('\n'), isFalse);
    });

    test('the pinned regex rejects malformed lines', () {
      expect(
        usageTokensLogPattern.hasMatch(
          'fa-tokens: {"sessionId":"s","segment":1,"input":1,"output":1,'
          '"cacheRead":0,"requests":1,"source":"unknown-source"}',
        ),
        isFalse,
      );
      expect(usageTokensLogPattern.hasMatch('fa-tokens: not json'), isFalse);
      expect(usageTokensLogPattern.hasMatch('other: {}'), isFalse);
    });
  });
}
