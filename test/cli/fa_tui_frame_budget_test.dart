// Frame-height budget (issue #479): EVERY region view() renders pays into
// the viewport height — busy row, job board, sticky echo, chips, queue — so
// the frame is exactly termHeight rows whenever the chrome fits, and the
// prompt path pays for the prompt zone alone (no double count with the
// input zone). The squeezed board clips cell-aware, newest-kept, with an
// explicit `… +N more` tail row; no chrome row renders wider than the
// terminal (a wide chrome row soft-wraps and desyncs the row grid exactly
// like a height overflow).
library;

import 'dart:async';
import 'package:dart_tui/dart_tui.dart' hide stripAnsi;
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show QueuedMessage, stripAnsi;
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:test/test.dart';

const _board4 = [
  '⟳ Background jobs (4) · 4 running · 0 done · 0 lost',
  '↳ sh-4-x · bash ~/bin/install-gh.sh 2>&1 | tail -5',
  '↳ sh-3-x · uname -a; command -v brew; echo done',
  '↳ sh-2-x · cat ~/bin/install-gh.sh',
];

/// Summary + five live rows (six lines): forces board clipping on short
/// terminals; the two newest live rows sort last.
const _board6 = [..._board4, '↳ sh-1-x · echo fifth', '↳ sh-0-x · echo sixth'];

final _chip = TuiImageAttachment(
  name: 'clipboard-1.png',
  mimeType: 'image/png',
  bytes: List.filled(12, 0),
);

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => '/work · 0tok · turn 0 · test-model',
  prompt: 'fa> ',
);

FaTuiModel build({
  int termWidth = 80,
  int termHeight = 24,
  List<String> board = const [],
  List<TuiImageAttachment> attachments = const [],
  List<QueuedMessage> queue = const [],
  bool busy = false,
  String inputText = '',
}) {
  final model =
      FaTuiModel(
            callbacks: _callbacks(),
            isExited: () => false,
            termWidth: termWidth,
            termHeight: termHeight,
          ).update(BusyMsg(busy)).$1
          as FaTuiModel;
  return model.copyWith(
    inputText: inputText,
    jobBoardLines: board,
    attachments: attachments,
    queue: queue,
  );
}

FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

List<String> rowsOf(FaTuiModel m) => m.view().content.split('\n');

String _plain(String row) => stripAnsi(row);

void main() {
  test('UT-1 #479 AC1: frame is exactly termHeight rows across the '
      'chrome matrix (24- and 12-row terminals)', () {
    final combos = <String, FaTuiModel Function(int)>{
      'bare': (h) => build(termHeight: h),
      'busy': (h) => build(termHeight: h, busy: true),
      'board': (h) => build(termHeight: h, busy: true, board: _board4),
      'chips': (h) => build(termHeight: h, attachments: [_chip]),
      'queue': (h) => build(
        termHeight: h,
        queue: const [QueuedMessage('q1'), QueuedMessage('q2')],
      ),
      'all': (h) => build(
        termHeight: h,
        busy: true,
        board: _board4,
        attachments: [_chip],
        queue: const [QueuedMessage('q1')],
      ),
    };
    for (final entry in combos.entries) {
      for (final h in [24, 12]) {
        expect(rowsOf(entry.value(h)), hasLength(h), reason: '${entry.key}@$h');
      }
    }
  });

  test('UT-2 #479 AC2: a JobBoardMsg arriving and draining mid-run keeps '
      'the frame constant, follow-tail latched, region order unchanged', () {
    var model = build(termHeight: 24, busy: true);
    model = send(model, OutputMsg('answer stream line', newline: true));
    expect(rowsOf(model), hasLength(24));

    model = send(model, const JobBoardMsg(_board4));
    final rows = rowsOf(model);
    expect(rows, hasLength(24));
    // Follow-tail intact: the newest history row is still on the glass.
    expect(rows.map(_plain), contains(contains('answer stream line')));
    // Board rows sit immediately above the busy row (same position as
    // today: between the scheduled row and the waiting/busy rows).
    final busyIdx = rows.indexWhere((r) => _plain(r).contains('Working'));
    expect(busyIdx, greaterThanOrEqualTo(4));
    expect(_plain(rows[busyIdx - 4]), contains('Background jobs (4)'));
    expect(_plain(rows[busyIdx - 1]), contains('sh-2-x'));

    // Drain (empty board hides the region), frame stays exact.
    model = send(model, const JobBoardMsg([]));
    final drained = rowsOf(model);
    expect(drained, hasLength(24));
    expect(drained.map(_plain), isNot(contains(contains('Background jobs'))));
  });

  test('UT-3 #479 AC4: prompt mode with board and chips fills exactly '
      'termHeight (no double count of the input zone)', () {
    var model = build(
      termHeight: 24,
      busy: true,
      board: _board4,
      attachments: [_chip],
    );
    model = send(
      model,
      OpenPromptMsg(
        const TextPromptSpec(question: 'Enter value:'),
        Completer<TuiPromptAnswer?>(),
      ),
    );
    final rows = rowsOf(model);
    expect(rows, hasLength(24), reason: 'prompt frame must fill the glass');
    expect(rows.map(_plain), contains(contains('Background jobs (4)')));
    expect(
      rows.map(_plain),
      contains(contains('chips send with your next message')),
    );
    expect(rows.map(_plain), contains(contains('test-model')));

    // A multi-line draft must not change the prompt frame height (the
    // input zone is replaced by the prompt — its rows are not on glass).
    final draft = model.copyWith(inputText: 'line1\nline2\nline3');
    expect(rowsOf(draft), hasLength(24));
  });

  test('UT-4 #479 AC5: squeezed board clips newest-kept with an explicit '
      'tail row; input zone, rules and status are never sacrificed', () {
    // Height 10: fixed chrome (mandatory 4 + busy 1 + input 1) leaves 4
    // board rows of the 6; summary + the two newest live rows stay.
    final h10 = build(termHeight: 10, busy: true, board: _board6);
    final rows10 = rowsOf(h10).map(_plain).toList();
    expect(rows10, hasLength(10));
    expect(rows10, contains(contains('Background jobs (4)')));
    expect(rows10, contains('… +3 more'));
    expect(rows10, contains(contains('sh-0-x')));
    expect(rows10, isNot(contains(contains('sh-3-x'))));

    // Height 8: only summary + tail fit (newest-kept needs 3+ rows);
    // the live rows and their hidden-count report degrade together.
    final h8 = build(
      termHeight: 8,
      busy: true,
      board: _board6,
      inputText: 'keep me',
    );
    final rows8 = rowsOf(h8).map(_plain).toList();
    expect(rows8, hasLength(8));
    expect(rows8, contains(contains('Background jobs (4)')));
    expect(rows8, contains('… +5 more'));
    expect(rows8, isNot(contains(contains('sh-4-x'))));
    expect(rows8, isNot(contains(contains('sh-0-x'))));
    expect(rows8.where((r) => r.contains('─')), hasLength(2));
    expect(rows8, contains(contains('keep me'))); // composer survives
    expect(rows8, contains(contains('test-model'))); // status survives

    // E2: resize while jobs live recomputes the plan for the new height.
    final resized = build(
      termHeight: 24,
      busy: true,
      board: _board6,
    ).copyWith(termHeight: 8);
    expect(rowsOf(resized), hasLength(8));
  });

  test('UT-5 #479 AC6: board rows clip to VISIBLE cells — no chrome row '
      'wider than the terminal under any combination', () {
    final cjkRow = '↳ sh-9-x · ${'要約' * 60}'; // 1210 cells, 121 units
    final asciiRow = '↳ sh-8-x · ${'x' * 200}'; // 207 units
    final model = build(
      termWidth: 80,
      termHeight: 24,
      busy: true,
      board: [_board4[0], cjkRow, asciiRow],
      queue: const [QueuedMessage('队列消息 queue message')],
    );
    final rows = rowsOf(model).map(_plain).toList();
    for (final row in rows) {
      expect(
        tuiTextWidth(row),
        lessThanOrEqualTo(80),
        reason: 'chrome row renders past the width: "$row"',
      );
    }
    // The CJK row is clipped, not dropped, on a grapheme boundary.
    expect(rows, contains(contains('要約')));
  });

  test(
    'E5 #479: pinned sticky echo and live board coexist at termHeight',
    () async {
      var model = FaTuiModel(
        callbacks: _callbacks(),
        isExited: () => false,
        termHeight: 12,
      );
      for (final ch in 'hello'.split('')) {
        model = send(model, KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)));
      }
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      await Future<void>.delayed(Duration.zero);
      model = send(model, const BusyMsg(true));
      for (var i = 0; i < 30; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      expect(model.stickyLines, isNotEmpty, reason: 'fixture: echo pinned');
      model = model.copyWith(jobBoardLines: _board4, attachments: [_chip]);
      final rows = rowsOf(model);
      expect(rows, hasLength(12));
      expect(rows.map(_plain), contains(contains('Background jobs (4)')));
    },
  );
}
