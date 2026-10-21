// Regression (ledger #13): the TUI transcript must keep thinking and answer
// text separate and untruncated across an auto-compaction. The compaction
// report wraps the LLM summary in a ``` fence; a summary whose own fence
// lines are unbalanced used to leave the transcript formatter inside an open
// code fence, so every answer row after the report rendered verbatim
// (raw `**`, `#` headings) — the "garbled after auto-compaction" symptom.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// The TUI transcript lines a run produced: a dimmed thinking row, the
/// answer, then the compaction report (split on newlines the way the output
/// history stores it), then the post-compaction answer.
List<String> _transcript(String summary) {
  final pass = AutoCompactorPass(
    pass: 1,
    tokensBefore: 104717,
    tokensAfter: 43430,
    fallback: 'structured',
    ok: true,
    summary: summary,
    hiddenRecords: 12,
    summarizedMessages: 9,
  );
  return [
    '\x1b[2mthinking about the plan\x1b[0m',
    'Answer **before** compaction',
    for (final line in formatCompactionReport(pass, auto: true))
      ...line.split('\n').map((p) => p == '```' ? '\x1b[2m```\x1b[0m' : p),
    'Answer **after** compaction',
    '# Heading after',
  ];
}

void main() {
  group('TUI transcript across auto-compaction (ledger #13)', () {
    test(
      'a summary with unbalanced ``` fences does not swallow the rows after it',
      () {
        final tx = TranscriptMarkdown(width: 80)
          ..sync(_transcript('Goal.\n```py\nprint(1)'));
        final rows = tx.wrappedRows.map((r) => r.replaceAll('\x1b', 'E'));
        // The post-compaction answer renders as markdown (bold SGR), not as
        // verbatim code with the raw `**` markers.
        expect(
          rows.any((r) => r.contains('E[1m') && r.contains('after')),
          isTrue,
          reason: rows.join('\n'),
        );
        expect(rows.any((r) => r.contains('**after**')), isFalse);
        expect(rows.any((r) => r.contains('# Heading after')), isFalse);
      },
    );

    test('thinking rows and the answer stay on separate rows', () {
      final tx = TranscriptMarkdown(width: 80)
        ..sync(_transcript('Goal.\n```py\nprint(1)'));
      final rows = tx.wrappedRows;
      final thinking = rows.indexWhere((r) => r.contains('thinking about'));
      final answer = rows.indexWhere((r) => r.contains('before'));
      expect(thinking, isNonNegative);
      expect(answer, greaterThan(thinking));
      expect(
        rows[answer].contains('thinking about'),
        isFalse,
        reason: rows.join('\n'),
      );
    });
  });
}
