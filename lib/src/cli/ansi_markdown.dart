/// Incremental markdown-to-ANSI formatter for the TUI output history.
///
/// The TUI stores raw assistant text and formats it at view time: a fresh
/// [AnsiMarkdown] walks the (bounded) output lines top-to-bottom on every
/// frame via [formatAll], so multi-line state (code fences, tables) is
/// tracked while partial markdown from an in-flight stream simply renders
/// unstyled until its closing marker arrives. Only SGR sequences
/// (`\x1b[...m`) are emitted — the same set the viewport already strips
/// when measuring visible width for soft-wrapping, so scroll math stays
/// correct. Output preserves the input line count 1:1 (tables render one
/// grid row per source row, without top/bottom borders) so the viewport
/// scroll offset never shifts.
///
/// The visual mapping follows pi's `packages/tui/src/components/markdown.ts`
/// dark theme, retinted to the site palette (teal/indigo): headings without
/// the `#` prefix (H1 also underlined), fenced code indented 2 spaces with
/// dim border lines and no background, `│ ` quote bars, accent list
/// bullets, box-grid tables with a dim separator row, and full-width
/// horizontal rules capped at 80 columns.
library;

/// One formatter per render pass; feed the whole output buffer via
/// [formatAll] (or single lines in order via [formatLine]).
final class AnsiMarkdown {
  AnsiMarkdown({this.width = 80});

  /// Terminal width, used for horizontal rules (capped at 80 like pi) and
  /// as the table-fit budget (wider tables fall back to raw markdown).
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

  /// Formats the whole output buffer, preserving the line count 1:1.
  /// Table rows are buffered until the table ends so column widths can be
  /// computed across every row before rendering.
  List<String> formatAll(List<String> lines) {
    final out = <String>[];
    for (final line in lines) {
      if (!_inFence && _isTableRow(line)) {
        _tableBuffer.add(line);
        continue;
      }
      out.addAll(_flushTable());
      out.add(formatLine(line));
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
    if (line.startsWith('\x1b[48')) {
      final visible = line.replaceAll(_ansiRe, '');
      final pad = width - visible.length;
      if (pad <= 0) return line;
      final body = line.endsWith(_reset)
          ? line.substring(0, line.length - _reset.length)
          : line;
      return '$body${' ' * pad}$_reset';
    }

    // Full-width rules are stored baked at submit-time width; re-render them
    // at the current width so a resize never leaves ragged bars behind.
    final stripped = line.replaceAll(_ansiRe, '');
    if (stripped.length > 2 && _ruleRe.hasMatch(stripped)) {
      return '$_dim${'─' * width}$_reset';
    }

    // Code fences swallow everything between the markers verbatim (pi:
    // content indented 2 spaces, no background, dim border lines).
    if (_fenceRe.hasMatch(line)) {
      _inFence = !_inFence;
      return '$_dim$line$_reset';
    }
    if (_inFence) {
      return '  $line';
    }

    final header = _headerRe.firstMatch(line);
    if (header != null) {
      final level = header.group(1)!.length;
      final text = header.group(2)!;
      // pi: H1 bold+underline, H2 bold, H3+ keeps the literal ### prefix.
      return switch (level) {
        1 => '$_indigo$_bold$_underline$text$_reset',
        2 => '$_indigo$_bold$text$_reset',
        _ => '$_indigo$_bold${header.group(1)} $text$_reset',
      };
    }
    if (_hrRe.hasMatch(line)) {
      final ruleWidth = width < 80 ? width : 80;
      return '$_dim${'─' * ruleWidth}$_reset';
    }
    final quote = _quoteRe.firstMatch(line);
    if (quote != null) {
      final body = _formatInline(quote.group(3)!);
      return '${quote.group(1)}$_dim│$_reset $_dim$_italic$body$_reset';
    }
    final bullet = _bulletRe.firstMatch(line);
    if (bullet != null) {
      final marker = bullet.group(2)!;
      final body = bullet.group(3)!;
      // Task list items keep their checkbox (pi renders [x] / [ ]).
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
    return _formatInline(line);
  }

  /// Inline spans: links, inline code, bold, strikethrough, italic. Code
  /// spans are formatted before emphasis so markers inside them stay
  /// literal; every span is self-contained (SGR + reset).
  String _formatInline(String text) {
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
      return [for (final row in rows) _formatInline(row)];
    }

    final widths = List<int>.filled(columnCount, 0);
    // Column widths come from the FORMATTED cells: inline markers (the
    // backticks of `code`, ** of bold, ...) render away, so sizing columns
    // by raw text would push the separators right of the header's grid.
    final formatted = <int, List<String>>{};
    for (var r = 0; r < rows.length; r++) {
      if (r == 1) continue; // separator row has no content width
      formatted[r] = [
        for (var c = 0; c < columnCount; c++) _formatInline(cells[r][c]),
      ];
      for (var c = 0; c < columnCount; c++) {
        final visible = _visibleLength(formatted[r]![c]);
        if (visible > widths[c]) widths[c] = visible;
      }
    }
    // ' cell ' per column plus ' │ ' joins; pi falls back to raw when the
    // table does not fit — so do we.
    final total =
        widths.fold<int>(0, (a, b) => a + b) +
        columnCount * 2 +
        (columnCount - 1) * 3;
    if (total > width) {
      return [for (final row in rows) _formatInline(row)];
    }

    final out = <String>[];
    for (var r = 0; r < rows.length; r++) {
      if (r == 1) {
        // Separator row: '───┼───' in dim.
        out.add(
          '$_dim${[for (var c = 0; c < columnCount; c++) '─' * (widths[c] + 2)].join('┼')}$_reset',
        );
        continue;
      }
      final isHeader = r == 0;
      final renderedCells = <String>[];
      for (var c = 0; c < columnCount; c++) {
        final styled = formatted[r]![c];
        final padded = styled + ' ' * (widths[c] - _visibleLength(styled));
        renderedCells.add(isHeader ? '$_bold$padded$_reset' : padded);
      }
      out.add(' ${renderedCells.join(' $_dim│$_reset ')} ');
    }
    return out;
  }

  static int _visibleLength(String text) => text.replaceAll(_ansiRe, '').length;
}

/// Tokenizer for [wrapAnsiLine] — hoisted: it runs per wrapped line, and
/// building the RegExp there dominated the wrap cost on long histories.
final _ansiTokenRe = RegExp(r'\x1b\[[0-9;]*m|.', unicode: true);

/// Wraps one ANSI-styled line to [width] visible columns WITHOUT cutting
/// inside SGR escape sequences — dart_tui's viewport wrap slices raw text
/// and leaks escape tails (e.g. `212m`) as visible text. SGR state carries
/// across the cut, so styles continue correctly on the next row. The
/// unicode flag makes `.` match whole runes, keeping emoji intact.
List<String> wrapAnsiLine(String line, int width) {
  if (width <= 0) return [line];
  final visible = line.replaceAll(AnsiMarkdown.ansiSgrPattern, '').length;
  if (visible <= width) return [line];
  final rows = <String>[];
  var current = StringBuffer();
  var col = 0;
  final tokens = _ansiTokenRe.allMatches(line);
  for (final match in tokens) {
    final token = match.group(0)!;
    if (token.startsWith('\x1b')) {
      current.write(token);
      continue;
    }
    if (col >= width) {
      rows.add(current.toString());
      current = StringBuffer();
      col = 0;
    }
    current.write(token);
    col++;
  }
  if (current.isNotEmpty) rows.add(current.toString());
  return rows;
}
