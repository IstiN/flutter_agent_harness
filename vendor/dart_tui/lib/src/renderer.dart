import 'dart:io';

import 'package:characters/characters.dart';

import 'ansi_state.dart';
import 'bubbles/style.dart' show getWidth;
import 'grapheme_width.dart';
import 'terminal_control.dart';
import 'terminal_mode_state.dart';
import 'terminal_view_state.dart';
import 'view.dart';

abstract interface class TeaRenderer {
  void render(View view);
  void clearScreen();
  void insertAbove(String line);
  void setSyncUpdates(bool enabled);
  void setUnicodeCore(bool enabled);
  void release({bool reset = false});
  void restore(View view);
  void close();

  /// Imperatively enter or exit the alternate screen buffer.
  void setAltScreen(bool enabled);

  /// Imperatively hide or show the cursor.
  void setCursorVisibility(bool visible);

  /// Drops every cached frame assumption (diff cache, scroll history,
  /// tallest-grid watermark). Call when the physical geometry changes
  /// (resize): the next [render] repaints the whole screen once and the
  /// differential path resumes from there.
  void invalidate();

  /// Emit ANSI scroll sequences: positive [n] scrolls up, negative scrolls down.
  void scroll(int n, {bool up = true});
}

final class NilRenderer implements TeaRenderer {
  @override
  void clearScreen() {}
  @override
  void close() {}
  @override
  void insertAbove(String line) {}
  @override
  void setSyncUpdates(bool enabled) {}
  @override
  void setUnicodeCore(bool enabled) {}
  @override
  void release({bool reset = false}) {}
  @override
  void render(View view) {}
  @override
  void restore(View view) {}
  @override
  void setAltScreen(bool enabled) {}
  @override
  void setCursorVisibility(bool visible) {}
  @override
  void scroll(int n, {bool up = true}) {}
  @override
  void invalidate() {}
}

final class _CursorRendererState {
  CursorShape? _shape;
  bool? _blink;
  int? _color;
  int _lastRow = -1;
  int _lastCol = -1;

  void apply(
    IOSink output,
    Cursor? cursor, {
    bool forceHome = false,
  }) {
    if (cursor == null) {
      reset(output);
      return;
    }

    final shapeChanged = cursor.shape != _shape || cursor.blink != _blink;
    if (shapeChanged) {
      final style = switch (cursor.shape) {
        CursorShape.block => cursor.blink ? 1 : 2,
        CursorShape.underline => cursor.blink ? 3 : 4,
        CursorShape.bar => cursor.blink ? 5 : 6,
      };
      output.write('\x1b[$style q');
      _shape = cursor.shape;
      _blink = cursor.blink;
    }

    final colorChanged = cursor.color != _color;
    if (colorChanged) {
      if (cursor.color == null) {
        output.write('\x1b]112\x07');
      } else {
        final hex =
            (cursor.color! & 0xffffff).toRadixString(16).padLeft(6, '0');
        output.write('\x1b]12;#$hex\x07');
      }
      _color = cursor.color;
    }

    final row = cursor.y.clamp(0, 0x7ffffffe) + 1;
    final column = cursor.x.clamp(0, 0x7ffffffe) + 1;
    // CUP dedupe: an idle frame whose screen bytes are all unchanged does
    // not need the home sequence again. Style churn or an invalidated cache
    // re-homes; [forceHome] comes from the renderer and is true whenever
    // THIS frame painted anything — painting rows physically moves the
    // terminal cursor away from home, so the same logical position must be
    // re-emitted even though nothing changed.
    if (shapeChanged ||
        colorChanged ||
        forceHome ||
        row != _lastRow ||
        column != _lastCol) {
      output.write('\x1b[$row;${column}H');
      _lastRow = row;
      _lastCol = column;
    }
  }

  /// Forgets the last emitted CUP — call whenever terminal-side cursor
  /// position is no longer implied by our writes (clearScreen, alt-screen
  /// switches, scrolls, inserts, mode resets).
  void invalidate() {
    _lastRow = -1;
    _lastCol = -1;
  }

  void reset(IOSink output) {
    if (_shape != null) output.write('\x1b[0 q');
    if (_color != null) output.write('\x1b]112\x07');
    _shape = null;
    _blink = null;
    _color = null;
    _lastRow = -1;
    _lastCol = -1;
  }
}

final class AnsiRenderer implements TeaRenderer {
  AnsiRenderer({
    required IOSink output,
    IOSink? logSink,
    required bool defaultAltScreen,
    required bool defaultHideCursor,
    bool defaultReportFocus = false,
  })  : _output = output,
        _logSink = logSink,
        _modes = TerminalModeState(
          defaultAltScreen: defaultAltScreen,
          defaultHideCursor: defaultHideCursor,
          defaultReportFocus: defaultReportFocus,
        );

  final IOSink _output;
  final IOSink? _logSink;
  final TerminalModeState _modes;
  List<String> _lastLines = const <String>[];
  String _lastContent = '';
  String _lastTitle = '';
  bool _hasRenderedFrame = false;
  bool _syncUpdates = false;
  bool _unicodeCoreEnabled = false;
  final _cursorState = _CursorRendererState();
  final _terminalViewState = TerminalViewState();

  @override
  void render(View view) {
    final wantsAlt = _modes.effectiveAltScreen(view);
    _terminalViewState.beforeScreenChange(_output, wantsAlt);
    if (_modes.apply(_output, view)) {
      _lastLines = const <String>[];
      _lastContent = '';
      _hasRenderedFrame = false;
      _cursorState.invalidate();
    }
    _terminalViewState.apply(_output, view, altScreen: wantsAlt);
    // Title dedupe: the OSC sequence used to be re-written on every frame
    // with a non-empty title — churn the terminal parses for nothing.
    if (view.windowTitle != _lastTitle) {
      if (view.windowTitle.isNotEmpty) {
        _output.write(windowTitleSequence(view.windowTitle));
      }
      _lastTitle = view.windowTitle;
    }
    if (_hasRenderedFrame && view.content == _lastContent) {
      _cursorState.apply(_output, view.cursor);
      return;
    }
    final nextLines = view.content.split('\n');

    if (_syncUpdates) _output.write('\x1b[?2026h');
    final maxRows = nextLines.length > _lastLines.length
        ? nextLines.length
        : _lastLines.length;
    final firstFrame = !_hasRenderedFrame;
    var wroteRows = false;
    for (var row = 0; row < maxRows; row++) {
      final next = row < nextLines.length ? nextLines[row] : '';
      final prev = row < _lastLines.length ? _lastLines[row] : '';
      if (!firstFrame && next == prev) continue;
      wroteRows = true;
      _output.write('\x1b[${row + 1};1H');
      if (firstFrame) _output.write('\x1b[K');
      _output.write(next);
      // Only erase to end of line when the new line is *narrower* than the old
      // one — the sole case where stale cells from the previous frame remain
      // (the columns between the two widths). Erasing unconditionally lands the
      // EL on the pending-wrap last column of a full-width line and wipes the
      // just-painted cell, which loses the right edge and flickers it on every
      // redraw. Widths are compared visibly (SGR codes ignored, wide chars = 2).
      if (!firstFrame && getWidth(next) < getWidth(prev)) {
        _output.write('\x1b[K');
      }
    }
    if (_syncUpdates) _output.write('\x1b[?2026l');

    _lastLines = nextLines;
    _lastContent = view.content;
    _hasRenderedFrame = true;
    _cursorState.apply(_output, view.cursor, forceHome: wroteRows);
    _logSink?.writeln('--- frame (diff) ---\n${view.content}');
  }

  @override
  void setSyncUpdates(bool enabled) {
    _syncUpdates = enabled;
  }

  @override
  void setUnicodeCore(bool enabled) {
    if (enabled == _unicodeCoreEnabled) return;
    _output.write(enabled ? '\x1b[?2027h' : '\x1b[?2027l');
    _unicodeCoreEnabled = enabled;
  }

  @override
  void clearScreen() {
    _output.write('\x1b[H\x1b[2J');
    _lastLines = const <String>[];
    _lastContent = '';
    _hasRenderedFrame = false;
    _cursorState.invalidate();
  }

  @override
  void insertAbove(String line) {
    if (!_modes.altScreenEnabled) {
      _output.writeln(line);
      _cursorState.invalidate();
      return;
    }
    // In alt-screen: save cursor, scroll up to create space, write at top, restore
    _output.write('\x1b[s'); // save cursor position
    _output.write('\x1b[1;1H'); // move to top-left
    _output.write('\x1b[S'); // scroll up one line (creates blank row at bottom)
    _output.write('\x1b[1;1H'); // back to top-left
    // Clear the row *before* writing the line. Erasing after would land the EL
    // on the pending-wrap last column of a full-width line and wipe it (#7);
    // erasing first still removes any content the scroll shifted into this row.
    _output.write('\x1b[K'); // clear to end of line
    _output.write(line);
    _output.write('\x1b[u'); // restore cursor position
    _hasRenderedFrame = false; // invalidate diff cache
    _cursorState.invalidate();
  }

  @override
  void release({bool reset = false}) {
    setUnicodeCore(false);
    _terminalViewState.reset(_output);
    _cursorState.reset(_output);
    _modes.reset(_output);
    _lastLines = const <String>[];
    _lastContent = '';
    _lastTitle = '';
    _hasRenderedFrame = false;
    if (reset) {
      clearScreen();
    }
  }

  @override
  void restore(View view) {
    render(view);
  }

  @override
  void close() {
    release();
  }

  @override
  void setAltScreen(bool enabled) {
    _terminalViewState.beforeScreenChange(_output, enabled);
    if (!_modes.setAltScreen(_output, enabled)) return;
    _terminalViewState.restoreKeyboard(_output, enabled);
    _lastLines = const <String>[];
    _lastContent = '';
    _hasRenderedFrame = false;
    _cursorState.invalidate();
  }

  @override
  void setCursorVisibility(bool visible) =>
      _modes.setCursorVisibility(_output, visible);

  @override
  void scroll(int n, {bool up = true}) {
    if (n <= 0) return;
    // ESC[nS = scroll up n lines; ESC[nT = scroll down n lines
    _output.write(up ? '\x1b[${n}S' : '\x1b[${n}T');
    _lastLines = const <String>[];
    _lastContent = '';
    _hasRenderedFrame = false;
    _cursorState.invalidate();
  }

  @override
  void invalidate() {
    _lastLines = const <String>[];
    _lastContent = '';
    _hasRenderedFrame = false;
    _cursorState.invalidate();
  }
}

// ─── Cell-level diff renderer ──────────────────────────────────────────────

/// A single terminal cell with its active rendering state.
final class _Cell {
  const _Cell(this.char, this.attrs,
      [this.hyperlink = '', this.layoutUnstable = false])
      : isContinuation = false;

  const _Cell.continuation(this.attrs,
      [this.hyperlink = '', this.layoutUnstable = false])
      : char = '',
        isContinuation = true;

  final String char; // one grapheme cluster (may be multi-byte)
  final String
      attrs; // the CSI SGR sequence(s) active at this cell, e.g. '\x1b[1;32m'
  final String hyperlink; // active OSC 8 opening sequence
  final bool isContinuation;

  /// The grapheme's 2-cell width is a heuristic other width tables reject
  /// (see [isUnstableWideGrapheme]) — rows containing such cells must not
  /// take the surgical diff path (#342). Derived from [char], so it never
  /// participates in equality.
  final bool layoutUnstable;

  @override
  bool operator ==(Object other) =>
      other is _Cell &&
      other.char == char &&
      other.attrs == attrs &&
      other.hyperlink == hyperlink &&
      other.isContinuation == isContinuation;

  @override
  int get hashCode => Object.hash(char, attrs, hyperlink, isContinuation);
}

/// Renderer that diffs at the individual cell level, emitting precise
/// cursor-move + character-write sequences only for changed cells.
///
/// This produces less flicker than the line-level [AnsiRenderer] on terminals
/// that do not support synchronized updates (?2026).
///
/// Activate via [withCellRenderer] program option.
final class CellRenderer implements TeaRenderer {
  CellRenderer({
    required IOSink output,
    IOSink? logSink,
    required bool defaultAltScreen,
    required bool defaultHideCursor,
    bool defaultReportFocus = false,
  })  : _output = output,
        _logSink = logSink,
        _modes = TerminalModeState(
          defaultAltScreen: defaultAltScreen,
          defaultHideCursor: defaultHideCursor,
          defaultReportFocus: defaultReportFocus,
        );

  final IOSink _output;
  final IOSink? _logSink;
  final TerminalModeState _modes;
  bool _unicodeCoreEnabled = false;
  bool _syncUpdates = false;
  bool _syncOpen = false;

  List<List<_Cell>>? _lastGrid;
  String? _lastContent;
  String _lastTitle = '';
  // Tallest grid ever rendered; the scroll path additionally requires the
  // grid to match it (see _detectScrollShift).
  int _maxRows = 0;
  final _cursorState = _CursorRendererState();
  final _terminalViewState = TerminalViewState();

  @override
  void invalidate() {
    _lastGrid = null;
    _lastContent = null;
    _maxRows = 0;
    _cursorState.invalidate();
  }

  @override
  void render(View view) {
    final wantsAlt = _modes.effectiveAltScreen(view);
    _terminalViewState.beforeScreenChange(_output, wantsAlt);
    if (_modes.apply(_output, view)) {
      _lastGrid = null;
      _lastContent = null;
      _cursorState.invalidate();
    }
    _terminalViewState.apply(_output, view, altScreen: wantsAlt);
    if (view.windowTitle != _lastTitle) {
      if (view.windowTitle.isNotEmpty) {
        _output.write(windowTitleSequence(view.windowTitle));
      }
      _lastTitle = view.windowTitle;
    }
    if (_lastGrid != null && _lastContent == view.content) {
      _cursorState.apply(_output, view.cursor);
      return; // identical frame — skip rebuild + diff walk
    }
    final nextGrid = _buildGrid(view.content);
    final prev = _lastGrid;
    var wroteCells = false;
    if (prev == null) {
      // First frame: clear every row we are about to own, then paint.
      if (nextGrid.isNotEmpty) _syncBegin();
      for (var row = 0; row < nextGrid.length; row++) {
        _output.write('\x1b[${row + 1};1H\x1b[K');
      }
      wroteCells = nextGrid.isNotEmpty;
      wroteCells = _diffAndEmit(nextGrid) || wroteCells;
      _syncEnd();
    } else {
      final shift = _detectScrollShift(prev, nextGrid);
      if (shift != null) {
        // Scroll fast path: one scroll op + the fresh rows (+ any overlap
        // rows the live chrome rewrote across the shift) — never a repaint.
        _syncBegin();
        _emitScrollFrame(k: shift.k, repaint: shift.repaint, next: nextGrid);
        _syncEnd();
        wroteCells = true;
      } else {
        wroteCells = _diffAndEmit(nextGrid);
        _syncEnd();
      }
    }
    if (nextGrid.length > _maxRows) _maxRows = nextGrid.length;
    _lastGrid = nextGrid;
    _lastContent = view.content;
    _cursorState.apply(_output, view.cursor, forceHome: wroteCells);
    _logSink?.writeln('--- cell frame ---\n${view.content}');
  }

  @override
  void clearScreen() {
    _output.write('\x1b[H\x1b[2J');
    _lastGrid = null;
    _lastContent = null;
    _cursorState.invalidate();
  }

  @override
  void insertAbove(String line) {
    if (!_modes.altScreenEnabled) {
      _output.writeln(line);
      _cursorState.invalidate();
      return;
    }
    _output.write('\x1b[s');
    _output.write('\x1b[1;1H');
    _output.write('\x1b[S');
    _output.write('\x1b[1;1H');
    // Clear the row before writing so a full-width line keeps its last column
    // (see AnsiRenderer.insertAbove / #7).
    _output.write('\x1b[K');
    _output.write(line);
    _output.write('\x1b[u');
    _lastGrid = null;
    _lastContent = null;
    _cursorState.invalidate();
  }

  @override
  void release({bool reset = false}) {
    setUnicodeCore(false);
    _terminalViewState.reset(_output);
    _cursorState.reset(_output);
    _modes.reset(_output);
    _lastGrid = null;
    _lastContent = null;
    _lastTitle = '';
    if (reset) clearScreen();
  }

  @override
  void restore(View view) => render(view);

  @override
  void close() => release();

  @override
  void setSyncUpdates(bool enabled) {
    _syncUpdates = enabled;
  }

  @override
  void setUnicodeCore(bool enabled) {
    if (enabled == _unicodeCoreEnabled) return;
    _output.write(enabled ? '\x1b[?2027h' : '\x1b[?2027l');
    _unicodeCoreEnabled = enabled;
  }

  @override
  void setAltScreen(bool enabled) {
    _terminalViewState.beforeScreenChange(_output, enabled);
    if (!_modes.setAltScreen(_output, enabled)) return;
    _terminalViewState.restoreKeyboard(_output, enabled);
    _lastGrid = null;
    _lastContent = null;
    _cursorState.invalidate();
  }

  @override
  void setCursorVisibility(bool visible) =>
      _modes.setCursorVisibility(_output, visible);

  @override
  void scroll(int n, {bool up = true}) {
    if (n <= 0) return;
    _output.write(up ? '\x1b[${n}S' : '\x1b[${n}T');
    _lastGrid = null;
    _lastContent = null;
    _cursorState.invalidate();
  }

  // ── Grid building ──────────────────────────────────────────────────────────

  /// Parse [content] into a 2-D grid of [_Cell]s.
  /// Rows are separated by '\n'. Within each row, we walk grapheme clusters
  /// while tracking the active SGR and OSC 8 state.
  List<List<_Cell>> _buildGrid(String content) {
    final lines = content.split('\n');
    final grid = <List<_Cell>>[];
    for (final line in lines) {
      final cells = <_Cell>[];
      final state = AnsiStateTracker();
      var i = 0;
      final raw = line; // raw string with ANSI codes
      while (i < raw.length) {
        if (raw[i] == '\x1b') {
          // Consume the escape sequence
          final seq = _consumeEscape(raw, i);
          state.accept(seq.raw);
          i += seq.length;
        } else {
          final nextEscape = raw.indexOf('\x1b', i);
          final plainEnd = nextEscape < 0 ? raw.length : nextEscape;
          final plainText = raw.substring(i, plainEnd);
          for (final cluster in plainText.characters) {
            final attrs = state.sgrOpenSequence;
            final hyperlink = state.hyperlinkOpenSequence;
            final unstable = isUnstableWideGrapheme(cluster);
            cells.add(_Cell(cluster, attrs, hyperlink, unstable));
            for (var column = 1; column < graphemeWidth(cluster); column++) {
              cells.add(_Cell.continuation(attrs, hyperlink, unstable));
            }
          }
          i = plainEnd;
        }
      }
      grid.add(cells);
    }
    return grid;
  }

  /// Emit only the cells that differ from [_lastGrid]; returns true when
  /// anything was written (drives the cursor force-home).
  bool _diffAndEmit(List<List<_Cell>> next) {
    final prev = _lastGrid;
    final rows =
        next.length > (prev?.length ?? 0) ? next.length : (prev?.length ?? 0);
    var lastRow = -1;
    var lastCol = -1;
    var lastAttrs = '';
    var lastHyperlink = '';
    var wrote = false;

    for (var row = 0; row < rows; row++) {
      final nextRow = row < next.length ? next[row] : const <_Cell>[];
      final prevRow =
          (prev != null && row < prev.length) ? prev[row] : const <_Cell>[];
      final cols =
          nextRow.length > prevRow.length ? nextRow.length : prevRow.length;

      // #342: a row holding a glyph whose 2-cell width is a heuristic
      // other tables reject (▸, ✓, … emoji-range clusters: dart_tui says 2,
      // wcwidth terminals say 1) must never take the surgical path —
      // absolute cursor moves computed from OUR table land one column off
      // on a disagreeing terminal, and skipped "unchanged" cells leave the
      // previous frame's bytes on screen ('▸ tEdi- rovider h'). Repaint the
      // whole row contiguously so the terminal lays it out by its own
      // table; the bytes stay faithful for screen-scraping consumers.
      if (_hasUnstableLayout(nextRow) || _hasUnstableLayout(prevRow)) {
        if (!_rowsEqual(nextRow, prevRow)) {
          wrote = true;
          _syncBegin();
          if (lastAttrs.isNotEmpty) _output.write('\x1b[0m');
          if (lastHyperlink.isNotEmpty) _output.write('\x1b]8;;\x1b\\');
          _paintRow(row, nextRow);
          // _paintRow homes the cursor per row and closes SGR/hyperlinks;
          // forget the tracked position so the next surgical write always
          // re-addresses absolutely.
          lastRow = -1;
          lastCol = -1;
          lastAttrs = '';
          lastHyperlink = '';
        }
        continue;
      }

      for (var col = 0; col < cols; col++) {
        final nextCell =
            col < nextRow.length ? nextRow[col] : const _Cell(' ', '');
        // Beyond the previously WRITTEN row length the physical terminal
        // holds ERASED cells (CSI K / CSI 2J leave zero-width empty cells in
        // real terminals like xterm, not space cells), so equality with a
        // blank fallback can never be trusted there — a space the view
        // writes must be emitted explicitly or words visually collapse
        // ("Chat model" -> "Chatmodel"). A sentinel that never compares
        // equal forces the paint.
        final prevCell =
            col < prevRow.length ? prevRow[col] : const _Cell('\x00', '\x00');

        if (nextCell == prevCell) continue;

        // A continuation cell is occupied by the wide grapheme emitted from
        // the preceding terminal column. It participates in equality so that
        // stale content is cleared when a wide glyph disappears, but it must
        // never be written independently.
        if (nextCell.isContinuation) continue;
        wrote = true;
        _syncBegin();

        // Move cursor if needed
        if (lastRow != row || lastCol != col) {
          _output.write('\x1b[${row + 1};${col + 1}H');
          lastRow = row;
          lastCol = col;
        }

        if (nextCell.hyperlink != lastHyperlink) {
          if (lastHyperlink.isNotEmpty) _output.write('\x1b]8;;\x1b\\');
          if (nextCell.hyperlink.isNotEmpty) {
            _output.write(nextCell.hyperlink);
          }
          lastHyperlink = nextCell.hyperlink;
        }

        // Apply attrs if changed
        if (nextCell.attrs != lastAttrs) {
          if (nextCell.attrs.isEmpty) {
            _output.write('\x1b[0m');
          } else {
            _output.write(nextCell.attrs);
          }
          lastAttrs = nextCell.attrs;
        }

        _output.write(nextCell.char);
        lastCol += graphemeWidth(nextCell.char);
      }
    }

    // Reset SGR if we wrote anything with attrs
    if (lastAttrs.isNotEmpty) {
      _output.write('\x1b[0m');
    }
    if (lastHyperlink.isNotEmpty) {
      _output.write('\x1b]8;;\x1b\\');
    }
    return wrote;
  }

  // ── Synchronized output (DEC 2026) ────────────────────────────────────────

  /// Opens BSU before the first painted byte of a frame (lazy: idle frames
  /// stay byte-silent, AC — zero-byte static screens).
  void _syncBegin() {
    if (_syncUpdates && !_syncOpen) {
      _output.write('\x1b[?2026h');
      _syncOpen = true;
    }
  }

  /// Closes ESU after the frame's last byte; the cursor apply stays outside
  /// the atomic region (matches [AnsiRenderer]'s ordering).
  void _syncEnd() {
    if (_syncOpen) {
      _output.write('\x1b[?2026l');
      _syncOpen = false;
    }
  }

  // ── Scroll-region fast path ───────────────────────────────────────────────

  /// Pure-scroll detection: +k when [next] is [prev] shifted up by k rows
  /// (content advanced toward the top), -k when shifted down (viewport moved
  /// toward older history).
  ///
  /// Tolerant variant: a small number of overlap rows may differ (the live
  /// chrome — busy spinner, scroll indicator — rewrites itself every frame
  /// even when the content is a pure shift). Those rows are REPAINTED after
  /// the scroll op (see [_emitScrollFrame]), so the emitted stream stays
  /// byte-correct; the tolerance only decides whether the fast path pays
  /// off. The pure-shift case (no mismatches) is still preferred and keeps
  /// the headline budget: 1 op + k fresh rows.
  ///
  /// Returns null when no shift is worth taking → cell diff.
  ///
  /// Additionally requires the grid to be as tall as the tallest grid ever
  /// rendered: a scroll op shifts the PHYSICAL screen, and rows below a
  /// shorter grid would receive shifted stale content this renderer never
  /// repaints. Views that render fewer rows than the terminal simply keep
  /// the cell-diff path (fa_tui pads its view to full height).
  // ponytail: k capped at 40 (a wheel/page scroll never exceeds a
  // viewport); per-k early exit once the mismatch budget is blown. Row
  // hashing only if this ever shows up in a profile.
  ({int k, List<int> repaint})? _detectScrollShift(
      List<List<_Cell>> prev, List<List<_Cell>> next) {
    final rows = prev.length;
    if (rows < 2 || rows != next.length || rows != _maxRows) return null;
    const maxK = 40;
    var best = (matched: -1, k: 0, up: false);
    for (var k = 1; k <= (rows - 1 < maxK ? rows - 1 : maxK); k++) {
      // Up: overlap rows i in [0, rows-k) map from prev[i+k].
      {
        final overlap = rows - k;
        final budget = overlap > 16 ? overlap ~/ 8 : 2;
        var matched = 0;
        for (var i = 0; i < overlap; i++) {
          if (_rowsEqual(next[i], prev[i + k])) matched++;
        }
        // Majority guard: a degenerate k (tiny overlap, all noise) must
        // not win — then op + full repaint costs more than the plain diff.
        if (overlap - matched <= budget &&
            matched * 2 > overlap &&
            matched > best.matched) {
          best = (matched: matched, k: k, up: true);
        }
      }
      // Down: overlap rows i in [k, rows) map from prev[i-k].
      {
        final overlap = rows - k;
        final budget = overlap > 16 ? overlap ~/ 8 : 2;
        var matched = 0;
        for (var i = k; i < rows; i++) {
          if (_rowsEqual(next[i], prev[i - k])) matched++;
        }
        if (overlap - matched <= budget &&
            matched * 2 > overlap &&
            matched > best.matched) {
          best = (matched: matched, k: k, up: false);
        }
      }
    }
    if (best.k == 0) return null;
    final k = best.k;
    final mismatches = <int>[];
    if (best.up) {
      for (var i = 0; i < rows - k; i++) {
        if (!_rowsEqual(next[i], prev[i + k])) mismatches.add(i);
      }
    } else {
      for (var i = k; i < rows; i++) {
        if (!_rowsEqual(next[i], prev[i - k])) mismatches.add(i);
      }
    }
    return (k: best.up ? k : -k, repaint: mismatches);
  }

  bool _rowsEqual(List<_Cell> a, List<_Cell> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Whether any cell's grapheme has a heuristic (ambiguous/emoji) width —
  /// such rows must be repainted whole instead of surgically diffed (#342).
  bool _hasUnstableLayout(List<_Cell> row) {
    for (final cell in row) {
      if (cell.layoutUnstable) return true;
    }
    return false;
  }

  /// One scroll op for [k] (positive = up `CSI S`, negative = down `CSI T`)
  /// plus a repaint of only the rows the scroll leaves blank — a page scroll
  /// becomes 1 op + k rows instead of a whole-screen repaint. The [shift]'s
  /// mismatched overlap rows (live chrome that changed across the shift) are
  /// repainted too, so the physical screen converges to [next] exactly.
  void _emitScrollFrame(
      {required int k,
      required List<int> repaint,
      required List<List<_Cell>> next}) {
    _output.write(k > 0 ? '\x1b[${k}S' : '\x1b[${-k}T');
    final from = k > 0 ? next.length - k : 0;
    final to = k > 0 ? next.length : -k;
    for (var row = from; row < to; row++) {
      _paintRow(row, next[row]);
    }
    for (final row in repaint) {
      _paintRow(row, next[row]);
    }
  }

  /// Paints one full row from column 1, tracking SGR/hyperlink state so
  /// consecutive cells share one attribute stream. The row tail is erased
  /// (CSI K): a scroll op shifts the PHYSICAL screen, so the rows it leaves
  /// at the bottom hold stale content beyond this row's content length, and
  /// the grid treats beyond-content cells as blank — the erase is what makes
  /// that assumption true (missing it leaks stale characters between words).
  void _paintRow(int row, List<_Cell> cells) {
    var attrs = '';
    var hyperlink = '';
    _output.write('\x1b[${row + 1};1H');
    for (final cell in cells) {
      if (cell.isContinuation) continue;
      if (cell.hyperlink != hyperlink) {
        if (hyperlink.isNotEmpty) _output.write('\x1b]8;;\x1b\\');
        if (cell.hyperlink.isNotEmpty) _output.write(cell.hyperlink);
        hyperlink = cell.hyperlink;
      }
      if (cell.attrs != attrs) {
        _output.write(cell.attrs.isEmpty ? '\x1b[0m' : cell.attrs);
        attrs = cell.attrs;
      }
      _output.write(cell.char);
    }
    if (attrs.isNotEmpty) _output.write('\x1b[0m');
    if (hyperlink.isNotEmpty) _output.write('\x1b]8;;\x1b\\');
    _output.write('\x1b[K');
  }
}

// ── Escape sequence parser helper ─────────────────────────────────────────────

final class _EscSeq {
  const _EscSeq({required this.raw, required this.length});
  final String raw;
  final int length;
}

/// Consume one escape sequence starting at [start] in [s].
/// Returns the raw sequence and its length.
_EscSeq _consumeEscape(String s, int start) {
  // Expect s[start] == '\x1b'
  if (start + 1 >= s.length) {
    return const _EscSeq(raw: '\x1b', length: 1);
  }

  final next = s[start + 1];
  if (next == '[') {
    // CSI sequence: \x1b[ ... final_byte (@ through ~, i.e. 0x40-0x7E)
    var i = start + 2;
    while (i < s.length && (s.codeUnitAt(i) < 0x40 || s.codeUnitAt(i) > 0x7E)) {
      i++;
    }
    if (i < s.length) i++; // include the final byte
    final raw = s.substring(start, i);
    return _EscSeq(raw: raw, length: i - start);
  } else if (next == ']' || next == 'P') {
    // OSC strings end with BEL or ST; DCS strings end with ST. Consume the
    // complete two-byte ST so its trailing backslash cannot become content.
    final isOsc = next == ']';
    var i = start + 2;
    while (i < s.length) {
      if (isOsc && s[i] == '\x07') {
        i++;
        break;
      }
      if (s[i] == '\x1b' && i + 1 < s.length && s[i + 1] == '\\') {
        i += 2;
        break;
      }
      i++;
    }
    return _EscSeq(raw: s.substring(start, i), length: i - start);
  } else {
    // Single-char escape (e.g. \x1b7, \x1b8)
    return _EscSeq(raw: s.substring(start, start + 2), length: 2);
  }
}
