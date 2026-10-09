// AC7 / IT-7 (gh-1241): the segment-close `fa-tokens:` log line matches
// the documented format and the PINNED reporter regex.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  UsageSegment segment({
    UsageSource source = UsageSource.reported,
    String? model,
  }) => UsageSegment(
    index: 2,
    totals: const UsageModelTotals(
      requests: 58,
      input: 722300,
      output: 17600,
      cacheRead: 421100,
    ),
    byModel: const {'model-a': UsageModelTotals(requests: 58, input: 1)},
    source: source,
    model: model,
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

    group('gh-1460: model attribution', () {
      test('a segment with a model emits it right after "segment"', () {
        final line = usageTokensLogLine(
          sessionId: 'gh-1460',
          segment: segment(model: 'anthropic/claude-sonnet-4-5'),
        );
        expect(
          line,
          'fa-tokens: {"sessionId":"gh-1460","segment":2,'
          '"model":"anthropic/claude-sonnet-4-5","input":722300,'
          '"output":17600,"cacheRead":421100,"requests":58,'
          '"source":"reported"}',
        );
      });

      test('the pinned regex matches the new shape for every source', () {
        for (final source in UsageSource.values) {
          final line = usageTokensLogLine(
            sessionId: 's-1',
            segment: segment(source: source, model: 'openai/gpt-5.2'),
          );
          expect(
            usageTokensLogPattern.hasMatch(line),
            isTrue,
            reason: source.name,
          );
        }
      });

      test('a segment without a known model keeps the legacy shape (AC2)', () {
        final line = usageTokensLogLine(sessionId: 's-1', segment: segment());
        expect(line, isNot(contains('"model"')));
        expect(usageTokensLogPattern.hasMatch(line), isTrue);
      });

      test('the optional group stays position-strict', () {
        // A model key in any other slot must NOT parse: the pinned shape is
        // the reporter's contract, and a drifted placement means a drifted
        // writer.
        expect(
          usageTokensLogPattern.hasMatch(
            'fa-tokens: {"sessionId":"s","segment":1,"input":1,"model":"m",'
            '"output":1,"cacheRead":0,"requests":1,"source":"reported"}',
          ),
          isFalse,
        );
      });
    });
  });
}
