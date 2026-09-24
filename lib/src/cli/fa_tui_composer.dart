part of 'fa_tui.dart';

/// FaTuiModel's composer layout — split out of `fa_tui.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so
/// the extension sees the model's private members (issue #467).

extension _TuiComposerLayout on FaTuiModel {
  /// The band composer attachment (#806): the host supplies a snapshot
  /// builder + the status-line engine unless the `tui.classic` kill
  /// switch pinned the legacy chrome.
  bool get _bandAttached =>
      callbacks.statusSnapshot != null && callbacks.statusLineEngine != null;

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
  /// The mandatory fixed-chrome row count for the current frame shape.
  /// Band composer (#806): the top band replaces the composer's top
  /// rule, bottom rule and status footer — the chrome below the scroll
  /// indicator shrinks from three rows to one (the band) and the freed
  /// rows go to history. Prompt mode keeps the legacy layout (the
  /// prompt zone replaces the composer; its footer stays).
  int get _mandatoryChromeRows {
    const legacyMandatory =
        1 /* progress indicator */ +
        2 /* input frame rules */ +
        1 /* status row */;
    const bandMandatory =
        1 /* progress indicator */ +
        1 /* top status band (always owns its row — omp verticalChrome: 1) */;
    return _bandAttached && prompt == null ? bandMandatory : legacyMandatory;
  }

  /// The optional sections' wanted row counts, in consumption order
  /// (issue #496): board, waiting, scheduled, chips, queue, sticky.
  (int, int, int, int, int, int) _optionalSectionWants(int width) {
    final boardWanted = jobBoardLines.length;
    final waitingWanted = _waitingRowLines().length;
    final scheduledWanted = scheduledCount > 0 ? 1 : 0;
    final chipsWanted = attachments.isEmpty ? 0 : attachments.length + 1;
    final queueWanted = queue.isEmpty ? 0 : queue.length + 2;
    final stickyWanted = _stickyActive ? _formattedStickyRows(width).length : 0;
    return (
      boardWanted,
      waitingWanted,
      scheduledWanted,
      chipsWanted,
      queueWanted,
      stickyWanted,
    );
  }

  /// The queue block's progressive yield: the hint row drops first, then
  /// the OLDEST queued rows — the `queued (N)` header is the "your typing
  /// is not lost" contract and yields last within the block.
  (int, bool, bool) _queueYield(int take, int wanted) => (
    take >= wanted ? queue.length : (take - 1).clamp(0, queue.length),
    take > 0,
    take >= wanted,
  );

  _FramePlan _framePlanFor(int width, int height) {
    final inPrompt = prompt != null;
    final mandatory = _mandatoryChromeRows;
    // The scroll-progress indicator row ALWAYS paints — the percent rule
    // while the follow latch is detached, a blank row while following
    // (skipping it shifted every later row on scroll). Its row is the
    // `1 /* progress indicator */` inside [mandatory] — the busy row is
    // counted separately (`busy ? 1 : 0`).
    // Prompt mode (ask/approval): the prompt zone REPLACES the input zone
    // and its bottom rule, and paints its own spacer — the status row is
    // already inside `mandatory` (issue #479 AC4: the old budget charged
    // the prompt path for the input window, the never-painted bottom rule
    // AND the status row twice, so the frame under-filled and left a dead
    // band above the glass).
    final promptH = inPrompt ? tuiPromptRowCount(prompt!, width) + 1 : 0;
    final (inputVisible, inputOffset) = inPrompt
        ? (0, 0)
        : _visibleInputRows(mandatory, height);
    final fixed =
        mandatory -
        (inPrompt ? 1 : 0) /* the input zone's bottom rule never paints */ +
        (busy ? 1 : 0) + _menuReservedLines + promptH + inputVisible;
    final (
      boardWanted,
      waitingWanted,
      scheduledWanted,
      chipsWanted,
      queueWanted,
      stickyWanted,
    ) = _optionalSectionWants(width);
    final optionalWanted =
        boardWanted +
        waitingWanted +
        scheduledWanted +
        chipsWanted +
        queueWanted +
        stickyWanted;
    var budget = (height - fixed).clamp(0, height);
    // Reserve a small live-edge tail (the sent echo lines + the newest
    // tool card) ONLY when the optional chrome would otherwise swallow the
    // whole viewport (squeezed frames): unsqueezed frames keep the exact
    // pre-#496 viewport so nothing else shifts. The reserve is a FLOOR —
    // the sections below consume from the remainder, never the reserve.
    final reserve = _liveEdgeReserve(optionalWanted, budget);
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
    final (queueVisible, queueHeader, queueHint) = _queueYield(
      queueTake,
      queueWanted,
    );
    // The pinned echo is quantized all-or-nothing: a lone pin rule reads
    // as a glitch. When it does not fit, the row stays with history.
    // The taken rows LEAVE the consumable budget — history shrinks by
    // exactly what the echo paints, so the frame's total (sticky +
    // history + indicator + fixed) always equals the physical height and
    // the hard glass guard below never has to crop the echo away (the
    // #502 CI failure: sticky painted but history kept its unsqueezed
    // height, the 14-row frame overran a 12-row terminal and the guard
    // dropped rows from the TOP — the echo first).
    final sticky = stickyWanted <= consumable ? stickyWanted : 0;
    consumable -= sticky;
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

  /// The input zone's visible-row cursor window (issue #503): a
  /// paste-length draft yields rows — at least one row (the one the caret
  /// is on) always stays painted, never more than the chrome leaves room
  /// for. Returns the painted row count and the first painted row.
  (int, int) _visibleInputRows(int fixedChrome, int height) {
    // Issue #503: the input zone is a YIELDING section, not an unbounded
    // fixed one. A paste-length draft (many composer rows) used to blow
    // `fixed` past the physical height — the budget floored at 0, the
    // painted frame overran the glass, the terminal scrolled and the
    // composer row painted over the status row with the frame rules gone.
    final wanted = _inputLineCount;
    final cap = (height - fixedChrome - (busy ? 1 : 0)).clamp(
      1,
      height == 0 ? 1 : height,
    );
    final visible = wanted < cap ? wanted : cap;
    return (visible, _inputWindowOffset(visible));
  }

  /// The live-edge reserve for squeezed frames: [optionalWanted] chrome
  /// rows against a [budget]-row viewport. Zero while anything of the
  /// history fits (unsqueezed frames keep the exact pre-#496 viewport).
  int _liveEdgeReserve(int optionalWanted, int budget) {
    const liveEdgeRows = 4;
    if (optionalWanted < budget || budget <= 0) return 0;
    if (_wrappedLines().isEmpty) return 0;
    return liveEdgeRows > budget ? budget : liveEdgeRows;
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
  ///
  /// While the double-press Ctrl+C window is armed (issue #830), the dim
  /// `press ctrl+c again to exit` hint replaces the status line; the next
  /// keypress disarms and the status returns.
  String _statusRow() => ctrlCArmed
      ? _dim(tuiPadRight(kCtrlCExitHint, termWidth))
      : _dim(
          tuiPadRight(
            tuiFitWidth(callbacks.statusLine(), termWidth),
            termWidth,
          ),
        );

  /// The E1 belt: the engine's ladder is width-exact; a resize race
  /// truncates as the last resort so the row can never hardware-wrap.
  /// Pad after the cut — a truncated wide grapheme can leave the row
  /// short, and stale cells survive on the right of a short row.
  void _writeBeltRow(StringBuffer b, String raw) {
    b.writeln(_dim(tuiPadRight(tuiFitWidth(raw, termWidth), termWidth)));
  }

  /// One rendered span: the role style through the write-time seam, the
  /// band tint behind it unless the band is transparent.
  void _writeBandSpan(
    StringBuffer row,
    (String, StatusLineRoleKey) span,
    TuiTheme theme, {
    required bool idle,
    required double brandT,
    required RgbColor? bandBg,
  }) {
    final style = statusLineStyle(
      span.$2,
      theme: theme,
      idle: idle,
      brandT: brandT,
    );
    final c = FaThemeController.instance;
    row
      ..write(
        c.sgrPrefix(
          bandBg == null ? style : style.copyWith(backgroundRgb: bandBg),
        ),
      )
      ..write(span.$1);
  }

  /// The trailing gap: a transparent band resets and pads plain (the
  /// terminal background shows through); a filled band paints the bandBg
  /// fill flush to the right edge — either way the row stays full-width
  /// so stale cells die.
  void _writeBandGap(
    StringBuffer row,
    int pad,
    Style fill, {
    required bool transparent,
  }) {
    if (pad <= 0) return;
    final c = FaThemeController.instance;
    if (transparent) {
      // Reset first so the gap is plain terminal background.
      if (c.profile != null) row.write('\x1b[0m');
      row.write(' ' * pad);
    } else {
      row
        ..write(c.sgrPrefix(fill))
        ..write(' ' * pad);
    }
  }

  /// The status band row (#806): the omp band attachment — the host
  /// snapshot renders as a flush-left filled powerline band with a soft
  /// opening cap (nerd symbol table only; omp's font-safe table ships no
  /// cap), no frame, rules or corners. The band always owns its row (omp
  /// `verticalChrome: 1`) even when the engine has nothing to render.
  /// Colors flow through [statusLineStyle]/[kStatusLineRoles] at write
  /// time; width math runs on the raw strings (rule #279 E1).
  int _writeStatusBand(StringBuffer b) {
    final snapshot = callbacks.statusSnapshot!();
    final engine = callbacks.statusLineEngine!;
    final spans = engine.renderSpans(snapshot, termWidth);
    final raw = spans.map((s) => s.$1).join();
    if (tuiTextWidth(raw) > termWidth) {
      _writeBeltRow(b, raw);
      return 1;
    }
    final c = FaThemeController.instance;
    final theme = c.current;
    // omp `transparent`: no band fill and no end cap — the terminal
    // background shows through the gap (the #831 round-2 writer fix,
    // mirrored here).
    final transparent = engine.spec.transparent;
    final fill = kStatusLineRoles[StatusLineRoleKey.bandBg]!(theme);
    final bandBg = transparent ? null : fill.backgroundRgb;
    final row = StringBuffer();
    if (bandBg != null && engine.spec.nerdSymbols) {
      // The soft opening cap painted band-bg-as-fg (omp `useBgAsFg`).
      row
        ..write(c.sgrPrefix(Style(foregroundRgb: bandBg)))
        ..write('\u{e0b6}');
    }
    // The brand spans dim with the idle flag. Binary on purpose: the
    // 450 ms tween never engages — the host snapshot carries no
    // timestamps (the #837 review retired the dead fade plumbing).
    final brandT = snapshot.idle ? 0.0 : 1.0;
    for (final span in spans) {
      _writeBandSpan(
        row,
        span,
        theme,
        idle: snapshot.idle,
        brandT: brandT,
        bandBg: bandBg,
      );
    }
    _writeBandGap(
      row,
      termWidth - tuiTextWidth(raw),
      fill,
      transparent: transparent,
    );
    // Close the last span's SGR — only when styling is on (NO_COLOR
    // keeps the band shape-only, zero escapes).
    if (c.profile != null && !transparent) row.write('\x1b[0m');
    b.writeln(row.toString());
    return 1;
  }

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
      if (_activeGutterWidth > 0) {
        // omp band.ts renderRow: the gutter rides every composer row —
        // the border-colored `╰─ ` cue on the first, a plain indent on
        // the continuations (omp `gutter.continuation`).
        b.write(
          i == 0 ? _borderMuted(_composerGutter) : ' ' * _activeGutterWidth,
        );
      }
      b.write(visible[i]);
    }
    // Classic separates the input from the bottom rule + footer below;
    // the band frame ENDS at the input (the band is above), so no
    // trailing row — an over-painted frame would crop from the top and
    // desync the hit-region rows from the painted ones.
    if (!_bandAttached) b.writeln();
    final inWindow = cursorRow - start;
    return (inWindow < 0 ? 0 : inWindow, cursorCol);
  }

  /// The gutter width that actually paints: band rows carry the 3-cell
  /// `╰─ ` cue only when the terminal affords cue + one content cell —
  /// under 4 columns the band degrades to full-width rows. The painter,
  /// the wrap width, the caret home and the click mapping all read this
  /// ONE value so they can never disagree.
  int get _activeGutterWidth =>
      (_bandAttached && termWidth >= _composerGutterWidth + 1)
      ? _composerGutterWidth
      : 0;

  /// The wrap width for the composer's input text: band mode wraps at the
  /// CONTENT width (the gutter owns its columns, omp `lineContentWidth`);
  /// legacy wraps at the full width. [_wrappedInput] and [_inputLineCount]
  /// share it so the row count the budget pays for and the rows the
  /// painter writes can never disagree.
  int get _lineWrapWidth {
    final gutter = _activeGutterWidth;
    final content = termWidth - gutter;
    return content < 1 ? 1 : content;
  }

  /// The cursor's row index WITHIN [lineRows] and its CELL column —
  /// code-unit arithmetic lies once wide graphemes or dropped break
  /// spaces enter the line (issue #467), so the column measures the text
  /// width of the row's prefix.
  (int, int) _cursorCellInRows(
    List<WrappedComposerRow> lineRows,
    String logicalLine,
    int cursorColInLine,
  ) {
    var rowIdx = 0;
    for (var r = 1; r < lineRows.length; r++) {
      if (lineRows[r].startUnit <= cursorColInLine) rowIdx = r;
    }
    final col = tuiTextWidth(
      logicalLine.substring(lineRows[rowIdx].startUnit, cursorColInLine),
    );
    return (rowIdx, col);
  }

  /// True when the cursor rests exactly one row past the last full-width
  /// row of its logical line (#467).
  bool _cursorRestsPastFullRow(
    List<WrappedComposerRow> lineRows,
    String logicalLine,
    int cursorColInLine,
    int rowIdx,
    int cursorCol,
  ) {
    return cursorColInLine == logicalLine.length &&
        cursorColInLine > 0 &&
        cursorCol == _lineWrapWidth &&
        rowIdx == lineRows.length - 1;
  }

  /// The input text soft-wrapped to the wrap width (the whole prompt
  /// stays visible as a paragraph — no horizontal clipping), plus the
  /// cursor's row/column inside the wrapped block. A cursor sitting exactly
  /// past a full-width chunk gets the empty trailing row it points at, so
  /// the row count is cursor-dependent.
  (List<String>, int, int) _wrappedInput() {
    final width = _lineWrapWidth;
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
        final (rowIdx, col) = _cursorCellInRows(
          lineRows,
          logical[i],
          cursorColInLine,
        );
        cursorRow = rows.length + rowIdx;
        cursorCol = col;
        if (_cursorRestsPastFullRow(
          lineRows,
          logical[i],
          cursorColInLine,
          rowIdx,
          col,
        )) {
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
