import 'package:flutter_agent_harness/src/cli/system_notice_render.dart';
import 'package:test/test.dart';

void main() {
  test('notice blocks become dim quote lines; plain text untouched', () {
    expect(renderSystemNoticeLines('hello'), ['hello']);
    expect(
      renderSystemNoticeLines(
        '<system-notice>\nJob sh-1 finished (exit 0)\n</system-notice>',
      ),
      ['> ⚙ Job sh-1 finished (exit 0)'],
    );
    expect(
      renderSystemNoticeLines(
        'before\n<system-notice>mail arrived</system-notice>\nafter',
      ),
      ['before', '> ⚙ mail arrived', 'after'],
    );
    // Unterminated block (one-write notices always close, but stay safe).
    expect(renderSystemNoticeLines('<system-notice>still open'), [
      '> ⚙ still open',
    ]);
  });

  test('task-result blocks and service receipts get the same treatment', () {
    expect(
      renderSystemNoticeLines(
        '<task-result id="a">\nmemory tools wired\n</task-result>',
      ),
      ['> ⚙ memory tools wired'],
    );
    // Issue #276: the report block header replaced the bracketed
    // receipts — the quote treatment follows the header line.
    expect(renderSystemNoticeLines('● compacted · smol'), [
      '> ⚙ ● compacted · smol',
    ]);
    expect(renderSystemNoticeLines('● auto-compacted'), [
      '> ⚙ ● auto-compacted',
    ]);
    expect(
      renderSystemNoticeLines(
        '[context trimmed] 1000 → 200 tokens (summarizer unavailable)',
      ),
      ['> ⚙ [context trimmed] 1000 → 200 tokens (summarizer unavailable)'],
    );
  });

  test('needsSystemNoticeRewrite gates the TUI output path', () {
    expect(needsSystemNoticeRewrite('plain user text'), isFalse);
    expect(
      needsSystemNoticeRewrite('<system-notice>x</system-notice>'),
      isTrue,
    );
    // The styled header still matches — the ANSI styling rides inside
    // the line, the marker stays greppable.
    expect(needsSystemNoticeRewrite('● auto-compacted · smol'), isTrue);
  });
}
