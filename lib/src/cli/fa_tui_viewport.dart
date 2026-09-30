/// The viewport scroll machinery (issue #827) — follow anchor, turn-boundary
/// pinning, and the shared wrap cache bridge — split out of `fa_tui.dart` to
/// keep it under the repo's 2800-line size gate. Same library (a `part of`),
/// so the extension sees the model's private members; the render state
/// (`_wrapCache`, `turnStartLine`) is declared on [FaTuiModel] itself —
/// extensions cannot add fields.
part of 'fa_tui.dart';

extension _TuiViewport on FaTuiModel {
  /// Applies a user scroll: moves the offset (clamped) and re-evaluates the
  /// follow latch — scrolling up detaches, landing back on the exact bottom
  /// re-attaches.
  FaTuiModel _scrolledTo(int offset) {
    final wrapped = _wrappedLines();
    final next = offset.clamp(0, _scrollTopMax(wrapped));
    return copyWith(
      scrollOffset: next,
      followTail: next >= _scrollBottom(wrapped),
    );
  }

  /// The current turn's first wrapped row (issue #827). -1 (nothing
  /// submitted yet) and out-of-range (a foreign stale index) both return
  /// 0, riding the global bottom exactly like the pre-#827 follow. The
  /// bounded-history head-trim is NOT stale-by-design: every append shifts
  /// the index by the cut ([_turnStartShiftedBy]), so it keeps naming the
  /// echo across 2000+-line turns.
  int _turnStartRow() {
    if (turnStartLine < 0) return 0;
    _wrappedLines(); // refresh the shared wrap cache when stale
    final starts = _wrapCache.lineStartRows;
    if (turnStartLine >= starts.length) return 0;
    return starts[turnStartLine];
  }

  /// The turn-start index after a transcript head-trim dropped [cut] lines
  /// from the head (issue #827): every transcript index shifts by the cut.
  /// A turn whose echo was dropped entirely degrades to -1 — the
  /// pre-#827 global-bottom follow.
  int _turnStartShiftedBy(int cut) {
    if (cut == 0 || turnStartLine < 0) return turnStartLine;
    final shifted = turnStartLine - cut;
    return shifted < 0 ? -1 : shifted;
  }

  /// The follow anchor (issue #827): the live edge, but never below the
  /// current turn's first wrapped row while that turn fits the viewport —
  /// a freshly submitted prompt's window starts at its OWN echo, not at
  /// turn N-1's tail (the cross-turn bleed the sticky echo used to paper
  /// over). Long turns exceed the viewport and the anchor degrades to the
  /// bottom, where the fold indicator owns the explanation.
  int _turnAnchor(List<String> wrapped) {
    final bottom = _scrollBottom(wrapped);
    final start = _turnStartRow();
    return start > bottom ? start : bottom;
  }

  /// The effective viewport offset while the follow latch holds: the
  /// anchor, unless the user parked the window inside the turn-boundary
  /// pad zone above the live edge ([_scrollTopMax] allows that without
  /// detaching — the newest row is still on the glass there). The park
  /// survives frames with no new output (spinner ticks, keys, resize);
  /// the next streamed append hands the window back to the stream, which
  /// re-anchors at [_turnAnchor] — [_handleOutputMsg] owns that decision
  /// ("the stream owns the window").
  int _followOffset(List<String> wrapped) {
    if (scrollOffset > _scrollBottom(wrapped)) return scrollOffset;
    return _turnAnchor(wrapped);
  }

  /// The highest offset a user scroll may store: the usual live-edge
  /// bottom, plus — while the latch holds — the pad zone of a SHORT
  /// current turn (window above the bottom, blank-padded below without
  /// losing the live edge). Detached scrolls stay clamped to the bottom,
  /// as before. Same computation as [_turnAnchor] while latched: the
  /// stream re-anchor and the user-scroll ceiling must not drift.
  int _scrollTopMax(List<String> wrapped) =>
      followTail ? _turnAnchor(wrapped) : _scrollBottom(wrapped);

  /// The output history formatted and wrapped to physical rows at [width]
  /// (default: the current terminal width). All scroll math happens in
  /// these rows — raw line counts lie once long lines wrap. Memoized in the
  /// shared [_WrapCache]: the O(transcript) markdown+wrap pass re-runs only
  /// when the source list or the width actually changes.
  List<String> _wrappedLines([int? width]) {
    final w = width ?? termWidth;
    final cache = _wrapCache;
    if (identical(cache.source, outputLines) && cache.width == w) {
      return cache.rows; // pure hit: scroll math / key presses pay nothing
    }
    var tx = w == cache.width ? cache._tx : null;
    tx ??= TranscriptMarkdown(width: w);
    cache._tx = tx;
    tx.sync(outputLines); // O(delta) on appends; legacy pass only after a
    // resize/front-trim, where it is byte-identical to formatAll.
    cache
      ..source = outputLines
      ..width = w
      ..rows = tx.wrappedRows
      ..lineStartRows = tx.lineStartRows;
    return tx.wrappedRows;
  }

  /// The scroll offset that puts the last wrapped row at the bottom.
  int _scrollBottom(List<String> wrapped) =>
      (wrapped.length - _viewportHeight).clamp(0, wrapped.length);

  int _clampScroll(int offset, List<String> wrapped) =>
      offset.clamp(0, _scrollBottom(wrapped));

  /// Resolves a restored session's turn anchor (issue #827): the message
  /// lands AFTER the replayed output (`_send` flushes output ahead of every
  /// non-output message), so the replayed last-prompt echo's index counts
  /// back from THIS model's own output length — no absolute index can
  /// survive the host's banner/boot writes around the replay.
  (FaTuiModel, Cmd?) _replayTurnStart(SetTurnStartMsg msg) {
    final line = outputLines.length - 1 - msg.trailingLines;
    return (
      copyWith(turnStartLine: line.clamp(-1, outputLines.length - 1)),
      null,
    );
  }
}
