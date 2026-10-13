import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

/// Scratch: gh-1573 scenario at the model level — final answer streamed
/// while a job row + [btw] service notices land mid-stream.
void main() {
  test('gh-1573: answer rendered exactly once', () {
    var model = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (line, {images = const []}) async {},
        buildSlashMenu: (prefix) => const [],
        buildModelMenu: (filter, _) => const [],
        onModelSelected: (id) async {},
        statusLine: () => 'status',
        prompt: 'fa> ',
      ),
      isExited: () => false,
      termWidth: 100,
      termHeight: 40,
    );

    FaTuiModel pump(FaTuiModel m, Msg msg) =>
        m.update(msg).$1 as FaTuiModel;

    // Submit a prompt (echo lands in the transcript).
    for (final ch in 'do the thing'.split('')) {
      model = pump(
        model,
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
      );
    }
    model = pump(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));

    // Busy on.
    model = pump(model, const BusyMsg(true, source: 'run'));

    // Stream an answer with a table, one OutputMsg per line.
    final answerLines = [
      '| col1 | col2 |',
      '| --- | --- |',
      '| гарде | 2 |',
      '| b | 3 |',
      '',
      'Issue 1: fixed',
      '2. Issue two remains',
      '3. Issue three tracked',
    ];
    final buffer = StringBuffer();
    for (final line in answerLines) {
      final delta = '$line\n';
      buffer.write(delta);
      model = pump(model, OutputMsg(delta, newline: true));
      // Mid-stream service traffic after the table row: a settled job row
      // and a [btw] notice — the ticket's trigger.
      if (line == '| b | 3 |') {
        model = pump(
          model,
          JobBoardMsg(
            const ['sh-3-a1b2 · exit 1 · log: .fah/bash_jobs/sh-3-a1b2.log'],
          ),
        );
        const notice = '<system-notice>\n'
            '[btw] mail from main → delivered\n'
            '</system-notice>\n';
        model = pump(model, OutputMsg(notice, newline: true));
      }
    }

    model = pump(model, const BusyMsg(false));
    final view = model.view();
    final content = view.content;
    final plain = content.replaceAll(RegExp('\x1b\\[[0-9;]*m'), '');
    final garde = 'гарде'.allMatches(plain).length;
    final issue2 = '2. Issue two'.allMatches(plain).length;
    // ignore: avoid_print
    print('=== FRAME (40 rows x 100 cols) ===');
    // ignore: avoid_print
    print(plain);
    // ignore: avoid_print
    print('=== occurrences: гарде=$garde 2.Issue=$issue2 ===');
    expect(garde, 1, reason: 'table cell exactly once on the glass');
    expect(issue2, 1, reason: 'list item exactly once on the glass');
  });
}
