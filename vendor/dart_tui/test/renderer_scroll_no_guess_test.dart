// #2311: the CellRenderer scroll fast path must never GUESS the shift.
// On repetitive transcripts (repeated edit rows + footer counters that
// change every frame) a majority vote + mismatch budget picks a plausible
// but wrong k; the physical screen then mis-scrolls and every later cell
// diff lands on false beliefs (stale footers, fused digits, duplicated
// tokens). Contract pinned here:
//   AC1  ambiguous shifts (>=2 viable k) emit NO scroll op -> plain diff.
//   AC2  budget only ever accepts FULLY enumerable mismatches; a pinned
//        leading edge right after a scroll frame forces invalidate() and a
//        full repaint (belief self-heal).
//   AC3  width-ambiguous glyph rows are never trusted matches — they
//        repaint WHOLE on the scroll path.
//   AC4  every external-write path (insertAbove family) and resize drops
//        the cached frame belief.
//   AC5  REG: non-repetitive true scrolls still emit the cheap op, in
//        BOTH alt-screen and inline modes; k>40 still falls through.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:dart_tui/src/renderer.dart';
import 'package:dart_tui/src/view.dart';

View newView(String s) => View(content: s);

void main() {
  bool hasScrollOp(String out) => RegExp(r'\x1b\[[0-9]+[ST]').hasMatch(out);

  CellRenderer rendererWith(StringBuffer buf, {required bool altScreen}) {
    return CellRenderer(
      output: _SinkForward(buf),
      logSink: null,
      defaultAltScreen: altScreen,
      defaultHideCursor: false,
    );
  }

  group('AC1: ambiguous shifts never emit a scroll op (#2311)', () {
    test('one coincidental overlap row cannot prove a full redraw scrolled',
        () {
      // Exact review repro: only next[0] == prev[11] (both blank) matches
      // for k=11. That single coincidence must not eject r0..r10 into the
      // terminal scrollback when every other row is a distinct redraw.
      final prev = [
        ...[for (var i = 0; i <= 10; i++) 'r$i'],
        ''
      ].join('\n');
      final next = ['', for (var i = 1; i <= 11; i++) 'n$i'].join('\n');
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      final out = buf.toString();
      expect(hasScrollOp(out), isFalse,
          reason: 'k=11 has only one blank-row coincidence: no scroll op');
      expect(out, contains('n11'));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '');
    });

    test('periodic transcript: >=2 viable k => plain diff, converged frame',
        () {
      // 12 rows, content period 3 (4x 'e', 4x 'f', 4x 'g' — the repeated
      // edit-row shape); true shift is 2 with rewritten chrome rows at
      // 2/5/8 and a fresh tail. k=5, k=8 and k=11 are all viable under the
      // old majority+budget vote (old code emitted CSI S 5 — wrong by 3).
      final prev = [for (var i = 0; i < 12; i++) 'efg'[i % 3]].join('\n');
      final shifted = [for (var i = 0; i < 10; i++) 'efg'[(i + 2) % 3]];
      shifted[2] = 'z';
      shifted[5] = 'z';
      shifted[8] = 'z';
      final next = [...shifted, 'n10', 'n11'].join('\n');
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      final out = buf.toString();
      expect(hasScrollOp(out), isFalse,
          reason: 'ambiguous shift: multiple viable k — no scroll op may '
              'fire; the frame must converge via the plain cell diff');
      expect(out, contains('n10'));
      // The diff fallback converges: a follow-up idle frame stays silent.
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '');
    });

    for (final altScreen in [false, true]) {
      test(
          'repeated rows + changing footer counter => diff '
          '(altScreen: $altScreen)', () {
        // The money-session shape: 11 identical rows + a footer counter
        // that changes every frame. k=1 is byte-exact but k=2..9 are
        // budget-viable too — ambiguous, so no op may fire.
        final prev = [
          ...[for (var i = 0; i < 11; i++) 'x'],
          'tokens: 63',
        ].join('\n');
        final next = [
          ...[for (var i = 0; i < 10; i++) 'x'],
          'tokens: 63',
          'tokens: 69',
        ].join('\n');
        final buf = StringBuffer();
        final renderer = rendererWith(buf, altScreen: altScreen);
        renderer.render(newView(prev));
        buf.clear();
        renderer.render(newView(next));
        final out = buf.toString();
        expect(hasScrollOp(out), isFalse,
            reason: 'repetitive frame with a changing footer: the shift is '
                'ambiguous — diff/repaint, never a guessed op');
        buf.clear();
        renderer.render(newView(next));
        expect(buf.toString(), '');
      });
    }
  });

  group('AC2: budget enumerability + post-scroll belief self-heal (#2311)', () {
    test('accepted shift repaints every enumerated mismatch row whole', () {
      // Sole viable k=1; one rewritten chrome row inside the overlap.
      // The op may fire, but the mismatch row must be repainted whole.
      final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
      final next = [
        'row-1',
        'row-2',
        'spinner', // enumerated mismatch — repainted after the op
        'row-4',
        'row-5',
        'row-6',
        'row-7',
        'row-8',
        'row-9',
        'row-10',
      ].join('\n');
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(),
          '\x1b[1S\x1b[10;1Hrow-10\x1b[K\x1b[3;1Hspinner\x1b[K');
    });

    test('pinned edge right after a scroll frame => invalidate + full repaint',
        () {
      // Frame 1 takes the scroll fast path (sole k=1, edge changes).
      // Frame 2 pins a contentful row 0 while history shifts beneath it:
      // the static-edge invariant (#761) fails right after a scroll — the
      // previous op's belief may be wrong, so the renderer must drop the
      // cached grid and repaint from scratch instead of diffing on it.
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView([for (var i = 0; i < 10; i++) 'r$i'].join('\n')));
      renderer
          .render(newView([for (var i = 1; i <= 10; i++) 'r$i'].join('\n')));
      expect(RegExp(r'\x1b\[1S').hasMatch(buf.toString()), isTrue,
          reason: 'precondition: frame 2 took the scroll fast path');
      buf.clear();
      // Frame 3: row 0 pinned ('r1'), history shifted beneath it.
      final pinned = [
        'r1',
        for (var i = 3; i <= 11; i++) 'r$i',
      ].join('\n');
      renderer.render(newView(pinned));
      final out = buf.toString();
      expect(hasScrollOp(out), isFalse,
          reason: 'static leading edge inhibits the op (#761)');
      expect(out, contains('\x1b[1;1H\x1b[K'),
          reason: 'post-scroll invariant failure must force a full repaint '
              '(belief invalidated), not a surgical diff on the old belief');
      expect(out, contains('r11'));
      // Healed: the next idle frame is silent again.
      buf.clear();
      renderer.render(newView(pinned));
      expect(buf.toString(), '');
    });
  });

  group('AC3: width-ambiguous rows never ride the scroll as trusted (#2311)',
      () {
    test('unstable-glyph overlap row repaints whole even when cell-equal', () {
      // '⏰ tail' (U+23F0 — emoji heuristic 2-cell width) matches cell-wise
      // across the shift, but our width table disagrees with wcwidth
      // terminals: trusting it as "matched" (skip) would leave the
      // previous frame's physical bytes on screen. It must be repainted.
      final prev = [
        for (var i = 1; i <= 9; i++) 'r$i',
        '⏰ tail',
      ].join('\n');
      final next = [
        for (var i = 2; i <= 9; i++) 'r$i',
        '⏰ tail',
        'r10',
      ].join('\n');
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      final out = buf.toString();
      expect(RegExp(r'\x1b\[1S').hasMatch(out), isTrue,
          reason: 'the shift itself is sole and byte-proven for stable rows');
      expect(out, contains('\x1b[9;1H⏰ tail\x1b[K'),
          reason: 'the width-ambiguous overlap row must repaint WHOLE, '
              'never be skipped as a trusted match');
      expect(out, contains('\x1b[10;1Hr10\x1b[K'));
    });
  });

  group('AC4: external writes + resize drop the cached frame (#2311)', () {
    test('inline insertAbove invalidates the belief (next frame repaints)', () {
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView('alpha\nbeta'));
      renderer.insertAbove('printed above');
      buf.clear();
      // Same view content again: the belief must have been dropped by the
      // external writeln, so this is a full repaint — not a 0-byte skip.
      renderer.render(newView('alpha\nbeta'));
      final out = buf.toString();
      expect(out, contains('\x1b[1;1H\x1b[K'),
          reason: 'insertAbove scrolls the physical screen; the cached grid '
              'is stale and the next frame must repaint from scratch');
      expect(out, contains('alpha'));
    });

    test('grep-guard: every external-write path + resize invalidates', () {
      final rendererSrc = File('lib/src/renderer.dart').readAsStringSync();
      final programSrc = File('lib/src/program.dart').readAsStringSync();

      String methodBody(String signature) {
        // lastIndexOf: CellRenderer is the LAST class declaring these
        // (the TeaRenderer interface and NilRenderer come first).
        final start = rendererSrc.lastIndexOf(signature);
        expect(start, greaterThanOrEqualTo(0),
            reason: '$signature not found in renderer.dart');
        final from = rendererSrc.indexOf('\n', start);
        final end = rendererSrc.indexOf('\n  @override', from);
        return rendererSrc.substring(from, end < 0 ? rendererSrc.length : end);
      }

      for (final signature in [
        'void insertAbove(String line) {',
        'void clearScreen() {',
        'void scroll(int n, {bool up = true}) {',
        'void release({bool reset = false}) {',
        'void setAltScreen(bool enabled) {',
      ]) {
        expect(methodBody(signature), contains('_lastGrid = null'),
            reason: '$signature changes screen state and must drop the '
                'cached frame belief');
      }

      // Resize: the geometry-change branch of WindowSizeMsg invalidates.
      expect(
        RegExp(r'msg is WindowSizeMsg[\s\S]{0,600}?_renderer\?\.invalidate\(\);')
            .hasMatch(programSrc),
        isTrue,
        reason: 'resize must invalidate the renderer (#274 MAJOR2)',
      );
    });
  });

  group('AC5 REG: true scrolls keep the cheap op (#2311)', () {
    test('near-full-height scroll with two trusted overlap rows keeps SU', () {
      // k=10 in a 12-row grid leaves two byte-exact, stable overlap rows.
      // Requiring a second trusted row must not disable this large scroll.
      final prev = [for (var i = 0; i < 12; i++) 'r$i'].join('\n');
      final next = [
        'r10',
        'r11',
        for (var i = 2; i < 12; i++) 'n$i',
      ].join('\n');
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      final out = buf.toString();
      expect(out, startsWith('\x1b[10S'));
      expect(RegExp(r'\x1b\[\d+;1H').allMatches(out).length, 10);
      expect(out, contains('n11'));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '');
    });

    for (final altScreen in [false, true]) {
      test(
          'non-repetitive scroll-by-1 emits SU + fresh row '
          '(altScreen: $altScreen)', () {
        final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
        final next = [for (var i = 1; i <= 10; i++) 'row-$i'].join('\n');
        final buf = StringBuffer();
        final renderer = rendererWith(buf, altScreen: altScreen);
        renderer.render(newView(prev));
        buf.clear();
        renderer.render(newView(next));
        final out = buf.toString();
        expect(RegExp(r'\x1b\[1S').hasMatch(out), isTrue);
        expect(out, contains('row-10'));
        buf.clear();
        renderer.render(newView(next));
        expect(buf.toString(), '', reason: 'identical-frame skip unchanged');
      });
    }

    test('k>40 fallthrough: a 41-row shift takes the plain diff', () {
      final prev = [for (var i = 0; i < 50; i++) 'row-$i'].join('\n');
      final next = [
        for (var i = 41; i <= 49; i++) 'row-$i',
        for (var i = 0; i <= 40; i++) 'new-$i',
      ].join('\n');
      final buf = StringBuffer();
      final renderer = rendererWith(buf, altScreen: false);
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      final out = buf.toString();
      expect(hasScrollOp(out), isFalse,
          reason: 'k>40 stays capped: no op may fire for a 41-row shift');
      // The diff fallback converges: a follow-up idle frame stays silent.
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '');
    });
  });
}

/// [TestSink] writes into its own buffer; wrap one so the test asserts a
/// single [StringBuffer] it owns.
class _SinkForward implements IOSink {
  _SinkForward(this._target);
  final StringBuffer _target;
  @override
  void write(Object? obj) => _target.write(obj);
  @override
  void writeln([Object? obj = '']) => _target.writeln(obj);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _target.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _target.writeCharCode(charCode);
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
