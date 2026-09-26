/// Unit proof for the gh-982 flake diagnosis: the PTY harness's raw
/// viewport exposes xterm BUFFER-CELL MATERIALIZATION artifacts, so
/// cross-frame raw equality can fail on a screen that is
/// content-identical — and `frameContentLines` is the comparison form
/// that stays faithful to the content.
///
/// The two dart_tui paint paths disagree about row tails
/// (vendor/dart_tui/lib/src/renderer.dart):
///
/// - the scroll fast path ends every painted row with an erase
///   (`_paintRow` → `CSI K`; emulator cells become EMPTY, codepoint 0,
///   invisible to `BufferLine.getText`),
/// - the cell-diff path (`_diffAndEmit`) writes only changed cells and
///   never erases the tail — whatever an earlier full repaint
///   materialized there (explicit space cells) stays.
///
/// Which history a logical row carries depends on the renderer's
/// frame-shift heuristics, i.e. on platform timing — macOS/fa-m5 vs
/// linux produced different histories for the same scenario and the
/// `· older` freeze row failed a raw list equality despite
/// byte-identical counts (gh-982).
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

import 'pty_harness.dart';

const _olderRow =
    '⟳ Background jobs (5) · 5 running · 0 done · 0 lost · older';

void main() {
  group('frameContentLines', () {
    test('written-space and EL-erased tails of the same row normalize '
        'equal', () {
      final padded = [_olderRow.padRight(120)];
      final erased = [_olderRow];
      expect(
        padded,
        isNot(equals(erased)),
        reason: 'precondition: the raw buffer really does differ',
      );
      expect(frameContentLines(padded), frameContentLines(erased));
    });

    test('genuine content differences stay visible', () {
      final fiveRunning = [_olderRow];
      final fourRunning = [
        '⟳ Background jobs (5) · 4 running · 1 done · 0 lost · older',
      ];
      expect(
        frameContentLines(fiveRunning),
        isNot(frameContentLines(fourRunning)),
        reason: 'the freeze proof must still catch re-derived counts',
      );
    });

    test('strips only trailing blanks — leading layout is preserved', () {
      final frame = ['  indented  ', '', _olderRow];
      expect(frameContentLines(frame), ['  indented', '', _olderRow]);
    });
  });

  group('emulator materialization (the gh-982 artifact class)', () {
    test('same row text reads padded or unpadded depending on the '
        'renderer path that last touched the line', () {
      final written = Terminal(maxLines: 100)
        ..resize(120, 24)
        ..write('\x1b[5;1H${_olderRow.padRight(120)}');
      final erased = Terminal(maxLines: 100)
        ..resize(120, 24)
        ..write('\x1b[5;1H${_olderRow.padRight(120)}')
        ..write('\x1b[5;1H$_olderRow\x1b[K');

      String lineOf(Terminal t) =>
          t.buffer.lines[t.buffer.scrollBack + 4].getText();

      expect(lineOf(written), isNot(lineOf(erased)));
      expect(
        lineOf(written).trimRight(),
        lineOf(erased).trimRight(),
      );
    });
  });
}
