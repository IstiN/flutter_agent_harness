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
    expect(
      renderSystemNoticeLines('<system-notice>still open'),
      ['> ⚙ still open'],
    );
  });
}
