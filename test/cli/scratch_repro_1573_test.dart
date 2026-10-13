import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

/// Scratch reproduction for gh-1573: final answer duplicated when a
/// service line ([btw] / job settle) lands mid-stream.
void main() {
  test('service line inserted mid-stream: answer appears exactly once', () {
    final tx = TranscriptMarkdown(width: 60);
    final src = <String>['user echo line'];

    // Stream the answer: a table streamed line-by-line (with newlines),
    // each flush = one more line.
    final answer = [
      '| col1 | col2 |',
      '| --- | --- |',
      '| гарде | 2 |',
      '| b | 3 |',
      '',
      'Issue 1: done',
      '2. Issue two text',
    ];
    for (var i = 0; i < answer.length; i++) {
      // A [btw] service notice lands after the SECOND streamed line.
      if (i == 2) {
        src.addAll(['[btw] mail from main → delivered', '']);
      }
      src.add(answer[i]);
      final out = tx.sync(src);
      // Every intermediate view must contain the answer text at most once.
      final joined = out.join('\n');
      final occurrences = 'гарде'.allMatches(joined).length;
      expect(occurrences, lessThanOrEqualTo(1), reason: 'step $i:\n$joined');
    }
    final out = tx.sync(src);
    final expected = AnsiMarkdown(width: 60).formatAll(src);
    expect(out.join('\n'), expected.join('\n'));
  });

  test('growing tail + service line + more growth: byte parity', () {
    final tx = TranscriptMarkdown(width: 60);
    final src = <String>['echo'];

    // Growing tail (no newline deltas).
    src.add('answer part one');
    tx.sync(src);
    src[src.length - 1] = 'answer part one grew';
    tx.sync(src);
    // Service line lands mid-stream.
    src.addAll(['[btw] scheduler fired', '']);
    tx.sync(src);
    // Answer continues — a fresh growing tail after the service block.
    src.add('continuation | табл | кол');
    tx.sync(src);
    src[src.length - 1] = 'continuation | табл | колонка';
    final out = tx.sync(src);
    final expected = AnsiMarkdown(width: 60).formatAll(src);
    expect(out.join('\n'), expected.join('\n'),
        reason: 'incremental must equal one-shot');
  });
}
