/// Incremental markdown-to-ANSI formatter for the TUI output history.
///
/// The TUI stores raw assistant text and formats it at view time: a fresh
/// [AnsiMarkdown] walks the (bounded) output lines top-to-bottom on every
/// frame via [formatAll], so multi-line state (code fences, tables) is
/// tracked while partial markdown from an in-flight stream simply renders
/// unstyled until its closing marker arrives. Only SGR sequences
/// (`\x1b[...m`) are emitted — the same set the viewport already strips
/// when measuring visible width for soft-wrapping, so scroll math stays
/// correct. Output preserves the input line count for every construct
/// EXCEPT a table that overflows the terminal width: its long cells wrap
/// onto continuation grid rows (each still carrying the aligned borders),
/// so a wide table renders as a real box grid instead of collapsing to raw
/// markdown. Scroll math is unaffected either way — consumers work in
/// wrapped-ROW space and treat a formatted line list generically.
///
///
/// The visual mapping follows pi's `packages/tui/src/components/markdown.ts`
/// dark theme, retinted to the site palette (teal/indigo): headings without
/// the `#` prefix (H1 also underlined), fenced code indented 2 spaces with
/// dim border lines and no background, `│ ` quote bars, accent list
/// bullets, box-grid tables with a dim separator row, and full-width
/// horizontal rules capped at 80 columns.
library;

import 'tui_text_width.dart' show tuiTextWidth;

/// One formatter per render pass; feed the whole output buffer via
/// [formatAll] (or single lines in order via [formatLine]).
final class AnsiMarkdown {
  AnsiMarkdown({this.width = 80});

  /// Terminal width, used for horizontal rules (capped at 80 like pi) and
  /// as the table-fit budget (overflowing cells wrap; only a degenerate
  /// budget still falls back to raw markdown).
  final int width;

  var _inFence = false;
  final _tableBuffer = <String>[];

  // Site palette (site/styles.css): teal accent, indigo accent-2.
  static const _teal = '\x1b[38;2;94;234;212m';
  static const _indigo = '\x1b[38;2;129;140;248m';
  static const _dim = '\x1b[2m';
  static const _bold = '\x1b[1m';
  static const _italic = '\x1b[3m';
  static const _underline = '\x1b[4m';
  static const _strike = '\x1b[9m';
  static const _reset = '\x1b[0m';

  static final _fenceRe = RegExp(r'^\s*```');
  static final _headerRe = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _hrRe = RegExp(r'^\s{0,3}((-\s*){3,}|(_\s*){3,}|(\*\s*){3,})$');
  static final _quoteRe = RegExp(r'^(\s*)>( |$)(.*)$');
  static final _bulletRe = RegExp(r'^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$');
  static final _taskRe = RegExp(r'^\[( |x|X)\]\s+(.*)$');
  static final _linkRe = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
  static final _codeSpanRe = RegExp(r'`([^`]+)`');
  static final _boldRe = RegExp(r'\*\*([^*]+)\*\*');
  static final _strikeRe = RegExp(r'~~([^~]+)~~');
  static final _italicRe = RegExp(r'(?<!\w)[*_]([^*_]+)[*_](?!\w)');
  static final _tableRowRe = RegExp(r'^\s*\|.*\|\s*$');
  static final _tableSeparatorCellRe = RegExp(r'^:?-+:?$');
  static final _ansiRe = RegExp(r'\x1b\[[0-9;]*m');
  // Hoisted out of the per-line hot path: constructing a RegExp per
  // formatted line showed up in scroll/stream rendering profiles.
  static final _ruleRe = RegExp(r'^─+$');

  /// The SGR matcher shared with [wrapAnsiLine] and tests.
  static RegExp get ansiSgrPattern => _ansiRe;

  /// Whether code-fence mode is active (cross-line state).
  bool get inFence => _inFence;

  /// Emits any buffered table rows (the end-of-buffer step of
  /// [formatAll]); a no-op with nothing pending.
  List<String> flushTrailing() => _flushTable();

  /// Streams one source line through the incremental pipeline: table rows
  /// are buffered (0 output lines) like in [formatAll]; anything else
  /// emits `[…pending table…, formattedLine]`. Used by
  /// [TranscriptMarkdown] — a long-lived instance carries `_inFence` and
  /// the pending-table buffer across calls, which is exactly the
  /// persistent-parser state the per-call object lost.
  List<String> consumeLine(String line) {
    if (!_inFence && _isTableRow(line)) {
      _tableBuffer.add(line);
      return const [];
    }
    return [..._flushTable(), formatLine(line)];
  }

  /// Whether table rows are buffered awaiting their separator/closing row
  /// (a sync-time commit boundary is invalid until this drains).
  bool get hasPendingTable => _tableBuffer.isNotEmpty;

  /// Restores the cross-line state captured at a commit boundary (see
  /// [TranscriptMarkdown]). Same library, so private fields are reachable;
  /// takes copies defensively.
  void restoreState({required bool inFence, required List<String> table}) {
    _inFence = inFence;
    _tableBuffer
      ..clear()
      ..addAll(table);
  }

  /// Current cross-line state snapshot (see [restoreState]).
  (bool, List<String>) snapshotState() => (_inFence, List.of(_tableBuffer));

  /// Formats the whole output buffer, preserving the line count 1:1.
  /// Table rows are buffered until the table ends so column widths can be
  /// computed across every row before rendering.
  List<String> formatAll(List<String> lines) {
    final out = <String>[];
    for (final line in lines) {
      out.addAll(consumeLine(line));
    }
    out.addAll(_flushTable());
    return out;
  }

  /// Formats one raw output line, updating fence state. Does NOT handle
  /// tables (see [formatAll]). Inline spans are resolved inside a single
  /// line only (matches how deltas arrive).
  String formatLine(String line) {
    // Pre-styled lines (the user echo carries a background): pad the
    // background out to the CURRENT width — the stored line predates any
    // terminal resize.
    final preStyled = _formatPreStyled(line);
    if (preStyled != null) return preStyled;

    // Full-width rules are stored baked at submit-time width; re-render them
    // at the current width so a resize never leaves ragged bars behind.
    // Skip the ANSI strip when the line carries no escape codes (the common
    // case during streaming).
    final stripped = line.codeUnits.any((c) => c == 0x1b)
        ? line.replaceAll(_ansiRe, '')
        : line;
    if (stripped.length > 2 && _ruleRe.hasMatch(stripped)) {
      return '$_dim${'─' * width}$_reset';
    }

    final fenced = _formatFence(line);
    if (fenced != null) return fenced;

    return _formatMarkdownLine(line);
  }

  /// Pre-styled background lines padded to the current width; null for
  /// ordinary lines. Padding is cell-width aware: the renderer measures
  /// grapheme clusters, so `padRight` (UTF-16 units) underpads any echo
  /// carrying wide characters and stale cells survive on the right.
  String? _formatPreStyled(String line) {
    if (!line.startsWith('\x1b[48')) return null;
    final visible = line.replaceAll(_ansiRe, '');
    final pad = width - tuiTextWidth(visible);
    if (pad <= 0) return line;
    final body = line.endsWith(_reset)
        ? line.substring(0, line.length - _reset.length)
        : line;
    return '$body${' ' * pad}$_reset';
  }

  /// Code fences swallow everything between the markers verbatim (pi:
  /// content indented 2 spaces, no background, dim border lines). Null for
  /// markdown content outside a fence.
  String? _formatFence(String line) {
    if (_fenceRe.hasMatch(line)) {
      _inFence = !_inFence;
      return '$_dim$line$_reset';
    }
    if (_inFence) {
      return '  $line';
    }
    return null;
  }

  /// Markdown block forms: headers, horizontal rules, quotes, bullets —
  /// anything else goes through inline formatting.
  String _formatMarkdownLine(String line) {
    // Hot path: ~10M calls, most lines are plain text. Skip 4 regex
    // firstMatch calls when the line carries no markdown block marker.
    if (_isBlockCandidate(line)) {
      return _formatHeader(line) ??
          _formatHr(line) ??
          _formatQuote(line) ??
          _formatBulletLine(line) ??
          _formatInline(line);
    }
    return _formatInline(line);
  }

  /// Quick first-char dispatch: returns false for lines that cannot be a
  /// markdown block form (plain text — skip the regex scans).
  bool _isBlockCandidate(String line) {
    if (line.isEmpty) return false;
    final c = line.codeUnitAt(0);
    if (_blockMarkerChars.contains(c)) return true;
    return c >= 0x30 && c <= 0x39 /*0-9*/;
  }

  /// Header line formatting (H1 bold+underline, H2 bold, H3+ keeps prefix).
  String? _formatHeader(String line) {
    final header = _headerRe.firstMatch(line);
    if (header == null) return null;
    final level = header.group(1)!.length;
    final text = header.group(2)!;
    return switch (level) {
      1 => '$_indigo$_bold$_underline$text$_reset',
      2 => '$_indigo$_bold$text$_reset',
      _ => '$_indigo$_bold${header.group(1)} $text$_reset',
    };
  }

  /// Horizontal rule formatting (capped at 80 chars).
  String? _formatHr(String line) {
    if (!_hrRe.hasMatch(line)) return null;
    final ruleWidth = width < 80 ? width : 80;
    return '$_dim${'─' * ruleWidth}$_reset';
  }

  /// Block-quote formatting.
  String? _formatQuote(String line) {
    final quote = _quoteRe.firstMatch(line);
    if (quote == null) return null;
    final body = _formatInline(quote.group(3)!);
    return '${quote.group(1)}$_dim│$_reset $_dim$_italic$body$_reset';
  }

  /// Bullet / numeric list formatting.
  String? _formatBulletLine(String line) {
    final bullet = _bulletRe.firstMatch(line);
    if (bullet == null) return null;
    return _formatBullet(bullet);
  }

  /// Bullet and task-list lines: `-`/`+` markers become a teal `•`, numeric
  /// markers stay literal; task items keep their checkbox (pi renders
  /// [x] / [ ]).
  String _formatBullet(RegExpMatch bullet) {
    final marker = bullet.group(2)!;
    final body = bullet.group(3)!;
    final task = _taskRe.firstMatch(body);
    // One-char marker = a `-`*`+` bullet (numeric markers are `12.` —
    // always longer), so no regex is needed on this per-line hot path.
    final renderedMarker = marker.length == 1
        ? '$_teal•$_reset'
        : '$_teal$marker$_reset';
    if (task != null) {
      final checked = task.group(1)!.toLowerCase() == 'x';
      final box = checked ? '$_teal[✓]$_reset' : '$_dim[ ]$_reset';
      return '${bullet.group(1)}$renderedMarker $box '
          '${_formatInline(task.group(2)!)}';
    }
    return '${bullet.group(1)}$renderedMarker ${_formatInline(body)}';
  }

  /// Inline spans: links, inline code, bold, strikethrough, italic. Code
  /// spans are formatted before emphasis so markers inside them stay
  /// literal; every span is self-contained (SGR + reset).
  String _formatInline(String text) {
    // Hot path: ~11M calls, the vast majority are plain text with no inline
    // markdown markers at all. Skip 5 chained replaceAllMapped regex scans
    // when none of the trigger characters are present.
    if (!text.contains('[') &&
        !text.contains('`') &&
        !text.contains('*') &&
        !text.contains('~') &&
        !text.contains('_')) {
      return text;
    }
    var out = text;
    out = out.replaceAllMapped(
      _linkRe,
      (m) => '$_underline${m[1]}$_reset$_dim (${m[2]})$_reset',
    );
    out = out.replaceAllMapped(_codeSpanRe, (m) => '$_teal${m[1]}$_reset');
    out = out.replaceAllMapped(_boldRe, (m) => '$_bold${m[1]}$_reset');
    out = out.replaceAllMapped(_strikeRe, (m) => '$_strike${m[1]}$_reset');
    out = out.replaceAllMapped(_italicRe, (m) => '$_italic${m[1]}$_reset');
    return out;
  }

  // ---------------------------------------------------------------- tables

  bool _isTableRow(String line) => _tableRowRe.hasMatch(line);

  List<String> _splitCells(String row) {
    var r = row.trim();
    if (r.startsWith('|')) r = r.substring(1);
    if (r.endsWith('|')) r = r.substring(0, r.length - 1);
    return r.split('|').map((c) => c.trim()).toList();
  }

  /// Renders the buffered table rows as a compact box grid (header bold,
  /// dim separator row), one output line per source line. Falls back to
  /// raw markdown when the table is malformed or does not fit the width.
  List<String> _flushTable() {
    if (_tableBuffer.isEmpty) return const [];
    final rows = List.of(_tableBuffer);
    _tableBuffer.clear();

    final cells = [for (final row in rows) _splitCells(row)];
    final columnCount = cells.first.length;
    final uniform = cells.every((c) => c.length == columnCount);
    final hasSeparator =
        rows.length >= 2 &&
        cells[1].every((c) => _tableSeparatorCellRe.hasMatch(c));
    if (!uniform || columnCount < 2 || !hasSeparator) {
      // Not a clean table: emit raw, inline-formatted like any other line.
      return _rawTableRows(rows);
    }

    final widths = List<int>.filled(columnCount, 0);
    // Column widths come from the FORMATTED cells: inline markers (the
    // backticks of `code`, ** of bold, ...) render away, so sizing columns
    // by raw text would push the separators right of the header's grid.
    final formatted = _formattedCells(rows, cells, widths);
    // Grid overhead: ' cell ' per column plus the ' │ ' joiners between
    // columns plus the single leading/trailing space.
    final overhead = (columnCount - 1) * 3 + 2;
    final caps = _columnCaps(widths, width - overhead);
    if (caps == null) {
      // Degenerate budget — a tiny terminal or very many columns: even the
      // minimum column width would not produce a readable grid. Raw rows.
      return _rawTableRows(rows);
    }

    return _renderTableRows(rows, caps, formatted);
  }

  /// Raw rows, inline-formatted like any other line (malformed or
  /// degenerate-budget tables).
  List<String> _rawTableRows(List<String> rows) {
    return [for (final row in rows) _formatInline(row)];
  }

  /// The inline-formatted cells keyed by row (the separator row carries no
  /// content width), with per-column max visible widths accumulated into
  /// [widths].
  Map<int, List<String>> _formattedCells(
    List<String> rows,
    List<List<String>> cells,
    List<int> widths,
  ) {
    final formatted = <int, List<String>>{};
    for (var r = 0; r < rows.length; r++) {
      if (r == 1) continue; // separator row has no content width
      formatted[r] = [
        for (var c = 0; c < cells[r].length; c++) _formatInline(cells[r][c]),
      ];
      for (var c = 0; c < cells[r].length; c++) {
        final visible = _visibleLength(formatted[r]![c]);
        if (visible > widths[c]) widths[c] = visible;
      }
    }
    return formatted;
  }

  /// Minimum readable column width: below this the wrapped grid degrades
  /// into letter-soup and the raw fallback serves better.
  static const int _minColumnWidth = 6;

  /// Caps natural column widths into the available frame [budget]
  /// (terminal width minus joiner/padding overhead).
  ///
  /// Returns null when even the floor does not fit (degenerate — the caller
  /// falls back to raw). Columns that fit naturally keep their width; the
  /// overflow budget is shared by the remaining columns, weighted by how
  /// much they need and distributed deterministically (widest-first, unit
  /// leftovers repaid in the same order).
  static List<int>? _columnCaps(List<int> natural, int budget) {
    if (budget < natural.length * _minColumnWidth) return null;
    final sumNatural = natural.fold<int>(0, (a, b) => a + b);
    if (sumNatural <= budget) return List.of(natural);

    final floorSum = natural.length * _minColumnWidth;
    final wantTotal = sumNatural - floorSum; // > 0 past the fit check above
    var spare = budget - floorSum; // >= 0 likewise
    final order = [for (var c = 0; c < natural.length; c++) c]
      ..sort((a, b) => natural[b].compareTo(natural[a]));
    final caps = List<int>.filled(natural.length, _minColumnWidth);
    for (final c in order) {
      if (spare <= 0) break;
      final want = natural[c] - _minColumnWidth;
      if (want <= 0) continue;
      var grant = (spare * want) ~/ wantTotal;
      if (grant > spare) grant = spare;
      caps[c] += grant;
      spare -= grant;
    }
    // Repay integer-flooring losses widest-first while budget remains.
    for (final c in order) {
      if (spare <= 0) break;
      final missing = natural[c] - caps[c];
      if (missing > 0) {
        final grant = missing < spare ? missing : spare;
        caps[c] += grant;
        spare -= grant;
      }
    }
    return caps;
  }

  /// Emits the grid rows: padded cells joined by dim `│`, the separator row
  /// as a dim `───┼───` line, the header row bold. A cell wider than its
  /// column WRAPS ([wrapAnsiLine]) onto continuation physical rows that keep
  /// every border aligned — an overflowing table stays a real grid instead
  /// of collapsing to raw markdown. Each physical row is padded to the full
  /// frame: continuation cells render as blanks under the already-shown
  /// part of their column.
  List<String> _renderTableRows(
    List<String> rows,
    List<int> widths,
    Map<int, List<String>> formatted,
  ) {
    final out = <String>[];

    // Per logical row: the wrapped fragments of every cell, and the tallest
    // cell's line count (the physical height of that logical row).
    final fragments = <List<List<String>>>[];
    final heights = <int>[];
    for (var r = 0; r < rows.length; r++) {
      if (r == 1) {
        fragments.add(const []);
        heights.add(1);
        continue;
      }
      final wrapped = <List<String>>[
        for (var c = 0; c < widths.length; c++)
          wrapAnsiLine(formatted[r]![c], widths[c]),
      ];
      var h = 1;
      for (final lines in wrapped) {
        if (lines.length > h) h = lines.length;
      }
      fragments.add(wrapped);
      heights.add(h);
    }

    for (var r = 0; r < rows.length; r++) {
      if (r == 1) {
        out.add(
          '$_dim${[for (var c = 0; c < widths.length; c++) '─' * (widths[c] + 2)].join('┼')}$_reset',
        );
        continue;
      }
      final isHeader = r == 0;
      for (var k = 0; k < heights[r]; k++) {
        final renderedCells = <String>[];
        for (var c = 0; c < widths.length; c++) {
          final lines = fragments[r][c];
          final frag = k < lines.length ? lines[k] : '';
          // Header bold re-opens per fragment: a wrapped fragment must not
          // leak bold into its trailing padding or into the joiner.
          final styled = isHeader && frag.isNotEmpty
              ? '$_bold$frag$_reset'
              : frag;
          renderedCells.add(styled + ' ' * (widths[c] - _visibleLength(frag)));
        }
        out.add(' ${renderedCells.join(' $_dim│$_reset ')} ');
      }
    }
    return out;
  }

  /// Visible cell width of a styled fragment: ANSI stripped, then measured
  /// in terminal cells (grapheme clusters — an emoji is 2 cells even though
  /// it is 1–2 UTF-16 units). Table column sizing must match the renderer
  /// or the grid separators drift out of alignment.
  static int _visibleLength(String text) =>
      tuiTextWidth(text.replaceAll(_ansiRe, ''));
}

/// Tokenizer for [wrapAnsiLine] — hoisted: it runs per wrapped line, and
/// building the RegExp there dominated the wrap cost on long histories.
final _ansiTokenRe = RegExp(r'\x1b\[[0-9;]*m|.', unicode: true);

/// First-byte markers for markdown block candidates (#, >, -, *, +, space).
const _blockMarkerChars = {0x23, 0x3E, 0x2D, 0x2A, 0x2B, 0x20};

/// Wraps one ANSI-styled line to [width] visible CELL columns WITHOUT
/// cutting inside SGR escape sequences — dart_tui's viewport wrap slices raw
/// text and leaks escape tails (e.g. `212m`) as visible text.
///
/// Widths are measured in terminal cells (grapheme clusters, see
/// [tuiTextWidth]) so the rows we emit never exceed what the renderer can
/// place: an emoji or CJK character occupies 2 cells despite being 1–2
/// UTF-16 units, and counting it as one column overflowed every wrapped row
/// that contained one (the "markdown breaks after emoji" corruption).
///
/// Two correctness rules beyond the escape safety:
///
/// - Word-aware: breaks at spaces when possible (a hard mid-word cut only
///   happens for a single word longer than [width]); a boundary space stays
///   at the end of the closing row, so reassembling the rows reproduces the
///   original text.
/// - SGR state carries across the cut EXPLICITLY: the closed row ends with
///   a reset and the continuation row re-opens the active styles. dart_tui
///   redraws rows independently, so relying on the terminal to keep SGR
///   across a newline loses styling on every wrapped styled span.
///
/// The unicode flag makes `.` match whole runes, keeping emoji intact.
List<String> wrapAnsiLine(String line, int width) {
  if (width <= 0) return [line];
  // Skip the ANSI strip on plain-text lines (the common case).
  final hasAnsi = line.codeUnits.any((c) => c == 0x1b);
  final visible = hasAnsi
      ? tuiTextWidth(line.replaceAll(AnsiMarkdown.ansiSgrPattern, ''))
      : tuiTextWidth(line);
  if (visible <= width) return [line];

  final rows = <String>[];
  final row = StringBuffer();
  var col = 0;
  // SGR codes active at the current write position (since the last reset).
  final activeSgr = <String>[];
  // The word being accumulated: whole tokens (chars + inline SGR) and its
  // visible length.
  final wordTokens = <String>[];
  var wordVisible = 0;

  void closeRow() {
    if (activeSgr.isNotEmpty) row.write('\x1b[0m');
    rows.add(row.toString());
    row
      ..clear()
      ..writeAll(activeSgr);
    col = 0;
  }

  void writeToken(String token, int visibleLen) {
    row.write(token);
    col += visibleLen;
    if (token.startsWith('\x1b')) {
      if (token == '\x1b[0m') {
        activeSgr.clear();
      } else {
        activeSgr.add(token);
      }
    }
  }

  void flushWord() {
    if (wordTokens.isEmpty) return;
    if (wordVisible > width) {
      // A single word longer than the width: hard-cut it across rows.
      if (col > 0) closeRow();
      for (final token in wordTokens) {
        final tokenWidth = _tokenWidth(token);
        // Close before an overflowing token, but never emit an empty row
        // (a single wide token on a 1-cell row just overflows as-is).
        if (col > 0 && !token.startsWith('\x1b') && col + tokenWidth > width) {
          closeRow();
        }
        writeToken(token, tokenWidth);
      }
    } else {
      if (col > 0 && col + wordVisible > width) closeRow();
      for (final token in wordTokens) {
        writeToken(token, _tokenWidth(token));
      }
    }
    wordTokens.clear();
    wordVisible = 0;
  }

  for (final match in _ansiTokenRe.allMatches(line)) {
    final token = match.group(0)!;
    if (token == ' ') {
      flushWord();
      // A boundary space ends the closing row when it fits; at the very edge
      // it is dropped rather than becoming an invisible leading space.
      if (col + 1 <= width) {
        writeToken(token, 1);
      } else {
        closeRow();
      }
      continue;
    }
    wordTokens.add(token);
    if (!token.startsWith('\x1b')) wordVisible += _tokenWidth(token);
  }
  flushWord();
  // A row holding only re-emitted SGR codes (no visible columns) is dropped.
  if (col > 0) closeRow();
  return rows;
}

/// The cell width of one wrap token: SGR escapes take no columns, anything
/// else is measured by grapheme cluster (fast path: a single ASCII rune).
int _tokenWidth(String token) {
  if (token.startsWith('\x1b')) return 0;
  if (token.length == 1) {
    final unit = token.codeUnitAt(0);
    // ASCII fast path: C0 controls are zero-width, printable ASCII is one
    // cell; everything wider/combining falls to the full measurement.
    if (unit < 0x80) {
      return (unit < 0x20 || unit == 0x7f) ? 0 : 1;
    }
  }
  return tuiTextWidth(token);
}

/// Incremental transcript formatter backing the fa TUI's `_WrapCache`
/// (docs/performance-cli-tui.md). The per-call [AnsiMarkdown.formatAll] is
/// O(transcript) and ran on every coalesced streaming flush (~20/s):
/// measured 26.96 ms per pass over a 2000-line history — over half of each
/// 50 ms flush interval spent between keystrokes. This class keeps ONE
/// long-lived [AnsiMarkdown] whose cross-line state persists across calls
/// (yoxterm rule §4, persistent parser state) and durably commits
/// formatted+wrapped results through a boundary index (rule §2, damage
/// tracking via a boundary instead of content diffs).
///
/// Correctness contract: after `sync(src)` the exposed views equal
/// `AnsiMarkdown(width).formatAll(src)` followed by the same wrap pass —
/// pinned adversarially in transcript_markdown_perf_test.dart. Tables open
/// across syncs re-render their tail from the last clean snapshot every
/// call: a table is the only block whose rendering depends on input that
/// has not arrived yet.
/// One consume-walk's results: per-line outputs aligned to src[from..),
/// the last step index that ended with an EMPTY pending-table buffer
/// (-1 when none), fence state at that step, whether a table was still
/// open at end-of-walk, and the end-flush output.
final class _WalkResult {
  _WalkResult(
    this.outsPerLine,
    this.lastClean,
    this.fenceAtClean,
    this.pendingEnd,
    this.trailing,
    this.fenceAfter,
  );

  final List<List<String>> outsPerLine;
  final int lastClean;
  final bool fenceAtClean;
  final bool pendingEnd;
  final List<String> trailing;

  /// Fence state after each consumed line (index i = state after src
  /// line from+i) — lets the commit edge remember the state just BEFORE
  /// the boundary line so a one-line rollback can restore it.
  final List<bool> fenceAfter;
}

final class TranscriptMarkdown {
  TranscriptMarkdown({required this.width}) : _fmt = AnsiMarkdown(width: width);

  /// Wrap/format width (terminal columns). Changed only via
  /// [widthOverrideForTest], which drops all caches onto the rebuild path.
  int width;

  AnsiMarkdown _fmt;

  /// Committed source-line count: rendering of src[0.._through) provably
  /// never changes with future input, so its caches are final.
  var _through = 0;

  // Raw first/last source lines at the commit boundary: cheap O(1)
  // identity sentinels. Copies keep element identity ([...history, d] /
  // sublist), so first-mismatch proves a FRONT drop (history-cap trim)
  // and last-mismatch proves the line just under the boundary was
  // REPLACED (callers regenerating their tail) — either lands on the
  // documented full-rebuild path rather than serving stale rows.
  String? _boundaryFirst;
  String? _boundaryLast;

  // Durable caches for src[0.._through): formatted lines, wrapped rows and
  // the line-to-row start index (total-row sentinel appended).
  List<String> _formatted = const [];
  List<String> _rows = const [];
  List<int> _starts = const [0];

  // Published views = durable caches (plus nothing today: an open-table
  // tail re-renders wholesale on the NEXT sync instead of being frozen
  // stale between calls, which keeps one source of truth).
  List<String> _viewFormatted = const [];
  List<String> _viewRows = const [];
  List<int> _viewStarts = const [0];

  // Pipeline state captured at the commit boundary ([_through]).
  var _savedFence = false;

  /// Fence state just BEFORE the boundary source line — the restore point
  /// used by the grown-tail rollback (streaming without newlines).
  var _fenceBeforeBoundaryLine = false;

  /// Start index into [_formatted] per SOURCE line (sentinel = current
  /// length) — lets the rollback drop exactly one source line's formatted
  /// output without a per-line map on the hot path.
  List<int> _srcFmtStarts = const [0];

  /// Start row into [_rows] per SOURCE line (sentinel = current length).
  List<int> _srcRowStarts = const [0];

  // Work counters — contract tests assert these, never timings.
  static int debugFullRebuilds = 0;
  static int debugResumedPasses = 0;
  static int debugLinesFormatted = 0;

  /// Growing-tail throttle (see [sync]): skips counted here.
  static int debugTailThrottled = 0;

  /// Only lines longer than this are throttled — test streams (and real
  /// short lines) must keep their byte-exact immediate behavior.
  static const int _tailThrottleMinLength = 8192;

  /// ~10 Hz re-render cap for an expensive still-growing tail line.
  static const int _tailThrottleIntervalMs = 100;
  int _lastTailProcessMs = -1000;

  /// Zeroes the debug counters.
  static void resetDebugCounters() {
    debugFullRebuilds = 0;
    debugResumedPasses = 0;
    debugLinesFormatted = 0;
    debugTailThrottled = 0;
  }

  /// Test seam: forces the next [sync] onto the rebuild path (simulates a
  /// terminal resize without constructing a new instance).
  void widthOverrideForTest(int newWidth) => width = newWidth;

  /// Test seams exposing internal progress for diagnostics.
  int get debugThroughForTest => _through;
  String? get debugBoundaryFirstForTest => _boundaryFirst;

  /// Formatted lines rendered so far.
  List<String> get formattedLines => _viewFormatted;

  /// Wrapped physical rows rendered so far.
  List<String> get wrappedRows => _viewRows;

  /// `lineStartRows[i]` = first wrapped row of rendered line `i`; final
  /// entry is the total-row-count sentinel (the exact shape `_WrapCache`
  /// stores).
  List<int> get lineStartRows => _viewStarts;

  /// Brings every view in line with [src]; returns [formattedLines].
  List<String> sync(List<String> src) {
    final resumable =
        width == _fmt.width &&
        src.length >= _through &&
        (_through == 0 ||
            (src.isNotEmpty &&
                identical(src.first, _boundaryFirst) &&
                identical(src[_through - 1], _boundaryLast)));
    if (!resumable && !_rollbackGrownTail(src)) {
      _rebuild(src);
      return _viewFormatted;
    }
    if (src.length == _through) {
      return _viewFormatted; // nothing new: pure cache hit
    }
    // Growing-tail throttle: a streamed paragraph whose last line has no
    // newline yet re-formats + re-wraps that line on EVERY flush — O(line
    // length), so a long thinking burst (tens of KB in one line) saturated
    // the event loop at the 16ms flush cadence: the screen froze (neither
    // the thinking nor typed input rendered) until the chunk ended. When
    // the ONLY pending change is such a line and it is expensive, process
    // it at ~10 Hz instead — the paragraph accumulates, everything else
    // (typing, other lines, the final newline) stays instant. Bytes are
    // never dropped: the unchanged `src` is re-offered on the next flush.
    if (src.length == _through + 1 &&
        src.last.length > _tailThrottleMinLength &&
        (DateTime.now().millisecondsSinceEpoch - _lastTailProcessMs) <
            _tailThrottleIntervalMs) {
      debugTailThrottled++;
      return _viewFormatted;
    }
    if (src.length == _through + 1) {
      _lastTailProcessMs = DateTime.now().millisecondsSinceEpoch;
    }
    debugResumedPasses++;
    debugLinesFormatted += src.length - _through;

    final r = _walk(src, from: _through);
    _commitTo(r, src, from: _through);
    _expose(r, src);
    return _viewFormatted;
  }

  /// A streaming flush WITHOUT a trailing newline grows the last source
  /// line into a NEW string with the SAME prefix. The boundary identity
  /// sentinel reads that as a "replaced tail" and used to take the full
  /// rebuild path — measured ~220ms per flush on a large transcript, i.e.
  /// per streamed chunk, starving the UI loop so keystrokes queued behind
  /// it (the typing-lag-while-streaming bug). A strictly prefix-extended
  /// tail can instead roll the durable caches back ONE source line and
  /// resume: only that line re-formats and re-wraps.
  bool _rollbackGrownTail(List<String> src) {
    if (width != _fmt.width) return false;
    if (_through <= 0 || src.length < _through) return false;
    final boundary = _boundaryLast;
    if (boundary == null || _boundaryFirst == null) return false;
    if (src.isEmpty || !identical(src.first, _boundaryFirst)) return false;
    final grown = src[_through - 1];
    if (grown.length <= boundary.length || !grown.startsWith(boundary)) {
      return false; // replaced, not grown — keep the documented safe path
    }
    final edge = _through - 1;
    final fmtKept = _srcFmtStarts[edge];
    final rowKept = _srcRowStarts[edge];
    // In-place truncation: sublist+spread copied the whole per-session
    // arrays on EVERY no-newline chunk, so cost grew with session length.
    _formatted.length = fmtKept;
    _rows.length = rowKept;
    _starts.length = fmtKept;
    _starts.add(_rows.length);
    _srcFmtStarts.length = edge;
    _srcFmtStarts.add(_formatted.length);
    _srcRowStarts.length = edge;
    _srcRowStarts.add(_rows.length);
    _through = edge;
    _boundaryLast = edge > 0 ? src[edge - 1] : null;
    _savedFence = _fenceBeforeBoundaryLine;
    return true;
  }

  /// Consume-walk over src[from..) seeded with the frozen boundary state.
  _WalkResult _walk(List<String> src, {required int from}) {
    _fmt.restoreState(inFence: _savedFence, table: const []);
    final outsPerLine = <List<String>>[];
    final fenceAfter = <bool>[];
    var lastClean = -1; // step whose completion left no pending table
    var fenceAtClean = false;
    for (var i = from; i < src.length; i++) {
      outsPerLine.add(_fmt.consumeLine(src[i]));
      fenceAfter.add(_fmt.inFence);
      if (!_fmt.hasPendingTable) {
        lastClean = outsPerLine.length - 1;
        fenceAtClean = _fmt.inFence;
      }
    }
    return _WalkResult(
      outsPerLine,
      lastClean,
      fenceAtClean,
      _fmt.hasPendingTable,
      _fmt.flushTrailing(),
      fenceAfter,
    );
  }

  /// Folds everything UP TO THE LAST CLEAN STEP into the durable caches.
  ///
  /// The boundary NEVER advances past a still-open table's first row:
  /// rendering for those rows is not final (column widths may still grow),
  /// and the frozen snapshot carries only fence state. Advancing into the
  /// open span would lose buffered rows on the next resume. Found
  /// adversarially by transcript_table_render_test.dart.
  void _commitTo(_WalkResult r, List<String> src, {required int from}) {
    final upto = r.lastClean + 1; // count of leading final steps
    if (upto <= 0) return;
    final formatted = [..._formatted];
    final rows = [..._rows];
    final starts = [..._starts]..removeLast(); // per formatted line
    final fmtStarts = [..._srcFmtStarts]..removeLast(); // per source line
    final rowStarts = [..._srcRowStarts]..removeLast(); // per source line
    for (var step = 0; step < upto; step++) {
      fmtStarts.add(formatted.length);
      rowStarts.add(rows.length);
      for (final line in r.outsPerLine[step]) {
        starts.add(rows.length);
        formatted.add(line);
        rows.addAll(wrapAnsiLine(line, width));
      }
    }
    _formatted = formatted;
    _rows = rows;
    _starts = [...starts, rows.length];
    _srcFmtStarts = [...fmtStarts, formatted.length];
    _srcRowStarts = [...rowStarts, rows.length];
    _through = from + upto;
    if (from == 0) _boundaryFirst ??= src.first;
    _boundaryLast = src[_through - 1];
    _fenceBeforeBoundaryLine = upto >= 2 ? r.fenceAfter[upto - 2] : _savedFence;
    _savedFence = r.fenceAtClean;
  }

  /// Publishes caches + whatever this walk produced beyond the commit
  /// edge (an open-table span and/or the end-flush) as fresh view lists;
  /// durable caches stay untouched by provisional bytes.
  void _expose(_WalkResult r, List<String> src) {
    final tailStartStep = r.lastClean + 1;
    final tailLines = <String>[
      for (var step = tailStartStep; step < r.outsPerLine.length; step++)
        ...r.outsPerLine[step],
      ...r.trailing,
    ];
    if (tailLines.isEmpty) {
      _publishCleanViews();
      return;
    }
    final tailRows = <String>[];
    final tailStarts = <int>[];
    final rowOffset = _rows.length;
    final past = <int>[..._starts.sublist(0, _starts.length - 1)];
    for (final line in tailLines) {
      tailStarts.add(rowOffset + tailRows.length);
      tailRows.addAll(wrapAnsiLine(line, width));
    }
    final total = rowOffset + tailRows.length;
    _viewFormatted = [..._formatted, ...tailLines];
    _viewRows = [..._rows, ...tailRows];
    _viewStarts = [...past, ...tailStarts, total];
  }

  void _publishCleanViews() {
    _viewFormatted = _formatted;
    _viewRows = _rows;
    _viewStarts = _starts;
  }

  /// Full-rebuild fallback: width change, head-trimmed or shrunk source.
  /// Legacy behavior byte-for-byte (one formatAll + wrap pass), adopted as
  /// the durable baseline.
  void _rebuild(List<String> src) {
    debugFullRebuilds++;
    debugLinesFormatted += src.length;
    final fmt = AnsiMarkdown(width: width);
    final outs = <List<String>>[];
    final fenceAfter = <bool>[];
    var lastClean = -1;
    var fenceAtClean = false;
    for (final line in src) {
      outs.add(fmt.consumeLine(line));
      fenceAfter.add(fmt.inFence);
      if (!fmt.hasPendingTable) {
        lastClean = outs.length - 1;
        fenceAtClean = fmt.inFence;
      }
    }
    final hadPending = fmt.hasPendingTable;
    final trailing = fmt.flushTrailing();

    _fmt = fmt;
    _formatted = [];
    _rows = [];
    // Empty-but-sentineled shape: the commit drops the trailing sentinel
    // via removeLast, so fresh caches must already carry [0].
    _starts = [0];
    _srcFmtStarts = [0];
    _srcRowStarts = [0];
    _fenceBeforeBoundaryLine = false;
    _through = 0;
    _boundaryFirst = src.isEmpty ? null : src.first;
    _boundaryLast = src.isEmpty ? null : src.last;
    _savedFence = false;
    final r = _WalkResult(
      outs,
      lastClean,
      fenceAtClean,
      hadPending,
      trailing,
      fenceAfter,
    );
    _commitTo(r, src, from: 0);
    _savedFence = fenceAtClean; // even without a durable edge yet
    _expose(r, src);
  }
}
