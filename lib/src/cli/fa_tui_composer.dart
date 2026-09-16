part of 'fa_tui.dart';

/// FaTuiModel's composer layout — split out of `fa_tui.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so
/// the extension sees the model's private members (issue #467).

extension _TuiComposerLayout on FaTuiModel {
  /// The input block's height in PHYSICAL rows: the text soft-wraps to the
  /// terminal width, so a long single line occupies several rows. All
  /// layout math (viewport height, cursor homing) must use this count —
  /// the raw `\n` count lies once a line wraps.
  int get _inputLineCount => _wrappedInput().$1.length;

  /// Truncates [text] to [maxWidth] (default: the terminal width) with an
  /// ellipsis. Every chrome row (status, menu items) must fit on one
  /// terminal row: a soft-wrapped chrome line desyncs the renderer's row
  /// math and smears the frame on every repaint.
  /// Truncates [text] to the terminal width in terminal cells (not UTF-16
  /// units) so wide characters cannot push chrome rows past the width.
  String _fitWidth(String text, [int? maxWidth]) =>
      tuiFitWidth(text, maxWidth ?? termWidth);

  /// The per-frame layout plan (issue #496): how many rows of every
  /// optional section the frame paints, plus the history window. ONE
  /// computation serves both the budget getter and the painters, so the
  /// painted frame can never disagree with the row math — the old code
  /// floored the viewport at 0 while the pin/board/queue chrome kept
  /// painting unconditionally, the frame overran the physical screen, the
  /// real composer rows never reached the glass and stale rows below the
  /// painted region kept the submitted text + cursor visible (the owner's
  /// "echo duplicates into the input row").
  ///
  /// When the mandatory chrome (progress, busy row, menu, prompt, input
  /// frame, status, input rows) alone would not leave room, optional
  /// sections yield, most dispensable first: job board, waiting rows,
  /// scheduled row, attachment chips, queue block, pinned echo. One
  /// history row is reserved ahead of the optional chrome whenever the
  /// transcript is non-empty: the live edge (the sent echo / newest answer
  /// line) must stay on screen even on a squeezed frame.
  _FramePlan _framePlanFor(int width, int height) {
    const mandatory =
        1 /* progress indicator */ +
        2 /* input frame rules */ +
        1 /* status row */;
    final promptH = prompt != null ? tuiPromptRowCount(prompt!, width) + 2 : 0;
    // Issue #503: the input zone is a YIELDING section, not an unbounded
    // fixed one. A paste-length draft (many composer rows) used to blow
    // `fixed` past the physical height — the budget floored at 0, the
    // painted frame overran the glass, the terminal scrolled and the
    // composer row painted over the status row with the frame rules gone.
    // The input now keeps a cursor window: at least one row (the one the
    // caret is on), never more than the chrome leaves room for.
    final inputWanted = _inputLineCount;
    final inputCap = (height - mandatory - (busy ? 1 : 0) - promptH)
        .clamp(1, height == 0 ? 1 : height);
    final inputVisible = inputWanted < inputCap ? inputWanted : inputCap;
    final inputOffset = _inputWindowOffset(inputVisible);
    final fixed =
        mandatory + (busy ? 1 : 0) + _menuReservedLines + promptH +
        inputVisible;
    final boardWanted = jobBoardLines.length;
    final waitingWanted = _waitingRowLines().length;
    final scheduledWanted = scheduledCount > 0 ? 1 : 0;
    final chipsWanted = attachments.isEmpty ? 0 : attachments.length + 1;
    final queueWanted = queue.isEmpty ? 0 : queue.length + 2;
    final stickyWanted =
        _stickyActive ? _formattedStickyRows(width).length : 0;
    final optionalWanted =
        boardWanted + waitingWanted + scheduledWanted + chipsWanted +
        queueWanted + stickyWanted;
    var budget = (height - fixed).clamp(0, height);
    // Reserve a small live-edge tail (the sent echo lines + the newest
    // tool card) ONLY when the optional chrome would otherwise swallow the
    // whole viewport (squeezed frames): unsqueezed frames keep the exact
    // pre-#496 viewport so nothing else shifts. The reserve is a FLOOR —
    // the sections below consume from the remainder, never the reserve.
    var reserve = 0;
    if (optionalWanted >= budget && budget > 0 && _wrappedLines().isNotEmpty) {
      const liveEdgeRows = 4;
      reserve = liveEdgeRows > budget ? budget : liveEdgeRows;
    }
    var consumable = budget - reserve;
    int section(int wanted) {
      final take = wanted < consumable ? wanted : consumable;
      consumable -= take;
      return take;
    }

    final board = section(boardWanted);
    final waiting = section(waitingWanted);
    final scheduled = section(scheduledWanted);
    final chips = section(chipsWanted);
    final queueTake = section(queueWanted);
    // The queue block yields progressively: the hint row drops first, then
    // the OLDEST queued rows — the `queued (N)` header is the "your typing
    // is not lost" contract and yields last within the block.
    final queueVisible = queueTake >= queueWanted
        ? queue.length
        : (queueTake - 1).clamp(0, queue.length);
    final queueHeader = queueTake > 0;
    final queueHint = queueTake >= queueWanted;
    // The pinned echo is quantized all-or-nothing: a lone pin rule reads
    // as a glitch. When it does not fit, the row stays with history.
    final sticky = stickyWanted <= consumable ? stickyWanted : 0;
    return _FramePlan(
      board: board,
      waiting: waiting,
      scheduled: scheduled,
      chips: chips,
      queue: queueVisible,
      queueHeader: queueHeader,
      queueHint: queueHint,
      sticky: sticky,
      history: consumable + reserve,
      input: inputVisible,
      inputOffset: inputOffset,
    );
  }

  /// The first visible wrapped-input row for a [visible]-row window: the
  /// caret's row stays the window's LAST row (bottom-anchored, like the
  /// history follow) so typing at the tail is always on the glass.
  int _inputWindowOffset(int visible) {
    final (_, cursorRow, _) = _wrappedInput();
    final total = _inputLineCount;
    if (visible >= total) return 0;
    return (cursorRow - visible + 1).clamp(0, total - visible);
  }

  int _viewportHeightFor(int width, int height) =>
      _framePlanFor(width, height).history;

  int get _viewportHeight => _viewportHeightFor(termWidth, termHeight);

  /// The sticky user echo pinned to the top while a run streams and the
  /// echo itself has scrolled out of view (Copilot-style, issue #496:
  /// paints only the plan's visible rows — yields whole when squeezed).
  int _writeStickyEcho(StringBuffer b, int visible) {
    if (!_stickyActive || visible <= 0) return 0;
    final rows = _formattedStickyRows(termWidth);
    final count = visible < rows.length ? visible : rows.length;
    for (var i = 0; i < count; i++) {
      b.writeln(rows[i]);
    }
    return count;
  }

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
  /// The framed input lines with the plan's visible-row cursor window
  /// (issue #503: a tall draft yields rows — the caret's row stays the
  /// window's last). Returns the cursor's input line index INSIDE THE
  /// WINDOW and the screen column for the cursor home. Registers the
  /// composer hit-region (issue #278): click = caret move.
  (int, int) _writeInputLines(StringBuffer b, int baseRow, _FramePlan plan) {
    final (rows, cursorRow, cursorCol) = _wrappedInput();
    final start = plan.inputOffset.clamp(0, rows.length);
    final end = (plan.inputOffset + plan.input).clamp(start, rows.length);
    final visible = rows.sublist(start, end);
    _hitRegions.add(
      TuiHitRegion(
        x: 0,
        y: baseRow,
        w: termWidth,
        h: visible.length,
        kind: TuiRegionKind.composer,
      ),
    );
    for (var i = 0; i < visible.length; i++) {
      if (i > 0) b.writeln();
      b.write(visible[i]);
    }
    b.writeln();
    final inWindow = cursorRow - start;
    return (inWindow < 0 ? 0 : inWindow, cursorCol);
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

/// The visible row counts of one frame's optional sections (issue #496).
/// Produced by [_framePlanFor]; consumed by the budget getter AND the
/// painters so they can never disagree again. [history] is the viewport
/// window; [queue] counts visible queued ROWS — [queueHeader] renders the
/// `queued (N)` badge (it yields last within the block, so a squeezed
/// frame can show the badge alone), [queueHint] the edit hint; the rest
/// are plain visible line counts, already yielded to fit the physical
/// screen.
final class _FramePlan {
  const _FramePlan({
    required this.board,
    required this.waiting,
    required this.scheduled,
    required this.chips,
    required this.queue,
    required this.queueHeader,
    required this.queueHint,
    required this.sticky,
    required this.history,
    this.input = 0,
    this.inputOffset = 0,
  });

  final int board;
  final int waiting;
  final int scheduled;
  final int chips;
  final int queue;
  final bool queueHeader;
  final bool queueHint;
  final int sticky;
  final int history;

  /// The visible wrapped-input rows (issue #503): the input zone yields
  /// through a cursor window instead of overrunning the glass; [input]
  /// counts the painted rows, [inputOffset] is the first painted row.
  final int input;
  final int inputOffset;
}
