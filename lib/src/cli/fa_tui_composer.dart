part of 'fa_tui.dart';

/// FaTuiModel's composer layout — split out of `fa_tui.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so
/// the extension sees the model's private members (issue #467).

extension _TuiComposerLayout on FaTuiModel {
  /// The input block's height in PHYSICAL rows: the text soft-wraps to the
  /// terminal width, so a long single line occupies several rows. All
  /// layout math (viewport height, cursor homing) must use this count —
  /// the raw `\n` count lies once a line wraps.
  int get _inputLineCount => _sentEchoPinActive
      ? _sentEchoRows(termWidth).length
      : _wrappedInput().$1.length;

  /// Whether the composer region currently pins the sent echo: a turn is
  /// running, nothing is being typed, a submitted message is on hand, and
  /// the top sticky is not already showing it (scrolled out). While pinned,
  /// the history window hides the echo block ([_visibleWrappedRows]) so the
  /// message renders EXACTLY once — in the composer region, where the
  /// owner's #467 width-clip AC reads it back mid-run.
  bool get _sentEchoPinActive =>
      busy &&
      inputText.isEmpty &&
      sentEchoLines.isNotEmpty &&
      !_stickyActive;

  /// The pinned sent echo rows: a dim full-width rule over the message
  /// wrapped to width, each row padded to the full user-message band so a
  /// repaint never leaves stale tail cells.
  List<String> _sentEchoRows(int width) {
    final w = width < 1 ? 1 : width;
    final rows = <String>[_dim('─' * w)];
    for (final line in sentEchoLines) {
      for (final slice in wrapAnsiLine(line, w)) {
        final pad = (w - tuiTextWidth(slice)).clamp(0, w);
        rows.add(
          '${tuiUserMessageBgSgr()}${tuiUserMessageTextSgr()}$slice'
          '${' ' * pad}\x1b[0m',
        );
      }
    }
    return rows;
  }

  /// The history window's rows with the echo block removed while the sent
  /// echo is pinned in the composer region — the message must not render
  /// twice ("no pinned duplicate" contract). Row math above the span is
  /// untouched; the reply flows straight under the pinned block.
  List<String> _visibleWrappedRows(List<String> wrapped) {
    if (!_sentEchoPinActive) return wrapped;
    final starts = _wrapCache.lineStartRows;
    if (stickyIndex < 0 || stickyIndex + 1 >= starts.length) return wrapped;
    final echoEndLine = (stickyIndex + stickyEchoLineCount).clamp(
      0,
      starts.length - 1,
    );
    final startRow = starts[stickyIndex];
    final endRow = starts[echoEndLine];
    if (endRow <= startRow || endRow > wrapped.length) return wrapped;
    return [...wrapped]..removeRange(startRow, endRow);
  }

  /// The pinned sent echo painted in place of the empty input row; the
  /// caret homes to the block's first row (typing releases the pin).
  (int, int) _writeSentEcho(StringBuffer b, int baseRow) {
    final rows = _sentEchoRows(termWidth);
    _hitRegions.add(
      TuiHitRegion(
        x: 0,
        y: baseRow,
        w: termWidth,
        h: rows.length,
        kind: TuiRegionKind.composer,
      ),
    );
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) b.writeln();
      b.write(rows[i]);
    }
    b.writeln();
    return (0, 0);
  }

  /// Truncates [text] to [maxWidth] (default: the terminal width) with an
  /// ellipsis. Every chrome row (status, menu items) must fit on one
  /// terminal row: a soft-wrapped chrome line desyncs the renderer's row
  /// math and smears the frame on every repaint.
  /// Truncates [text] to the terminal width in terminal cells (not UTF-16
  /// units) so wide characters cannot push chrome rows past the width.
  String _fitWidth(String text, [int? maxWidth]) =>
      tuiFitWidth(text, maxWidth ?? termWidth);

  int _viewportHeightFor(int width, int height) {
    const progressH = 1;
    // The input zone is framed by a rule above and a rule below it.
    const inputFrameH = 2;
    const statusH = 1;
    final busyH = busy ? 1 : 0;
    final scheduledH = scheduledCount > 0 ? 1 : 0;
    final waitingH = _waitingRowLines().length;
    // The background-job board's live rows (issue #429) render between the
    // menu and the busy row — unreserved, a mid-run tool row pushed the
    // whole frame past the physical height and the terminal scrolled stale
    // rows into the composer region (issue #467 artifact evidence).
    final jobBoardH = jobBoardLines.length;
    // The pinned user echo (Copilot-style sticky) is written ABOVE the
    // history window — equally unreserved, it overflowed the bottom edge
    // by its own row count and scrolled the status row into the composer
    // (owner evidence #2, issue #467).
    final stickyH = _stickyActive ? _formattedStickyRows(width).length : 0;
    final queueH = queue.isEmpty ? 0 : queue.length + 2;
    final promptH = prompt != null ? tuiPromptRowCount(prompt!, width) + 2 : 0;
    final used =
        progressH +
        stickyH +
        _menuReservedLines +
        busyH +
        scheduledH +
        waitingH +
        jobBoardH +
        queueH +
        promptH +
        inputFrameH +
        statusH +
        _inputLineCount;
    // Clamp to the physical height (floor 0): a ≥3 floor on a tiny terminal
    // would promise rows the screen does not have and break the pure-scroll
    // → CSI S 1:1 mapping (issue #274 review minor).
    return (height - used).clamp(0, height);
  }

  int get _viewportHeight => _viewportHeightFor(termWidth, termHeight);

  /// The status row, fitted AND padded to the terminal width: a shorter new
  /// status (e.g. switching from a long model id to a short one) must
  /// overwrite the previous row's tail — the renderer only rewrites the
  /// cells the new content covers. Both operations are cell-width aware
  /// (grapheme clusters): UTF-16 padding underpads any status carrying wide
  /// characters and stale cells survive on the right.
  String _statusRow() => _dim(
    tuiPadRight(tuiFitWidth(callbacks.statusLine(), termWidth), termWidth),
  );

  /// The framed input lines with horizontal cursor-window scrolling; returns
  /// the cursor's input line index and screen column for the cursor home.
  /// Registers the composer hit-region (issue #278): click = caret move.
  (int, int) _writeInputLines(StringBuffer b, int baseRow) {
    if (_sentEchoPinActive) return _writeSentEcho(b, baseRow);
    final (rows, cursorRow, cursorCol) = _wrappedInput();
    _hitRegions.add(
      TuiHitRegion(
        x: 0,
        y: baseRow,
        w: termWidth,
        h: rows.length,
        kind: TuiRegionKind.composer,
      ),
    );
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) b.writeln();
      b.write(rows[i]);
    }
    b.writeln();
    return (cursorRow, cursorCol);
  }

  /// The input text soft-wrapped to the terminal width (the whole prompt
  /// stays visible as a paragraph — no horizontal clipping), plus the
  /// cursor's row/column inside the wrapped block. A cursor sitting exactly
  /// past a full-width chunk gets the empty trailing row it points at, so
  /// the row count is cursor-dependent — [_inputLineCount] uses this same
  /// computation and the two never disagree.
  (List<String>, int, int) _wrappedInput() {
    final width = termWidth < 1 ? 1 : termWidth;
    final logical = inputText.split('\n');
    final beforeCursor = inputText.substring(0, cursor);
    final cursorLogicalLine = '\n'.allMatches(beforeCursor).length;
    final lastNl = beforeCursor.lastIndexOf('\n');
    final cursorColInLine = lastNl < 0
        ? beforeCursor.length
        : beforeCursor.length - lastNl - 1;

    final rows = <String>[];
    var cursorRow = 0;
    var cursorCol = 0;
    for (var i = 0; i < logical.length; i++) {
      final lineRows = wrapComposerRows(logical[i], width);
      if (i == cursorLogicalLine) {
        // The row whose buffer offset holds the cursor, and the cursor's
        // CELL column inside it — code-unit arithmetic lies once wide
        // graphemes or dropped break spaces enter the line (issue #467).
        var rowIdx = 0;
        for (var r = 1; r < lineRows.length; r++) {
          if (lineRows[r].startUnit <= cursorColInLine) rowIdx = r;
        }
        cursorRow = rows.length + rowIdx;
        cursorCol = tuiTextWidth(
          logical[i].substring(lineRows[rowIdx].startUnit, cursorColInLine),
        );
        if (cursorColInLine == logical[i].length &&
            cursorColInLine > 0 &&
            cursorCol == width &&
            rowIdx == lineRows.length - 1) {
          // The cursor rests one row past the last full-width row.
          lineRows.add(WrappedComposerRow('', cursorColInLine));
          cursorRow = rows.length + lineRows.length - 1;
          cursorCol = 0;
        }
      }
      for (final wrapped in lineRows) {
        rows.add(wrapped.text);
      }
    }
    return (rows, cursorRow, cursorCol);
  }
}
