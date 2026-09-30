// Viewport never loses shown content (issue #827): the tail-follow hint
// (`^ N lines above fold - PgUp`), the clean turn-boundary anchor, and the
// unified above/below fold accounting.
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
}) => FaTuiModel(
  callbacks: _callbacks(),
  isExited: () => false,
  termWidth: termWidth,
  termHeight: termHeight,
  mouseCapture: mouseCapture,
).update(BusyMsg(busy)).$1 as FaTuiModel;

FaTuiModel _send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

List<String> _rowsOf(FaTuiModel m) =>
    m.view().content.split('\n').map((r) => stripAnsi(r)).toList();

final _hint = RegExp(r'\^ (\d+) lines above fold - PgUp');

/// The `^ N lines above fold` count in the frame, or null when absent.
int? _hintN(List<String> rows) {
  for (final row in rows) {
    final m = _hint.firstMatch(row);
    if (m != null) return int.parse(m.group(1)!);
  }
  return null;
}

bool _hasPercent(List<String> rows) =>
    rows.any((r) => RegExp(r'\d+%').hasMatch(r));

void main() {
  group('AC1 — above-the-fold indicator during tail-follow', () {
    test('a long single-turn transcript shows N = wrapped-hidden rows', () {
      // 40 short (non-wrapping) lines, one turn from row 0: vh = 24 - 5
      // (progress + 2 rules + status + input) = 19, so 21 rows hide above.
      final model = _build(
        termHeight: 24,
      ).copyWith(outputLines: [for (var i = 0; i < 40; i++) 'row $i']);
      final rows = _rowsOf(model);
      expect(_hintN(rows), 21, reason: 'N must equal wrapped-hidden rows');
      // The window content confirms the geometry: rows 21..39 on glass.
      expect(rows.first, contains('row 21'));
      expect(rows[18], contains('row 39'));
    });

    test('N counts WRAPPED rows, not logical lines (CJK-safe)', () {
      // 10 lines of 90 cells each wrap to 2 rows at width 80 → 20 wrapped
      // rows; turn starts at logical line 5 = wrapped row 10 (short turn,
      // anchor = 10) — the hint names 10 hidden WRAPPED rows, not 5 lines.
      final wide = '要約' * 22 + 'x'; // 44 wide glyphs (88 cells) + 1 = 89 cells
      final model = _build().copyWith(
        outputLines: [for (var i = 0; i < 10; i++) '$wide $i'],
        turnStartLine: 5,
      );
      final rows = _rowsOf(model);
      expect(_hintN(rows), 10, reason: 'N counts wrapped rows');
    });

    test('no hint at offset 0 and none when the tail latch is detached', () {
      final short = _build().copyWith(outputLines: ['just one row']);
      expect(_hintN(_rowsOf(short)), isNull,
          reason: 'E3: one-row response, zero hidden rows');

      final long = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      );
      final scrolled = _send(
        long,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      final rows = _rowsOf(scrolled);
      expect(_hintN(rows), isNull, reason: 'detached: the percent rule owns');
      expect(_hasPercent(rows), isTrue);
    });
  });

  group('AC2 — scrolling interacts with the hint count', () {
    // Short current turn: the window anchors at the turn start (row 35)
    // above the live edge (bottom = 21) — the pad zone. Wheel-ups ride
    // down WITHOUT detaching (the live edge stays on the glass) and the
    // hint count visibly decrements.
    FaTuiModel padZone() => _build().copyWith(
      outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      turnStartLine: 35,
      scrollOffset: 35, // parked at the anchor, as every follow path keeps it
    );

    test('wheel-up decrements N while the latch holds', () {
      expect(_hintN(_rowsOf(padZone())), 35);
      final up3 = _send(
        padZone(),
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(up3.followTail, isTrue, reason: 'live edge still on glass');
      expect(_hintN(_rowsOf(up3)), 32);
    });

    test('scrolling past the fold detaches, offset 0 has no hint, '
        'scrolling back restores tail-follow', () {
      var model = padZone();
      for (var i = 0; i < 5; i++) {
        model = _send(
          model,
          MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
        );
      }
      expect(model.followTail, isFalse, reason: '35 - 15 = 20 < bottom 21');
      expect(_hasPercent(_rowsOf(model)), isTrue);

      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      var top = _rowsOf(model);
      expect(model.scrollOffset, 1, reason: '35 - 19 vh, clamped');
      expect(_hintN(top), isNull, reason: 'detached: no hint at the top');
      expect(_hasPercent(top), isTrue, reason: 'percent shown, detached');

      // Page back down: landing on/below the bottom re-latches follow,
      // the percent rule clears and the hint returns with the anchor N.
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      expect(model.followTail, isFalse, reason: '20 still above bottom 21');
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      top = _rowsOf(model);
      expect(model.followTail, isTrue);
      expect(_hasPercent(top), isFalse);
      expect(_hintN(top), 35);
    });

    test('long turn: page-down past the fold restores tail-follow', () {
      var model = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
        scrollOffset: 21, // anchor = bottom = 40 - 19 vh
      );
      expect(_hintN(_rowsOf(model)), 21);
      model = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(model.followTail, isFalse);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      expect(model.followTail, isTrue);
      expect(_hintN(_rowsOf(model)), 21, reason: 're-anchored at the fold');
      expect(_hasPercent(_rowsOf(model)), isFalse);
    });
  });

  group('AC3 — clean turn boundary, no cross-turn bleed', () {
    test('a two-turn scripted session never shows turn N-1 after submit',
        () async {
      const turnOne = 'TURN-ONE-MARKER explain the bug';
      const turnTwo = 'TURN-TWO-MARKER now fix it';
      var model = _build(termHeight: 12);

      // Turn 1: submit, stream past the viewport, settle.
      model = model.copyWith(inputText: turnOne);
      var result = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
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

      // The very first frame after submit anchors at turn 2's echo.
      expect(frames.first.any((r) => r.contains('TURN-TWO-MARKER')), isTrue,
          reason: 'the fresh prompt is on the glass immediately');
      for (final frame in frames) {
        expect(frame, isNot(anyOf([
          contains('TURN-ONE-MARKER'),
          contains('alpha answer'),
        ])), reason: 'turn N-1 residue above the prompt line');
      }
    });

    test('a short turn pads blanks below instead of showing turn N-1', () {
      // 40 rows on glass, current turn starts at row 35: the window is
      // rows 35..39 plus blank padding — nothing from rows 0..34.
      final model = _build().copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
        turnStartLine: 35,
      );
      final rows = _rowsOf(model);
      final history = rows.take(19).toList();
      expect(history.first, contains('row 35'));
      expect(history[4], contains('row 39'));
      expect(
        history.skip(5).any((r) => r.trim().isNotEmpty),
        isFalse,
        reason: 'pad zone must be blank, not turn N-1 text',
      );
    });
  });

  group('AC4 — the hint lives inside the frame budget', () {
    test('one-row viewport history still paints the hint without stealing '
        'the prompt chrome', () {
      // termHeight 6: legacy fixed chrome 5 → history 1 → 39 rows hide.
      final model = _build(termHeight: 6).copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      );
      final rows = _rowsOf(model);
      expect(rows, hasLength(6), reason: 'frame exactly fits the glass');
      expect(_hintN(rows), 39);
      expect(rows.last, contains('test-model'),
          reason: 'status/prompt rows untouched');
      expect(rows[0], contains('row 39'), reason: 'live edge still on glass');
    });

    test('zero-history viewport yields the hint entirely (E2)', () {
      // termHeight 5: chrome alone fills the glass, history = 0.
      final model = _build(termHeight: 5).copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      );
      final rows = _rowsOf(model);
      expect(rows, hasLength(5));
      expect(_hintN(rows), isNull,
          reason: 'a window that shows no rows announces nothing');
      expect(rows.last, contains('test-model'),
          reason: 'prompt row never moves for the hint');

      // The composer tail is identical whether or not rows hide above.
      final calm = _build(
        termHeight: 5,
      ).copyWith(outputLines: ['tiny']);
      expect(
        _rowsOf(model).skip(1),
        _rowsOf(calm).skip(1),
        reason: 'hint absence keeps the bottom chrome byte-stable',
      );
    });
  });

  group('AC5 — reset-to-bottom paths re-evaluate the hint', () {
    List<String> longHistory() => [for (var i = 0; i < 40; i++) 'row $i'];

    test('submit re-anchors the hint at the new turn', () async {
      var model = _build(termHeight: 12).copyWith(outputLines: longHistory());
      expect(_hintN(_rowsOf(model)), 33, reason: '40 - 7 vh');

      model = model.copyWith(inputText: 'second question');
      final result = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
      model = result.$1 as FaTuiModel;
      await result.$2?.call();

      // The echo lands at wrapped row 40 (every line is one row); the
      // hint names it, not the stale pre-submit fold count.
      expect(_hintN(_rowsOf(model)), 40,
          reason: 'window anchored at the new echo');
    });

    test('steering re-anchors the hint at the steered echo', () {
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
      final n = _hintN(_rowsOf(model));
      expect(n, 40, reason: 'window anchored at the steered echo row');
    });

    test('queue drain re-anchors the hint at the drained echo', () {
      var model = _build().copyWith(
        outputLines: longHistory(),
        busy: true,
        queue: const [QueuedMessage('drained text')],
      );
      model = _send(model, DrainQueueMsg(Completer<List<String>>()));
      expect(_hintN(_rowsOf(model)), 40,
          reason: 'fresh fold count for the drained turn');
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
      expect(_hintN(_rowsOf(scrolled)), isNull,
          reason: 'detached: percent rule, never both at once');
    });

    test('native wheel does not repaint or move the viewport', () {
      final model = _build(mouseCapture: false).copyWith(
        outputLines: [for (var i = 0; i < 40; i++) 'row $i'],
      );
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
    test('E1: resize mid-stream recomputes the hint, latch survives', () {
      var model = _build(termHeight: 24).copyWith(
        outputLines: [for (var i = 0; i < 60; i++) 'row $i'],
      );
      expect(_hintN(_rowsOf(model)), 41, reason: '60 - 19 vh');

      model = _send(model, WindowSizeMsg(80, 12));
      expect(model.followTail, isTrue, reason: 'shrink keeps the latch');
      expect(_hintN(_rowsOf(model)), 53, reason: '60 - 7 vh');

      model = _send(model, WindowSizeMsg(80, 30));
      expect(_hintN(_rowsOf(model)), 35, reason: '60 - 25 vh');
      expect(_rowsOf(model), hasLength(30));
    });

    test('E3: one-row response never shows the hint (idle and busy)', () {
      for (final busy in [false, true]) {
        final model = _build(busy: busy).copyWith(
          outputLines: ['single line'],
        );
        expect(_hintN(_rowsOf(model)), isNull, reason: 'busy=$busy');
      }
    });

    test('E5: tall from the first streamed row — hint present from the '
        'first overflow', () {
      var model = _build(termHeight: 24);
      for (var i = 0; i < 20; i++) {
        model = _send(model, OutputMsg('stream $i', newline: true));
      }
      // 21 wrapped rows (newline appends a trailing blank), vh 19: two
      // rows hidden already.
      final rows = _rowsOf(model);
      expect(_hintN(rows), 2, reason: 'symptom 1 verbatim');
      expect(rows.first, contains('stream 2'),
          reason: 'the hidden head is named, not lost');
    });
  });

  group('AC7 — byte-identical rendering where the feature is inert', () {
    Map<String, String> loadGoldens() {
      final goldens = <String, String>{};
      for (final line in File(
        'test/cli/fa_tui_viewport_fold_golden.txt',
      ).readAsLinesSync()) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final split = line.split(' ');
        goldens[split[0]] = split[1];
      }
      return goldens;
    }

    String render(FaTuiModel model) {
      final buf = StringBuffer();
      CellRenderer(
        output: _BufSink(buf),
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
      expect(render(short), goldens['F1'],
          reason: 'F1: bare frame, offset 0 — no hint row content');

      var long = _build();
      for (var i = 0; i < 60; i++) {
        long = _send(long, OutputMsg('stream line $i', newline: true));
      }
      var up = _send(
        long,
        KeyPressMsg(const TeaKey(code: KeyCode.pageUp)),
      );
      up = _send(up, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      expect(render(up), goldens['F3'],
          reason: 'F3: detached percent frame — legacy bytes untouched');
    });

    test('anchored multi-turn frame snapshot (drift guard)', () {
      final goldens = loadGoldens();
      var long = _build();
      for (var i = 0; i < 60; i++) {
        long = _send(long, OutputMsg('stream line $i', newline: true));
      }
      final turned = long.copyWith(turnStartLine: 10);
      // The snapshot pins the hint row AND every stable region; any
      // accidental layout drift fails here (REG blocks merge).
      expect(_hintN(_rowsOf(turned)), isNotNull);
      expect(render(turned), goldens['F4'], reason: 'F4 canonical frame');
    });
  });
}

/// Minimal [IOSink] over a [StringBuffer] capturing what the renderer would
/// write to the tty (same as fa_tui_sticky_scroll_test.dart).
final class _BufSink implements IOSink {
  _BufSink(this._buf);
  final StringBuffer _buf;

  @override
  void write(Object? obj) => _buf.write(obj);
  @override
  void writeln([Object? obj = '']) => _buf.writeln(obj);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
}
