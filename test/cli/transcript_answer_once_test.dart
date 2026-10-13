import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

/// gh-1573 regression: the final assistant answer must render EXACTLY
/// ONCE while the transcript commits it under live service traffic.
///
/// The reported shape: a table-bearing answer streams while a background
/// bash job settles (job-board row) and `[btw]` mail/scheduler notices
/// land mid-stream; deltas arrive WITHOUT trailing newlines, so the last
/// transcript line keeps growing. When the line that closed the streamed
/// table then grows (the next delta glues onto it), the grown-tail
/// rollback re-walked that line with an EMPTY parser buffer — the flushed
/// table grid dropped out of the view and re-appeared only on the next
/// full rebuild, so the answer visibly re-rendered in two layouts across
/// frames (table → degraded flowing text → table …).
void main() {
  /// Streams [fragments] through [tx] as no-newline deltas (each fragment
  /// merges into the growing tail like a real streamed answer), checking
  /// the incremental view against the one-shot pass at every step.
  void expectParityUnderDeltas(
    TranscriptMarkdown tx,
    List<String> src,
    List<String> fragments,
    String note,
  ) {
    for (var i = 0; i < fragments.length; i++) {
      final fragment = fragments[i];
      if (src.isEmpty) {
        src.add(fragment);
      } else {
        // A no-newline delta merges into the tail; an embedded '\n' splits
        // — exactly _appendOutput's merge semantics.
        final parts = fragment.split('\n');
        src[src.length - 1] += parts.first;
        for (var p = 1; p < parts.length; p++) {
          src.add(parts[p]);
        }
      }
      final out = tx.sync(src);
      final expected = AnsiMarkdown(width: 60).formatAll(src);
      expect(
        out.join('\n'),
        expected.join('\n'),
        reason: '$note: fragment $i (${fragment.length} chars) diverged\n'
            '--- incremental ---\n${out.join('\n')}\n'
            '--- one-shot ---\n${expected.join('\n')}',
      );
    }
  }

  test('gh-1573: grid survives the grown-tail rollback of its closing line',
      () {
    final tx = TranscriptMarkdown(width: 60);
    final src = <String>['user echo'];

    // Table streams row by row (each newline rides the NEXT fragment), so
    // the span stays open and provisional across syncs.
    expectParityUnderDeltas(tx, src, [
      'Вот ответ с таблицей:\n',
      '| кол1 | кол2 |\n',
      '| --- | --- |\n',
      '| гарде | 2 |\n',
      // The table's closing line arrives WITHOUT its newline and keeps
      // growing — the exact shape that armed the broken rollback.
      'Итог готов',
      '2. Issue два',
    ], 'table close + growing tail');

    // The committed view must still carry the whole grid.
    final view = tx.sync(src);
    expect(view.join('\n'), contains('кол1'));
    expect(view.join('\n'), contains('гарде'));
  });

  test('gh-1573: grid survives service traffic landing mid-tail', () {
    final tx = TranscriptMarkdown(width: 60);
    final src = <String>['user echo'];

    expectParityUnderDeltas(tx, src, [
      'Ответ:\n',
      '| кол1 | кол2 |\n',
      '| --- | --- |\n',
      '| гарде | 2 |\n',
      'Итог готов',
    ], 'pre-notice stream');

    // A [btw] service notice + a settled job row land BETWEEN deltas:
    // complete lines appended after the growing tail.
    src.addAll(['> ⚙ [btw] mail from main → delivered', '']);
    src.addAll(['sh-3-a1b2 · exit 1 · log: .fah/bash_jobs/sh-3-a1b2.log', '']);
    tx.sync(src);

    // The answer continues; every later sync must equal the one-shot pass.
    expectParityUnderDeltas(tx, src, [
      '2. Issue два\n',
      '3. Issue три\n',
    ], 'post-notice stream');

    final view = tx.sync(src);
    final joined = view.join('\n');
    expect('кол1'.allMatches(joined).length, 1,
        reason: 'the table header renders exactly once');
    expect('гарде'.allMatches(joined).length, 1,
        reason: 'the table cell renders exactly once');
  });

  test('gh-1573: chunk-split tail after a table close takes the byte-exact '
      'rebuild path', () {
    final tx = TranscriptMarkdown(width: 60);
    final src = <String>['echo'];

    expectParityUnderDeltas(tx, src, [
      '| a | b |\n',
      '| 1 | 2 |\n',
      'tail:',
    ], 'close');

    // fa_tui's 32KB tail cap hard-splits an oversized tail into chunks —
    // fresh substring identities. Simulated here at a small scale: the
    // boundary line is REPLACED by chunk lines that concatenate back to a
    // prefix-extension of it.
    final boundary = src.removeLast();
    final head = boundary.substring(0, boundary.length - 2);
    src.addAll([
      head.substring(0, head.length ~/ 2),
      head.substring(head.length ~/ 2),
      'x',
    ]);
    final out = tx.sync(src);
    final expected = AnsiMarkdown(width: 60).formatAll(src);
    expect(out.join('\n'), expected.join('\n'),
        reason: 'the refused split rollback lands on the rebuild path');
    expect(out.join('\n'), contains('| a |'),
        reason: 'the grid survives the split');
  });

  test('gh-1573: the glass renders the answer exactly once while a job row '
      'and a [btw] notice are pending', () {
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
    FaTuiModel pump(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    // Submit + busy: the run bracket with the user echo in the transcript.
    for (final ch in 'do the thing'.split('')) {
      model = pump(
        model,
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
      );
    }
    model = pump(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = pump(model, const BusyMsg(true, source: 'run'));

    void check(String note, {required bool tableClosed}) {
      final plain = model
          .view()
          .content
          .replaceAll(RegExp('\x1b\\[[0-9;]*m'), '');
      // While the table is still buffering (open span), its rows render
      // provisionally — the only hard invariant is "never duplicated".
      // Once the closing line committed, the grid is durable: exactly one
      // render, at every sampled frame.
      final headerCount = 'кол1'.allMatches(plain).length;
      final cellCount = 'гарде'.allMatches(plain).length;
      expect(headerCount, lessThanOrEqualTo(1),
          reason: '$note: the table header never duplicates on the glass');
      expect(cellCount, lessThanOrEqualTo(1),
          reason: '$note: the table cell never duplicates on the glass');
      if (tableClosed) {
        expect(headerCount, 1,
            reason: '$note: the committed table header renders exactly once '
                'on the glass:\n$plain');
        expect(cellCount, 1,
            reason: '$note: the committed table cell renders exactly once '
                'on the glass:\n$plain');
      }
    }

    // The answer streams as no-newline deltas (the tail line grows), a
    // table inside it, then the closing line that keeps growing — glued
    // list items included, as reported.
    final fragments = [
      'Вот ответ:\n| кол1 | кол2 |\n| --- | --- |\n',
      '| гарде | 2 |\n',
      '| b | 3 |\n',
      'Итог готов',
      '2. Issue два',
      '3. Issue три',
    ];
    for (var i = 0; i < fragments.length; i++) {
      model = pump(model, OutputMsg(fragments[i]));
      // The ticket's trigger: a background bash job settles (job-board
      // row) and a [btw] mail notice lands mid-stream.
      if (i == 3) {
        model = pump(
          model,
          const JobBoardMsg(
            ['sh-3-a1b2 · exit 1 · log: .fah/bash_jobs/sh-3-a1b2.log'],
          ),
        );
        model = pump(
          model,
          OutputMsg(
            '<system-notice>\n[btw] mail from main → delivered\n'
            '</system-notice>\n',
            newline: true,
          ),
        );
      }
      check('fragment $i', tableClosed: i >= 3);
    }

    // Idle frame (busy off, job board still pending) stays correct too.
    model = pump(model, const BusyMsg(false));
    check('idle', tableClosed: true);
  });
}
