// The subagent status board's live region (gh-1415): message dispatch +
// the frame painter. One compact line per subagent — glyph, state verb,
// name, age, cost — pre-rendered by the host's TaskBoardRegion
// (subagent_board.dart); the model only stores and paints them.
//
// Lives in a part file to keep fa_tui.dart under the repo's 2800-line
// gate (same pattern as fa_tui_rows.dart).

part of 'fa_tui.dart';

extension _TuiSubagentBoard on FaTuiModel {
  /// The board's push (gh-1415): the host replaces the whole row set; an
  /// empty list hides the region (quiet zero — AC4).
  (Model, Cmd?) _handleSubagentBoard(SubagentBoardMsg msg) =>
      (copyWith(subagentBoardRows: msg.rows), null);

  /// The subagent rows one frame paints — exactly [plan.subagents] of
  /// them, the count the budget paid for (single-source with
  /// [_framePlanFor]). Under a squeezed frame the NEWEST rows keep the
  /// region (the job-board precedent); live rows stay visible, settled
  /// summaries yield first (they are dim one-liners by then).
  List<SubagentBoardRow> _visibleSubagentRows(_FramePlan plan) {
    final rows = subagentBoardRows;
    if (plan.subagents >= rows.length) return rows;
    if (plan.subagents <= 0) return const [];
    return rows.sublist(rows.length - plan.subagents);
  }

  /// Paints the region directly above the busy row: bright rows paint
  /// plain (the live set + the settle flash), settled summaries dim. Every
  /// row clips cell-aware at the live width (resize-safe, E4) — the
  /// renderer's own narrow-width ladder already dropped the preview first
  /// (E1); this belt only fires on a resize race.
  int _writeSubagentBoard(StringBuffer b, int row, _FramePlan plan) {
    for (final boardRow in _visibleSubagentRows(plan)) {
      final text = _clipToWidth(boardRow.text);
      b.writeln(boardRow.bright ? text : _dim(text));
      row++;
    }
    return row;
  }
}
