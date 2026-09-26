// Throwaway probe: does the same logical row read differently depending on
// whether its trailing cells were WRITTEN as spaces or EL-erased?
import 'package:xterm/xterm.dart';

void main() {
  const row = '⟳ Background jobs (5) · 5 running · 0 done · 0 lost · older';

  // History A (cell-diff path residue): a full repaint once wrote the row
  // padded to the glass; the diff renderer later rewrote only the content
  // cells, leaving the stale written spaces in the buffer line.
  final a = Terminal(maxLines: 100);
  a.resize(120, 24);
  a.write('\x1b[5;1H${row.padRight(120)}');
  // History B (scroll fast path): the row lands on a line whose tail is
  // erased (CSI K) — the cells become empty, not spaces.
  final b = Terminal(maxLines: 100);
  b.resize(120, 24);
  b.write('\x1b[5;1H${row.padRight(120)}');
  b.write('\x1b[5;1H$row\x1b[K');

  final lineOf = (Terminal t) => t.buffer.lines[t.buffer.scrollBack + 4].getText();
  print('A padded : "${lineOf(a)}"');
  print('B erased : "${lineOf(b)}"');
  print('A == B   : ${lineOf(a) == lineOf(b)}');
  print('A.trimRight() == B.trimRight() : '
      '${lineOf(a).trimRight() == lineOf(b).trimRight()}');
}
