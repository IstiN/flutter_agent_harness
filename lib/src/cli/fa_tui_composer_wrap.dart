/// The composer soft-wrap: one logical line to cell-bounded rows
/// (issue #467) — word-boundary preferred, a word wider than the
/// viewport hard-broken (E1), grapheme clusters never split (E2).
///
/// Lives in a part file to keep fa_tui.dart under the line gate (same
/// pattern as fa_tui_rows.dart / fa_tui_mouse.dart).
part of 'fa_tui.dart';

/// One soft-wrapped composer row with the buffer offset (UTF-16 code units
/// into the SOURCE line) where it starts — the cursor maps back through
/// these offsets, so a resize re-wraps while the cursor stays on the same
/// buffer position (issue #467 E3).
final class WrappedComposerRow {
  const WrappedComposerRow(this.text, this.startUnit);

  /// The visible row (break-point spaces at its end dropped).
  final String text;

  /// Code units into the source logical line where this row begins.
  final int startUnit;
}

/// Soft-wraps one logical composer line to [width]-terminal-cell rows
/// (issue #467): word-boundary preferred, a word wider than the viewport
/// hard-breaks (E1, no wrap-point loop), grapheme clusters never split
/// across rows (E2 — the renderer measures cells, not code units, and a
/// row overflowing its width makes the terminal hardware-wrap and desync
/// the frame). Break-point space runs are dropped only where a row breaks;
/// interior runs render verbatim. Always returns at least one row.
List<WrappedComposerRow> wrapComposerRows(String line, int width) =>
    _ComposerWrap(width < 1 ? 1 : width).run(line);

/// Plain-row view of [wrapComposerRows].
List<String> wrapComposerLine(String line, int width) => [
  for (final row in wrapComposerRows(line, width)) row.text,
];

/// The greedy-wrap state machine behind [wrapComposerRows]. One mutable
/// walker per line; kept as a class so every method stays inside the CRAP
/// gate and the wrap rules read one per method.
final class _ComposerWrap {
  _ComposerWrap(this.width);

  /// Row capacity in terminal cells.
  final int width;

  final rows = <WrappedComposerRow>[];
  final _row = StringBuffer();
  final _word = StringBuffer();
  final _pending = StringBuffer(); // space run since the last word
  int _rowCells = 0;
  int _rowStartUnit = 0;
  int _wordCells = 0;
  int _wordStartUnit = 0;
  int _unit = 0; // code units consumed from the line

  List<WrappedComposerRow> run(String line) {
    if (line.isEmpty) return [const WrappedComposerRow('', 0)];
    for (final cluster in line.characters) {
      if (cluster == ' ') {
        _flushWord();
        _pending.write(' ');
      } else {
        if (_word.isEmpty) _wordStartUnit = _unit;
        _word.write(cluster);
        _wordCells += tuiGraphemeWidth(cluster);
      }
      _unit += cluster.length;
    }
    _flushWord();
    if (_row.isNotEmpty || rows.isEmpty) _emitRow();
    return rows;
  }

  /// Rows that end the frame must be flushed verbatim; [_emitRow] is the
  /// single place a row leaves the walker.
  void _emitRow() {
    rows.add(WrappedComposerRow(_row.toString(), _rowStartUnit));
    _row.clear();
    _rowCells = 0;
  }

  /// Lands the pending word on the current row, breaking the row (dropping
  /// the pending space run) when the word does not fit, and hard-breaking
  /// a word wider than the viewport (E1).
  void _flushWord() {
    if (_word.isEmpty) return;
    if (_wordCells > width) {
      _hardBreakWord();
      return;
    }
    if (_rowCells == 0) {
      _row.write(_word);
      _rowCells = _wordCells;
      _rowStartUnit = _wordStartUnit;
    } else if (_rowCells + _pending.length + _wordCells <= width) {
      _row
        ..write(_pending)
        ..write(_word);
      _rowCells += _pending.length + _wordCells;
    } else {
      _emitRow();
      _row.write(_word);
      _rowCells = _wordCells;
      _rowStartUnit = _wordStartUnit;
    }
    _word.clear();
    _wordCells = 0;
    _pending.clear();
  }

  /// E1: a word wider than the viewport slices into width-cell rows —
  /// clusters are never cut, and every slice starts a fresh row so two
  /// wrap points can never fight over the same cluster (no loop).
  void _hardBreakWord() {
    if (_rowCells > 0) _emitRow();
    final clusters = _word.toString().characters.toList();
    final slice = StringBuffer();
    var sliceCells = 0;
    var sliceStartUnit = _wordStartUnit;
    var sliceUnits = 0;
    for (final cluster in clusters) {
      final cells = tuiGraphemeWidth(cluster);
      if (sliceCells > 0 && sliceCells + cells > width) {
        rows.add(WrappedComposerRow(slice.toString(), sliceStartUnit));
        slice.clear();
        sliceStartUnit += sliceUnits;
        sliceCells = 0;
        sliceUnits = 0;
      }
      slice.write(cluster);
      sliceCells += cells;
      sliceUnits += cluster.length;
    }
    // The trailing slice becomes the current row (later words may join it).
    _row.write(slice);
    _rowCells = sliceCells;
    _rowStartUnit = sliceStartUnit;
    _word.clear();
    _wordCells = 0;
    _pending.clear();
  }
}
