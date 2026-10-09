/// The viewport scroll machinery (issues #827 + #1348) — the follow
/// anchor, pin-to-bottom tail tracking, and the shared wrap cache bridge —
/// split out of `fa_tui.dart` to keep it under the repo's 2800-line size
/// gate. Same library (a `part of`), so the extension sees the model's
/// private members; the render state (`_wrapCache`) is declared on
/// [FaTuiModel] itself — extensions cannot add fields.
part of 'fa_tui.dart';

extension _TuiViewport on FaTuiModel {
  /// Applies a user scroll: moves the offset (clamped) and classifies the
  /// gesture through the shared [FollowMode] contract (gh-1439) —
  /// scrolling away from the live edge holds; toward it re-arms when the
  /// landing spot sits inside the near-bottom band ([pageGesture] arms
  /// the shared ~10%-of-viewport band; line steps re-arm on the exact
  /// edge, the pinned arrow-key semantics). Any user scroll dissolves the
  /// boot anchor: the park is the boot's, not the user's. Holding stores
  /// the transcript line at the window's top edge ([heldAnchorLine]) so
  /// trims/resizes re-anchor the same logical position (E1/E2).
  FaTuiModel _scrolledTo(
    int offset, {
    required bool towardLive,
    bool pageGesture = false,
  }) {
    final wrapped = _wrappedLines();
    final bottom = _scrollBottom(wrapped);
    final next = offset.clamp(0, _scrollTopMax(wrapped));
    final arm = pageGesture
        ? FollowMode.nearBottomArmExtent(_viewportHeight)
        : 0;
    final followMode = follow.userScrolled(
      distanceFromLiveEdge: bottom - next,
      armExtent: arm,
      movedTowardLive: towardLive,
    );
    return copyWith(
      scrollOffset: next,
      follow: followMode,
      heldAnchorLine: followMode.isHeld
          ? _anchorLineAtRow(next)
          : -1,
      bootAnchorLine: 0,
    );
  }

  /// The explicit re-engage (End key / jump-chip click): live at the
  /// bottom edge, count flushed, anchor cleared. Exactly one action.
  FaTuiModel _jumpToLive() {
    final wrapped = _wrappedLines();
    return copyWith(
      scrollOffset: _scrollBottom(wrapped),
      follow: follow.jumpToLive(),
      heldAnchorLine: -1,
      bootAnchorLine: 0,
    );
  }

  /// The transcript line whose wrapped rows start at or before [row] —
  /// the logical anchor for a held window (binary search over
  /// [lineStartRows]; the sentinel tail entry is excluded).
  int _anchorLineAtRow(int row) {
    final starts = _wrapCache.lineStartRows;
    if (starts.length <= 1) return 0;
    var lo = 0;
    var hi = starts.length - 2;
    var best = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (starts[mid] <= row) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  /// The held anchor after an append that trimmed [cut] head lines
  /// (gh-1439 E1): the anchor shifts by the cut and the window re-derives
  /// its offset from the NEW wrap (the cache still holds the old
  /// line-starts — read them before any re-sync). Returns
  /// `(newAnchorLine, newOffset)`; an unheld or anchorless state passes
  /// through clamped unchanged.
  (int, int) _heldAnchorShiftedByCut(int cut) {
    final bottom = _scrollBottom(_wrappedLines());
    if (!follow.isHeld || heldAnchorLine < 0) {
      return (heldAnchorLine, scrollOffset.clamp(0, bottom));
    }
    final starts = _wrapCache.lineStartRows;
    final shifted = (heldAnchorLine - cut).clamp(0, starts.length - 2);
    return (shifted, starts[shifted].clamp(0, bottom));
  }

  /// The held anchor's wrapped row after a re-wrap (gh-1439 E2): the
  /// anchor is a transcript line, so the NEW wrap's line-starts name the
  /// same logical position at any width. -1 anchors degrade to the clamped
  /// raw offset.
  int _heldAnchorRow(List<String> wrapped) {
    final bottom = _scrollBottom(wrapped);
    if (!follow.isHeld || heldAnchorLine < 0) {
      return _clampScroll(scrollOffset, wrapped);
    }
    final starts = _wrapCache.lineStartRows;
    final anchor = heldAnchorLine.clamp(0, starts.length - 2);
    return starts[anchor].clamp(0, bottom);
  }

  /// The sticky-echo index after a transcript head-trim dropped [cut]
  /// lines (issue #827 review): the pinned echo is a transcript index —
  /// it shifts by the cut, and a trim that swallowed the pinned echo
  /// drops the pin (-1) instead of leaving it aimed at a foreign line.
  int _stickyShiftedBy(int cut) {
    if (cut == 0 || stickyIndex < 0) return stickyIndex;
    final shifted = stickyIndex - cut;
    return shifted < 0 ? -1 : shifted;
  }

  /// Host-driven state pushes: the hub overlay board and the composer
  /// text/history setters. Split out of [_updateAfterExitCheck] to keep
  /// the dispatcher's decision count under the CRAP ratchet.
  (Model, Cmd?)? _handleHostStateMsg(Msg msg) {
    if (msg is HubStateMsg) return _handleHubStateMsg(msg);
    if (msg is _CloseHubMsg) return (copyWith(clearHub: true), null);
    if (msg is SetBootAnchorMsg) {
      // The count is captured at the CONTROLLER call site (issue #446
      // wave-14, CI round 2): the queued message is consumed only after
      // the boot backlog drained into the model, so reading
      // outputLines.length here named the transcript END and folded the
      // entire boot banner on every PTY boot ('[Model]' never reached the
      // glass). The carried count = '\n's written before the anchor call
      // = the exact row the next write (the reconciliation summary)
      // lands on — the trailing phantom slot.
      return (copyWith(bootAnchorLine: msg.line), null);
    }

    if (msg is _SetInputTextMsg) {
      return (
        copyWith(
          inputText: msg.text,
          cursor: msg.text.length,
          menuOpen: false,
          menuTokenStart: -1,
        ),
        null,
      );
    }
    if (msg is SetInputHistoryMsg) {
      return (
        copyWith(
          inputHistory: msg.history,
          historyIndex: -1,
          historyDraft: null,
        ),
        null,
      );
    }
    return null;
  }

  /// The follow anchor (issues #827 + #1348): the live edge — the window
  /// pins to the BOTTOM, so a submitted message lands above the composer
  /// with the prior history directly above it and streaming scrolls up
  /// line by line (standard terminal semantics). #1348 supersedes #827's
  /// short-turn park at the turn's first row: that anchor pinned the fresh
  /// echo to the TOP of the glass with a blank page reserved underneath.
  ///
  /// The resumed boot's replay anchor joins the bottom (issue #446
  /// wave-14) — but ONLY when the glass must fold something: banner
  /// chrome + restored transcript overflowing the viewport anchors at the
  /// transcript start (the banner rides the fold under the #827
  /// indicator, the tail's head stays on the glass); a transcript that
  /// fits alone keeps offset 0 — parking the window on the anchor row
  /// folded the whole boot banner on every healthy boot (CI round 2:
  /// '[Model]' never painted, every PTY suite timed out at waitForBoot).
  /// And when even the anchored region overflows, the tail outranks the
  /// boot region and the anchor degrades to the bottom.
  int _followAnchor(List<String> wrapped) {
    final bottom = _scrollBottom(wrapped);
    final boot = _bootAnchorRow();
    if (boot != null && wrapped.length > _viewportHeight) {
      final region = wrapped.length - boot;
      if (region <= _viewportHeight && boot > bottom) return boot;
    }
    return bottom;
  }

  /// The boot anchor's wrapped row, or null when absent/foreign (0 = no
  /// anchor; an index past the transcript degrades the same way a stale
  /// turn start does).
  int? _bootAnchorRow() {
    if (bootAnchorLine <= 0 || bootAnchorLine >= outputLines.length) {
      return null;
    }
    _wrappedLines(); // refresh the shared wrap cache when stale
    final starts = _wrapCache.lineStartRows;
    if (bootAnchorLine >= starts.length) return null;
    return starts[bootAnchorLine];
  }

  /// The boot-anchor index after a transcript head-trim dropped [cut]
  /// lines: every transcript index shifts by the cut; a trim that
  /// swallowed the anchor drops it (0 — plain bottom follow).
  int _bootAnchorShiftedBy(int cut) {
    if (cut == 0 || bootAnchorLine <= 0) return bootAnchorLine;
    final shifted = bootAnchorLine - cut;
    return shifted < 0 ? 0 : shifted;
  }

  /// The effective viewport offset while the follow latch holds: the
  /// anchor — the live edge, or the boot-resume park above it — unless the
  /// user's own offset already sits there. The park survives frames with
  /// no new output (spinner ticks, keys, resize); the next streamed append
  /// hands the window back to the stream, which re-anchors at
  /// [_followAnchor] — [_handleOutputMsg] owns that decision ("the stream
  /// owns the window").
  int _followOffset(List<String> wrapped) {
    if (scrollOffset > _scrollBottom(wrapped)) return scrollOffset;
    return _followAnchor(wrapped);
  }

  /// The highest offset a user scroll may store: the follow anchor while
  /// the latch holds (the boot-resume park), the plain bottom when
  /// detached. Same computation as [_followAnchor] while latched: the
  /// stream re-anchor and the user-scroll ceiling must not drift.
  int _scrollTopMax(List<String> wrapped) =>
      followTail ? _followAnchor(wrapped) : _scrollBottom(wrapped);

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
}
