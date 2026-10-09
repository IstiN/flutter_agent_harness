// Viewport tail-follow (issues #827 + #1348): the viewport pins to the
// BOTTOM — a submitted message lands at the bottom above the composer with
// the prior history directly above it (no blank void), streaming scrolls up
// line by line, and a user scroll-up releases the pin (the detached percent
// rule is the jump-to-bottom affordance). gh-1446 retracts the reserved
// row's streaming TEXT: while rows hide above the fold the row renders as
// a textless dim rule; the unified above/below fold accounting stays.
// #1348 supersedes #827's turn-start anchor: the window never parks at the
// turn's first row.
//
// Pure render tests — fake terminal, no IO. Frames are read straight off
// `model.view()`; the AC7 goldens go through the real CellRenderer over an
// in-memory sink (same harness as fa_tui_sticky_scroll_test.dart) and
// compare against pristine-CLI byte baselines
// (fa_tui_viewport_fold_golden.txt).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart' hide stripAnsi;
import 'package:dart_tui/src/renderer.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show QueuedMessage, stripAnsi;
import 'package:test/test.dart';

import 'tui_render_harness.dart';

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => '/work · 0tok · turn 0 · test-model',
  prompt: 'fa> ',
);

FaTuiModel _build({
  int termWidth = 80,
  int termHeight = 24,
  bool busy = false,
  bool mouseCapture = true,
}) =>
    FaTuiModel(
          callbacks: _callbacks(),
          isExited: () => false,
          termWidth: termWidth,
          termHeight: termHeight,
          mouseCapture: mouseCapture,
        ).update(BusyMsg(busy)).$1
        as FaTuiModel;

FaTuiModel _send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

List<String> _rowsOf(FaTuiModel m) =>
    m.view().content.split('\n').map((r) => stripAnsi(r)).toList();

final _percent = RegExp(r'\d+%');

/// A pure gh-1446 fold-rule row: only `─` cells. The legacy composer's
/// input-frame rules match too — the tests pin the fold rule as a
/// rule-count DELTA against the same frame shape with nothing hidden (the
/// calm baseline), or by the row's position right under the history
/// window.
bool _isRuleRow(String row) =>
    row.isNotEmpty && row.runes.every((r) => r == 0x2500);

int _ruleRowCount(List<String> rows) => rows.where(_isRuleRow).length;

/// Whether [rows] carries the textless fold rule: one MORE pure rule row
/// than the calm twin of the same frame shape.
bool _hasFoldRule(List<String> rows, List<String> calmRows) =>
    _ruleRowCount(rows) == _ruleRowCount(calmRows) + 1;

bool _hasPercent(List<String> rows) =>
    rows.any((r) => _percent.hasMatch(r));

void main() {
  group('AC1 — above-the-fold indicator during tail-follow', () {
    test('rows hiding above the fold render the textless rule under the '
        'history window', () {
      // 40 short (non-wrapping) lines, one turn from row 0: vh = 24 - 5
      // (progress + 2 rules + status + input) = 19, so 21 rows hide above.
      final model = _build(
        termHeight: 24,
      ).copyWith(outputLines: [for (var i = 0; i < 40; i++) 'row $i']);
      final rows = _rowsOf(model);
      expect(
        _isRuleRow(rows[19]),
        isTrue,
        reason: 'the reserved row renders the textless rule (21 hidden)',
      );
      // The window content confirms the geometry: rows 21..39 on glass.
      expect(rows.first, contains('row 21'));
      expect(rows[18], contains('row 39'));
    });

    test('the rule keys on WRAPPED rows, not logical lines (CJK-safe)', () {
      // 10 lines of 90 cells each wrap to 2 rows at width 80 → 20 wrapped
      // rows; the bottom-riding window shows the last 19, so one hidden
      // WRAPPED row already folds (logical counting would say 0).
      final wide = '要約' * 22 + 'x'; // 44 wide glyphs (88 cells) + 1 = 89 cells
      final wideModel = _build().copyWith(
        outputLines: [for (var i = 0; i < 10; i++) '$wide $i'],
      );
      final calm = _build().copyWith(
        outputLines: [for (var i = 0; i < 10; i++) 'short $i'],
      );
      expect(
        _hasFoldRule(_rowsOf(wideModel), _rowsOf(calm)),
        isTrue,
        reason: '20 wrapped rows - 19 vh: the rule shows',
      );
    });

    test('no rule at offset 0 and none when the tail latch is detached', () {
      final short = _build().copyWith(outputLines: ['just one row']);
      final calm = _build().copyWith(outputLines: ['just one row']);
      expect(
        _hasFoldRule(_rowsOf(short), _rowsOf(calm)),
        isFalse,
        reason: 'E3: one-row response, zero hidden rows',
      );

      final long = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      );
      final scrolled = _send(
        long,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      final rows = _rowsOf(scrolled);
      expect(
        _hasFoldRule(rows, _rowsOf(_build().copyWith(outputLines: ['tiny']))),
        isFalse,
        reason: 'detached: the percent rule owns',
      );
      expect(_hasPercent(rows), isTrue);
    });
  });

  group('AC2 — user scroll releases the pin, bottom re-latches (#1348)', () {
    FaTuiModel atBottom() => _build().copyWith(
      outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      scrollOffset: 21, // the live edge (40 - 19 vh)
    );

    test('a wheel-up releases the pin; the percent rule owns the row', () {
      final up = _send(
        atBottom(),
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(up.followTail, isFalse, reason: 'user scroll-up releases the pin');
      expect(up.scrollOffset, 18, reason: 'bottom 21 - 3');
      final rows = _rowsOf(up);
      expect(_hasPercent(rows), isTrue);
      expect(
        _hasFoldRule(rows, _rowsOf(_build().copyWith(outputLines: ['tiny']))),
        isFalse,
        reason: 'detached: percent, never both',
      );
    });

    test('detached, new activity never moves the window — the percent '
        'rule is the jump-to-bottom affordance', () {
      var model = atBottom();
      model = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      final parked = _send(model, OutputMsg('late arrival', newline: true));
      expect(parked.followTail, isFalse);
      expect(
        parked.scrollOffset,
        model.scrollOffset,
        reason: 'a detached window never moves under the stream',
      );
      expect(_hasPercent(_rowsOf(parked)), isTrue);
    });

    test('page-down to the exact bottom re-latches tail-follow', () {
      var model = atBottom();
      model = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(model.followTail, isFalse);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      expect(model.followTail, isTrue);
      expect(
        _hasFoldRule(
          _rowsOf(model),
          _rowsOf(_build().copyWith(outputLines: ['tiny'])),
        ),
        isTrue,
      );
      expect(_hasPercent(_rowsOf(model)), isFalse);
    });
  });

  group('AC3 — submit lands at the bottom, no blank void (#1348 AC1)', () {
    test('a submitted message rides the bottom with prior history directly '
        'above it', () async {
      const turnOne = 'TURN-ONE-MARKER explain the bug';
      const turnTwo = 'TURN-TWO-MARKER now fix it';
      var model = _build(termHeight: 12);

      // Turn 1: submit, stream past the viewport, settle.
      model = model.copyWith(inputText: turnOne);
      var result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      model = result.$1 as FaTuiModel;
      await result.$2?.call();
      model = _send(model, const BusyMsg(true, source: 'run'));
      for (var i = 0; i < 30; i++) {
        model = _send(model, OutputMsg('alpha answer $i', newline: true));
      }
      model = _send(model, const BusyMsg(false));

      // Turn 2: capture every frame rendered after the submit.
      model = model.copyWith(inputText: turnTwo);
      result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      model = result.$1 as FaTuiModel;
      await result.$2?.call();

      final frames = <List<String>>[];
      frames.add(_rowsOf(model));
      model = _send(model, const BusyMsg(true, source: 'run'));
      for (var i = 0; i < 30; i++) {
        model = _send(model, OutputMsg('beta answer $i', newline: true));
        frames.add(_rowsOf(model));
      }
      model = _send(model, const BusyMsg(false));
      frames.add(_rowsOf(model));

      // The submitted prompt is at the BOTTOM of the history zone, with
      // the previous turn's tail DIRECTLY above it — standard terminal
      // semantics (#1348 AC1). The pre-#1348 turn-start anchor pinned the
      // echo to the TOP and padded the window below with blanks.
      final first = frames.first.take(7).toList(); // history zone, vh 7
      final lastContent = first.lastWhere((r) => r.trim().isNotEmpty);
      expect(
        lastContent,
        contains('TURN-TWO-MARKER'),
        reason: 'the fresh prompt is on the glass, at the bottom',
      );
      final aboveEcho = first
          .takeWhile((r) => !r.contains('TURN-TWO'))
          .lastWhere((r) => r.trim().isNotEmpty);
      expect(
        aboveEcho,
        contains('alpha answer 29'),
        reason: 'prior history sits directly above the new message',
      );
      // Streaming keeps the growing tail pinned to the bottom (#1348 AC2).
      expect(
        frames.last.join('\n'),
        contains('beta answer 29'),
        reason: 'the viewport tracks the growing tail',
      );
    });

    test('a short turn into a long transcript shows NO blank void below '
        'the echo (the reported symptom)', () {
      // 40 rows on glass + a 1-line submit: the window is the LAST 19
      // wrapped rows — history above, echo bubble at the bottom, nothing
      // blank-padded between them and the composer.
      var model = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
        inputText: 'hello',
      );
      final result = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
      model = result.$1 as FaTuiModel;
      final rows = _rowsOf(model);
      final history = rows.take(19).toList();
      expect(
        history.first,
        contains('row 25'),
        reason: 'the window is the last vh rows (44 total - 19)',
      );
      expect(
        history[14],
        contains('row 39'),
        reason: 'prior history runs right up to the echo',
      );
      final lastContent = history.lastWhere((r) => r.trim().isNotEmpty);
      expect(
        lastContent,
        contains('hello'),
        reason: 'the echo is the last content above the composer',
      );
      final trailingBlanks = history.reversed
          .takeWhile((r) => r.trim().isEmpty)
          .length;
      expect(
        trailingBlanks,
        lessThan(4),
        reason:
            'only the bubble padding may sit under the echo — '
            'a blank void is the bug',
      );
    });
  });

  group('AC4 — the indicator lives inside the frame budget', () {
    test('one-row viewport history still paints the rule without stealing '
        'the prompt chrome', () {
      // termHeight 6: legacy fixed chrome 5 → history 1 → 39 rows hide.
      final model = _build(
        termHeight: 6,
      ).copyWith(outputLines: [for (var i = 0; i < 40; i++) 'row $i']);
      final rows = _rowsOf(model);
      expect(rows, hasLength(6), reason: 'frame exactly fits the glass');
      expect(_isRuleRow(rows[1]), isTrue, reason: 'the reserved rule row');
      expect(
        rows.last,
        contains('test-model'),
        reason: 'status/prompt rows untouched',
      );
      expect(rows[0], contains('row 39'), reason: 'live edge still on glass');
    });

    test('zero-history viewport yields the rule entirely (E2)', () {
      // termHeight 5: chrome alone fills the glass, history = 0.
      final model = _build(
        termHeight: 5,
      ).copyWith(outputLines: [for (var i = 0; i < 40; i++) 'row $i']);
      final rows = _rowsOf(model);
      expect(rows, hasLength(5));
      final calm = _build(termHeight: 5).copyWith(outputLines: ['tiny']);
      expect(
        rows.last,
        contains('test-model'),
        reason: 'prompt row never moves for the rule',
      );

      // The composer tail is identical whether or not rows hide above —
      // a window that shows no rows announces nothing (E4).
      expect(
        rows.skip(1),
        _rowsOf(calm).skip(1),
        reason: 'rule absence keeps the bottom chrome byte-stable',
      );
    });
  });

  group('AC5 — reset-to-bottom paths re-evaluate the rule', () {
    List<String> longHistory() => [for (var i = 0; i < 40; i++) 'row $i'];

    test('submit re-anchors the window at the live edge', () async {
      var model = _build(termHeight: 12).copyWith(outputLines: longHistory());
      expect(
        _isRuleRow(_rowsOf(model)[7]),
        isTrue,
        reason: '40 - 7 vh: the rule owns the reserved row',
      );

      model = model.copyWith(inputText: 'second question');
      final result = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
      model = result.$1 as FaTuiModel;
      await result.$2?.call();

      // The echo bubble adds 4 wrapped rows (44 total); the window rides
      // the live edge, not the echo row (#1348) — the rule stays.
      expect(
        _isRuleRow(_rowsOf(model)[7]),
        isTrue,
        reason: '44 - 7 vh: the window is pinned to the bottom',
      );
    });

    test('steering re-anchors the window at the live edge', () {
      var model = _build().copyWith(
        outputLines: longHistory(),
        busy: true,
        queue: const [QueuedMessage('steered text')],
      );
      model = _send(
        model,
        KeyPressMsg(
          const TeaKey(code: KeyCode.rune, text: 's', modifiers: {KeyMod.ctrl}),
        ),
      );
      expect(model.queue, isEmpty, reason: 'fixture: ctrl+s flushed');
      final calm = _build(busy: true).copyWith(outputLines: ['tiny']);
      expect(
        _hasFoldRule(_rowsOf(model), _rowsOf(calm)),
        isTrue,
        reason:
            '40 + 4 echo + 1 receipt = 45; busy vh 18: the window rides '
            'the bottom',
      );
    });

    test('queue drain re-anchors the window at the live edge', () {
      var model = _build().copyWith(
        outputLines: longHistory(),
        busy: true,
        queue: const [QueuedMessage('drained text')],
      );
      model = _send(model, DrainQueueMsg(Completer<List<String>>()));
      final calm = _build(busy: true).copyWith(outputLines: ['tiny']);
      expect(
        _hasFoldRule(_rowsOf(model), _rowsOf(calm)),
        isTrue,
        reason: '44 lines, busy vh 18: the rule rides the live edge',
      );
    });
  });

  group('AC6/E4 — mouse-mode interplay unchanged', () {
    test('captured wheel scrolls the in-app viewport (percent shows)', () {
      final model = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
        scrollOffset: 21, // bottom
      );
      final scrolled = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(scrolled.scrollOffset, 18, reason: 'bottom 21 - 3');
      expect(scrolled.followTail, isFalse);
      expect(_hasPercent(_rowsOf(scrolled)), isTrue);
      expect(
        _hasFoldRule(
          _rowsOf(scrolled),
          _rowsOf(_build().copyWith(outputLines: ['tiny'])),
        ),
        isFalse,
        reason: 'detached: percent rule, never both at once',
      );
    });

    test('native wheel does not repaint or move the viewport', () {
      final model = _build(
        mouseCapture: false,
      ).copyWith(outputLines: [for (var i = 0; i < 40; i++) 'row $i']);
      final after = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(after.scrollOffset, model.scrollOffset);
      expect(after.followTail, model.followTail);
      expect(_rowsOf(after), _rowsOf(model));
    });
  });

  group('Edge cases', () {
    test('E1: resize mid-stream re-renders the rule, latch survives', () {
      var model = _build(
        termHeight: 24,
      ).copyWith(outputLines: [for (var i = 0; i < 60; i++) 'row $i']);
      expect(_isRuleRow(_rowsOf(model)[19]), isTrue, reason: '60 - 19 vh');

      model = _send(model, WindowSizeMsg(80, 12));
      expect(model.followTail, isTrue, reason: 'shrink keeps the latch');
      expect(_isRuleRow(_rowsOf(model)[7]), isTrue, reason: '60 - 7 vh');

      model = _send(model, WindowSizeMsg(80, 30));
      expect(_isRuleRow(_rowsOf(model)[25]), isTrue, reason: '60 - 25 vh');
      expect(_rowsOf(model), hasLength(30));
    });

    test('E3: one-row response never shows the rule (idle and busy)', () {
      for (final busy in [false, true]) {
        final model = _build(busy: busy).copyWith(outputLines: ['single line']);
        final calm = _build(busy: busy).copyWith(outputLines: ['single line']);
        expect(
          _hasFoldRule(_rowsOf(model), _rowsOf(calm)),
          isFalse,
          reason: 'busy=$busy',
        );
      }
    });

    test('E5: tall from the first streamed row — rule present from the '
        'first overflow', () {
      var model = _build(termHeight: 24);
      for (var i = 0; i < 20; i++) {
        model = _send(model, OutputMsg('stream $i', newline: true));
      }
      // 21 wrapped rows (newline appends a trailing blank), vh 19: two
      // rows hidden already.
      final rows = _rowsOf(model);
      expect(_isRuleRow(rows[19]), isTrue, reason: 'symptom 1 verbatim');
      expect(
        rows.first,
        contains('stream 2'),
        reason: 'the window tracks the live edge, not the fold',
      );
    });

    test('E6: a single hidden row already renders the rule', () {
      // 20 copied rows, vh 19: bottom = 1, one row hides above the fold.
      // The text is gone (gh-1446) — the COUNT is no longer observable;
      // the rule appearing at all is the contract.
      final model = _build().copyWith(
        outputLines: [for (var i = 0; i < 20; i++) 'row $i'],
      );
      final rows = _rowsOf(model);
      expect(_isRuleRow(rows[19]), isTrue);
      expect(rows.join('\n'), isNot(contains('above fold')),
          reason: 'the textless rule carries no words');
    });

    test('AC1 byte-scan: the streaming rule row carries NO text glyphs', () {
      // The reserved row renders as a dim rule of `─` only — no digits,
      // letters or `^` ever reach the row (gh-1446 AC1).
      final model = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      );
      final rows = _rowsOf(model);
      final ruleRow = rows[19];
      expect(ruleRow, matches(RegExp(r'^─+$')), reason: ruleRow);
      expect(ruleRow, hasLength(80), reason: 'full-width rule, no gaps');
      // The row reservation holds: the frame keeps the calm shape (the
      // same row count) — nothing below the rule shifts.
      final calm = _build().copyWith(outputLines: ['tiny']);
      expect(rows, hasLength(_rowsOf(calm).length));
      // Wave-14 grammar: a pure rule row is chrome to every separator-
      // stripping screen consumer — unlike the padded hint text it
      // replaces.
      expect(ruleRow.startsWith('────'), isTrue);
      expect(ruleRow.trimRight().endsWith('─'), isTrue);
      expect(ruleRow, isNot(startsWith(' ')));
    });
  });

  group('head-trim keeps the pinned echo honest', () {
    // 2401 lines: the first append crosses maxLines(2000) + slack(400),
    // the amortized trim cuts result.length - 2000 = 403 head lines.
    FaTuiModel trimmed({bool openFence = false}) {
      final lines = [
        if (openFence) '```dart',
        for (var i = 0; i < 2400; i++) 'pad $i',
        'TURN-ECHO-MARK',
      ];
      return _build().copyWith(outputLines: lines);
    }

    test('a trim keeps the window on the live edge — the tail stays on the '
        'glass', () {
      final streamed = _send(trimmed(), OutputMsg('tick', newline: true));
      // The append merges into the echo line and adds the trailing blank:
      // 2401 + 1 = 2402 lines -> cut 402, 2000 retained; the window rides
      // the bottom (2000 - 19 vh = 1981 -> retained index 1981 = original
      // line 2383).
      expect(
        _rowsOf(streamed).first,
        contains('pad 2383'),
        reason: 'rides the global bottom',
      );
    });

    test('a trim shifts the pinned sticky index by the cut', () {
      // The sticky pins at submit; the stream then crosses the cap and
      // the append fires the trim. The pinned echo is a transcript index
      // like any other — it shifts with the cut instead of pointing at a
      // foreign line (issue #827 review).
      final model = trimmed().copyWith(
        stickyLines: const ['pinned echo'],
        stickyIndex: 2400,
        stickyEchoLineCount: 1,
      );
      final streamed = _send(model, OutputMsg('tick', newline: true));
      expect(streamed.stickyIndex, 1998, reason: '2400 - 402 cut');
    });

    test('a trim landing in an open code fence shifts by cut - 1', () {
      // The dropped head opens a fence: the repair prepends a synthetic
      // fence line that occupies index 0, so retained lines sit one slot
      // lower than a plain cut — shift = 403 - 1 = 402. The echo is the
      // last line (2401) of the 2402-line fixture.
      final model = trimmed(openFence: true).copyWith(
        stickyLines: const ['pinned echo'],
        stickyIndex: 2401,
        stickyEchoLineCount: 1,
      );
      final streamed = _send(model, OutputMsg('tick', newline: true));
      expect(streamed.stickyIndex, 1999, reason: '2401 - (403 - 1)');
    });

    test('a trim that swallows the pinned echo drops the pin', () {
      final model = trimmed().copyWith(
        stickyLines: const ['pinned echo'],
        stickyIndex: 5,
        stickyEchoLineCount: 1,
      );
      final streamed = _send(model, OutputMsg('tick', newline: true));
      expect(
        streamed.stickyIndex,
        -1,
        reason:
            'a stale pin aimed at a foreign line is worse than '
            'no pin',
      );
    });

    test(
      'the submit echo trim keeps the echo on the glass at the bottom',
      () async {
        var submitted = _build()
            .copyWith(outputLines: [for (var i = 0; i < 2400; i++) 'pad $i'])
            .copyWith(inputText: 'SUBMIT-TRIM-MARK');
        final result = submitted.update(
          KeyPressMsg(const TeaKey(code: KeyCode.enter)),
        );
        submitted = result.$1 as FaTuiModel;
        await result.$2?.call();

        // The echo bubble adds 3 lines over the cap: 2403 -> cut 403,
        // 2000 retained; the tail append rides the slack (2001 total).
        // The echo text survives at retained index 2400 - 403 = 1997,
        // inside the bottom-riding window (1982..2000).
        expect(submitted.stickyIndex, 1997);
        expect(
          _rowsOf(submitted).first,
          contains('pad 2385'),
          reason: 'the window rides the bottom, not the echo row',
        );
      },
    );

    test('a trim during queue drain shifts the pinned sticky index', () {
      final lines = [for (var i = 0; i < 2399; i++) 'pad $i', 'ECHO-PIN'];
      final model = _build().copyWith(
        outputLines: lines,
        busy: true,
        stickyLines: const ['ECHO-PIN'],
        stickyIndex: 2399,
        stickyEchoLineCount: 1,
        queue: const [QueuedMessage('drained text')],
      );
      final drained = _send(model, DrainQueueMsg(Completer<List<String>>()));
      // The drained echo bubble adds 3 lines over the cap: 2403 -> cut
      // 403, 2000 retained. The pin must ride its own line into the
      // retained region — an unshifted index points 403 lines too deep at
      // a foreign row and corrupts the #917 dedupe geometry.
      expect(drained.stickyIndex, 1996, reason: '2399 - 403 cut');
      expect(
        stripAnsi(drained.outputLines[1996]),
        'ECHO-PIN',
        reason: 'the shifted pin still names its own line',
      );
    });

    test(
      'a trim during steering shifts the sticky pin and the boot anchor',
      () {
        final lines = [for (var i = 0; i < 2399; i++) 'pad $i', 'ECHO-PIN'];
        final model = _build().copyWith(
          outputLines: lines,
          busy: true,
          stickyLines: const ['ECHO-PIN'],
          stickyIndex: 2399,
          stickyEchoLineCount: 1,
          bootAnchorLine: 500,
          queue: const [QueuedMessage('steered text')],
        );
        final steered = _send(
          model,
          KeyPressMsg(
            const TeaKey(
              code: KeyCode.rune,
              text: 's',
              modifiers: {KeyMod.ctrl},
            ),
          ),
        );
        // 2400 + 3 echo lines = 2403 -> cut 403, 2000 retained; the receipt
        // append rides the slack (2001). Both anchored indices shift by the
        // cut: an unshifted boot anchor could re-qualify for the boot park
        // at a foreign row and park the follow window off the live edge.
        expect(steered.stickyIndex, 1996, reason: '2399 - 403 cut');
        expect(steered.bootAnchorLine, 97, reason: '500 - 403 cut');
        expect(
          stripAnsi(steered.outputLines[97]),
          'pad 500',
          reason:
              'the shifted boot anchor still names its own row '
              '(retained 97 = original 500)',
        );
      },
    );
  });

  group('AC7 — byte-identical rendering where the feature is inert', () {
    Map<String, String> loadGoldens() {
      final goldens = <String, String>{};
      for (final line in File(
        'test/cli/fa_tui_viewport_fold_golden.txt',
      ).readAsLinesSync()) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final split = line.split(' ');
        expect(split, hasLength(2), reason: 'malformed golden line: $line');
        goldens[split[0]] = split[1];
      }
      return goldens;
    }

    /// A golden frame by key — fails loudly on a missing/renamed key
    /// instead of comparing against a cryptic null.
    String golden(Map<String, String> goldens, String key) {
      final value = goldens[key];
      expect(value, isNotNull, reason: 'missing golden $key');
      return value!;
    }

    String render(FaTuiModel model) {
      final buf = StringBuffer();
      CellRenderer(
        output: StringSinkIOSink(buf),
        logSink: null,
        defaultAltScreen: false,
        defaultHideCursor: false,
      ).render(model.view());
      return base64Encode(utf8.encode(buf.toString()));
    }

    test('offset-0 and detached-percent frames match pristine bytes', () {
      final goldens = loadGoldens();

      var short = _build();
      short = _send(short, OutputMsg('hello world', newline: true));
      expect(
        render(short),
        golden(goldens, 'F1'),
        reason: 'F1: bare frame, offset 0 — no hint row content',
      );

      var long = _build();
      for (var i = 0; i < 60; i++) {
        long = _send(long, OutputMsg('stream line $i', newline: true));
      }
      var up = _send(long, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      up = _send(up, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      expect(
        render(up),
        golden(goldens, 'F3'),
        reason: 'F3: detached percent frame — legacy bytes untouched',
      );
    });

    test('follow frame after a live submit (drift guard)', () {
      final goldens = loadGoldens();
      var long = _build();
      for (var i = 0; i < 60; i++) {
        long = _send(long, OutputMsg('stream line $i', newline: true));
      }
      final result = long
          .copyWith(inputText: 'F4-TURN')
          .update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      final turned = result.$1 as FaTuiModel;
      // The snapshot pins the textless rule row AND every stable region;
      // any accidental layout drift fails here (REG blocks merge).
      expect(
        _hasFoldRule(
          _rowsOf(turned),
          _rowsOf(_build().copyWith(outputLines: ['tiny'])),
        ),
        isTrue,
      );
      expect(
        render(turned),
        golden(goldens, 'F4'),
        reason: 'F4 canonical frame',
      );
    });
  });

  group('resume rides the closed moment (bottom); live rides the bottom', () {
    // The replayed stream: 40 old rows, the last prompt echo (rule + text
    // + blank = lines 40..42), a 12-row reply. All short lines — wrapped
    // rows equal logical lines, so indices are inspectable.
    List<String> replayed() => [
      for (var i = 0; i < 40; i++) 'old row $i',
      '─' * 80,
      'RESUMED-PROMPT check the fold',
      '',
      for (var i = 0; i < 12; i++) 'resumed answer $i',
    ];

    test('a resumed transcript that fits the glass shows every row', () {
      // Boot chrome (banner tail + the #503 lost-summary) above a short
      // replayed turn: the resumed window rides the global bottom, and
      // with the whole transcript on the glass NOTHING may fold — the
      // reconciliation notice stays visible (issue #503 AC).
      final model = _build().copyWith(
        outputLines: [
          ...replayed().take(3), // boot chrome stands in for the banner
          '✗ 2 background tasks lost on restart',
          ...replayed().skip(40),
        ],
      );
      final rows = _rowsOf(model);
      // The reserved row stays BLANK — nothing hides, the fold rule never
      // shows (the replayed `────` separator is transcript content, not
      // the indicator; it sits at rows index 19 = history bottom + 1).
      expect(
        _isRuleRow(rows[19]),
        isFalse,
        reason: 'nothing is hidden when the transcript fits the glass',
      );
      expect(rows[19].trim(), isEmpty, reason: 'the blank reserved row');
      expect(rows.join('\n'), contains('lost on restart'));
      expect(rows.join('\n'), contains('RESUMED-PROMPT'));
    });

    test('a resumed transcript taller than the glass rides the bottom '
        'under the textless rule', () {
      final model = _build().copyWith(outputLines: replayed());
      final rows = _rowsOf(model);
      // The live edge wins: the replayed tail is on the glass, the older
      // rows hide above the fold — the same window the session rode at
      // close (#446 1:1), with the reserved rule owning the signal.
      expect(rows.join('\n'), contains('RESUMED-PROMPT'));
      expect(rows.join('\n'), contains('resumed answer 11'));
      expect(
        _isRuleRow(rows[19]),
        isTrue,
        reason: '55 - 19 wrapped rows hide above the bottom-riding window',
      );
      expect(
        rows.join('\n').contains('old row 0 '),
        isFalse,
        reason: 'deep pre-tail rows stay above the fold',
      );
    });

    test('the first LIVE submit after a resume rides the bottom', () async {
      // Resume itself never anchors (the boot glass must keep the
      // reconciliation notices) — and the user's next submit keeps the
      // standard terminal semantics: the echo lands at the BOTTOM above
      // the composer, prior replay tail directly above it (#1348).
      final resumed = _build().copyWith(outputLines: replayed());
      final result = resumed
          .copyWith(inputText: 'next turn')
          .update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      final model = result.$1 as FaTuiModel;
      await result.$2?.call();
      final rows = _rowsOf(model).take(19).toList();
      final lastContent = rows.lastWhere((r) => r.trim().isNotEmpty);
      expect(
        lastContent,
        contains('next turn'),
        reason: 'the new echo is the last content above the composer',
      );
      final aboveEcho = rows
          .takeWhile((r) => !r.contains('next turn'))
          .lastWhere((r) => r.trim().isNotEmpty);
      expect(
        aboveEcho,
        contains('resumed answer 11'),
        reason: 'the replayed tail sits directly above the echo',
      );
      expect(
        _isRuleRow(_rowsOf(model)[19]),
        isTrue,
        reason: '55 replayed + 4 echo rows = 59 - 19 vh',
      );
    });
  });
}
