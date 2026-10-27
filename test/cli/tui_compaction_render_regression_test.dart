// Regression (issue #1755, ledger #13): the TUI transcript must keep
// thinking and answer text separate and untruncated across an
// auto-compaction. The compaction report wraps the LLM summary in a ```
// fence; a summary whose own fence lines are unbalanced used to leave the
// transcript formatter inside an open code fence, so every answer row
// after the report rendered verbatim (raw `**`, `#` headings) — the
// "garbled after auto-compaction" symptom. Root cause: `_formatFence`
// regex-tested the RAW line, so a fence line carrying SGR bytes (the
// report dims its fences at print time) failed `_fenceRe` and the fence
// state never latched. Fix origin: YuryBY's `fix/tui-compaction-summary-fence`
// (closed PR #1747, commit 7557efeeb) — re-landed here.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// The TUI transcript lines a run produced: a dimmed thinking row, the
/// answer, then the compaction report (split on newlines the way the output
/// history stores it), then the post-compaction answer. The report's ```
/// lines carry the dim SGR the printer bakes in (`agent_cli_compaction.dart`
/// prints `line == '```' ? _style.dim(line) : line`).
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
    for (final line in formatCompactionReport(pass, auto: true, details: true))
      ...line.split('\n').map((p) => p == '```' ? '\x1b[2m```\x1b[0m' : p),
    'Answer **after** compaction',
    '# Heading after',
  ];
}

void main() {
  group('TUI transcript across auto-compaction (issue #1755)', () {
    test(
      'a summary with unbalanced ``` fences does not swallow the rows after it',
      () {
        final tx = TranscriptMarkdown(width: 80)
          ..sync(_transcript('Goal.\n```py\nprint(1)'));
        final rows = tx.wrappedRows.map((r) => r.replaceAll('\x1b', 'E'));
        // AC1: the post-compaction answer renders as markdown (bold SGR),
        // not as verbatim code with the raw `**` markers.
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

    test(
      'styled fence lines still latch fences without double-styling (AC2)',
      () {
        final md = AnsiMarkdown();
        final styled = '\x1b[2m```\x1b[0m';
        // A fence line carrying SGR bytes is recognized as a fence (state
        // latches) and passes through byte-identically — the renderer must
        // not stack a second dim pair on stored styling.
        expect(md.formatLine(styled), styled);
        // The latch is real: the next line renders as verbatim fence body.
        expect(md.formatLine('final **x** = 1;'), '  final **x** = 1;');
        // Plain fence lines still dim-wrap as before and close the state.
        final plainClose = md.formatLine('```');
        expect(plainClose, isNot('```'));
        expect(plainClose, contains('```'));
        expect(plainClose, contains('\x1b['));
        // Outside the fence markdown works again.
        expect(md.formatLine('a **b**'), contains('\x1b[1mb\x1b[0m'));
      },
    );

    test('balanced-fence transcripts render byte-identically (AC3 REG)', () {
      // AC3: a summary whose fences already pair — formatCompactionReport
      // returns it UNCHANGED (no fence appended) and the styled-fence rows
      // pass through byte-exact. Golden captured from the actual renderer.
      final tx = TranscriptMarkdown(width: 80)
        ..sync(_transcript('Goal.\n```py\nprint(1)\n```'));
      expect(tx.wrappedRows, [
        '\x1b[2mthinking about the plan\x1b[0m',
        'Answer \x1b[1mbefore\x1b[0m compaction',
        'auto-compacted · structured',
        'tokens: 104717 → 43430 (61287 freed · 59%)',
        'records: 12 hidden · 9 summarized',
        'summary:',
        '\x1b[2m```\x1b[0m',
        '  Goal.',
        '\x1b[2m```py\x1b[0m',
        'print(1)',
        '\x1b[2m```\x1b[0m',
        '\x1b[2m```\x1b[0m',
        'Answer \x1b[1mafter\x1b[0m compaction',
        '\x1b[38;2;129;140;248m\x1b[1m\x1b[4mHeading after\x1b[0m',
      ]);
    });

    test(
      'plain balanced fences render byte-identically (AC3 REG, renderer)',
      () {
        // The historically-working path the fix must not disturb: fence
        // lines stored WITHOUT styling toggle exactly as before. Literal
        // lines (no report formatter) so only the renderer is under test.
        final tx = TranscriptMarkdown(width: 80)
          ..sync([
            'Answer **before** compaction',
            'summary:',
            '```',
            'Goal.',
            '```py',
            'print(1)',
            '```',
            '```',
            'Answer **after** compaction',
            '# Heading after',
          ]);
        expect(tx.wrappedRows, [
          'Answer \x1b[1mbefore\x1b[0m compaction',
          'summary:',
          '\x1b[2m```\x1b[0m',
          '  Goal.',
          '\x1b[2m```py\x1b[0m',
          'print(1)',
          '\x1b[2m```\x1b[0m',
          '\x1b[2m```\x1b[0m',
          'Answer \x1b[1mafter\x1b[0m compaction',
          '\x1b[38;2;129;140;248m\x1b[1m\x1b[4mHeading after\x1b[0m',
        ]);
      },
    );
  });
}
