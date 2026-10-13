import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// gh-1573 differential: incremental TranscriptMarkdown syncs must equal
/// the one-shot pass at EVERY prefix while service lines ([btw] notices,
/// job rows) interleave with a streaming answer.
void main() {
  test('differential: service insertions during answer streaming', () {
    final src = <String>['user echo'];
    final tx = TranscriptMarkdown(width: 60);
    tx.sync(src);

    var step = 0;
    void check(String note) {
      step++;
      final out = tx.sync(src);
      final expected = AnsiMarkdown(width: 60).formatAll(src);
      expect(
        out,
        expected,
        reason: 'step $step ($note): incremental != one-shot\n'
            '--- incremental ---\n${out.join('\n')}\n'
            '--- one-shot ---\n${expected.join('\n')}',
      );
    }

    // 1. Answer streams as a growing tail (no newline yet).
    src.add('Ответ с таблицей:');
    check('growing tail start');
    src[src.length - 1] = 'Ответ с таблицей: гарде';
    check('tail grew');

    // 2. Answer line completes; a [btw] notice lands.
    src[src.length - 1] = 'Ответ с таблицей: гарде и хвост';
    check('tail grew more');
    src[src.length - 1] = '$src.last\n';
    src.removeLast(); // newline splits: keep as line then empty
    src.addAll(['', '> ⚙ [btw] mail delivered', '']);
    check('btw inserted');

    // 3. A table streams after the notice.
    for (final line in [
      '| кол1 | кол2 |',
      '| --- | --- |',
      '| гарде | 2 |',
    ]) {
      src.add(line);
      check('table row $line');
    }

    // 4. A job-settle system notice lands while the table is OPEN.
    src.addAll(['<system-notice>', 'job sh-3 finished', '</system-notice>', '']);
    check('job notice mid-open-table');

    // 5. Table continues and closes; prose follows.
    src.addAll(['| b | 3 |', '', '2. Issue two text', '3. Issue three']);
    check('close + prose');

    // 6. Growing tail again (prose without newline).
    src[src.length - 1] = '${src.last} continued';
    check('final tail');
  });

  test('differential: growing tail rolled back with pending open table', () {
    // The commit edge stops before an open table; the LAST line grows
    // without newline INSIDE the open-table span while a service line
    // sits between the committed edge and the tail.
    final src = <String>['echo', 'before'];
    final tx = TranscriptMarkdown(width: 40);
    tx.sync(src);

    var step = 0;
    void check(String note) {
      step++;
      final out = tx.sync(src);
      final expected = AnsiMarkdown(width: 40).formatAll(src);
      expect(out, expected, reason: 'step $step ($note)');
    }

    src.add('| a | b |');
    check('open table row 1');
    src.add('| 1 | 2 |');
    check('open table row 2');
    // Growing tail inside the open-table span.
    src.add('гарде');
    check('tail in open table');
    src[src.length - 1] = 'гарде2';
    check('tail grew in open table');
    src[src.length - 1] = 'гарде2. Issue';
    check('tail glued issue');
    // Table closes via a blank line.
    src[src.length - 1] = '$src.last\n';
    src.removeLast();
    src.addAll(['', 'after']);
    check('table closed');
  });
}
