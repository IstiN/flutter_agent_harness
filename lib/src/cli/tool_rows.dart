/// The compact tool-row grammar (issue #366): every builtin tool renders as
/// `<glyph> <label> · <detail> <elapsed>` — oh-my-pi-style, brand-colored,
/// budget-aware.
///
/// Pure layout + human-detail extraction; palette escapes are NEVER baked
/// here. Width math runs on RAW text (the #279 E1 rule): the caller styles
/// the laid-out segments at emit time via [LaidOutToolRow.style], so a
/// mid-session `/theme` switch is honored by the next row and the `…` the
/// fitter appended is painted with its segment, not pre-colored.
///
/// The visible row never carries the raw tool-argument JSON envelope: the
/// detail is the question text, the command, or the path — see
/// [toolRowDetail].
library;

import 'tui_text_width.dart';

/// A tool row's lifecycle state (issue #444): the row's border role is
/// picked by state, never hardcoded — running rows carry the accent
/// border, settled rows the quiet muted border, done/failed rows the
/// success/error tints.
enum ToolRowState { running, settled, done, failed }

/// One tool row's content, ready for layout.
final class ToolRowSegments {
  const ToolRowSegments({
    required this.glyph,
    required this.label,
    this.detail = '',
    this.elapsed = '',
  });

  /// The state marker (`•` running, `✓` done, `✗` error).
  final String glyph;

  /// The short tool name (`ask`, `bash`, `read`, …).
  final String label;

  /// The human detail (question text, command, path). Empty = the grammar
  /// degrades to glyph+label with no dangling `·` (issue #366 E2).
  final String detail;

  /// The dim trailing zone: `Ns` elapsed on end rows, or the `/tasks` job
  /// suffix (id + relativized log path).
  final String elapsed;
}

/// A row laid out within the width budget: every segment already fitted,
/// the `·` separator present only when a detail survived (E2).
final class LaidOutToolRow {
  const LaidOutToolRow(this.parts);

  /// Raw segments in print order (`glyph`, `label`, `·`, detail, elapsed);
  /// empty segments and the separator-when-no-detail are already dropped.
  final List<String> parts;

  /// The plain (unstyled) row.
  String join() => parts.join(' ');

  /// Paints the row at emit time: the glyph carries the state color, the
  /// label the bold tool-title accent, detail/separator/elapsed the muted
  /// role. Painters receive RAW text and return SGR-wrapped text.
  String style({
    required String Function(String) glyph,
    required String Function(String) label,
    required String Function(String) dim,
  }) {
    final painted = <String>[
      for (final (i, part) in parts.indexed)
        switch (i) {
          0 => glyph(part),
          1 => label(part),
          _ => dim(part),
        },
    ];
    return painted.join(' ');
  }
}

/// Lays one row out on [width] terminal cells (grapheme-safe): the label
/// and the trailing zone always fit in full (issue #366 AC2) — only the
/// detail absorbs a narrow terminal, ellipsized via [tuiFitWidth] and only
/// when the budget is genuinely exceeded.
LaidOutToolRow layoutToolRow(ToolRowSegments s, int width) {
  final w = width < 1 ? 1 : width;
  final glyphW = s.glyph.isEmpty ? 0 : tuiTextWidth('${s.glyph} ');
  final elapsedW = s.elapsed.isEmpty ? 0 : tuiTextWidth(' ${s.elapsed}');
  // Degenerate guard: even a label wider than the row stays on one line
  // (capped), because a soft-wrapped chrome row desyncs the renderer.
  final label = tuiFitWidth(s.label, (w - glyphW - elapsedW).clamp(1, w));
  final used = glyphW + tuiTextWidth(label) + elapsedW;
  final detailBudget = w - used - tuiTextWidth(' · ');
  final detail = s.detail.isEmpty || detailBudget < 1
      ? ''
      : tuiFitWidth(_flatten(s.detail), detailBudget);
  return LaidOutToolRow([
    if (s.glyph.isNotEmpty) s.glyph,
    label,
    if (detail.isNotEmpty) ...['·', detail],
    if (s.elapsed.isNotEmpty) s.elapsed,
  ]);
}

/// The human detail for a tool call (issue #366): the `ask` question text,
/// the `bash` command (`cd …/ && …` collapsed to the meaningful tail),
/// `read` → `path:lines`, `write`/`edit` → the path — never the JSON
/// envelope. Unknown tools degrade to their first string argument; no
/// string argument means an empty detail (E2).
String toolRowDetail(
  String toolName,
  Map<String, dynamic> args, {
  String? cwd,
  String? home,
}) {
  switch (toolName) {
    case 'ask':
      return _askDetail(args);
    case 'bash':
      return collapseCd(_firstString(args));
    case 'read':
      return _readDetail(args, cwd: cwd, home: home);
    case 'write':
    case 'edit':
    case 'ls':
    case 'bash_job':
      return _actionDetail(args);
    default:
      return _firstString(args);
  }
}

String _askDetail(Map<String, dynamic> args) {
  final questions = args['questions'];
  if (questions is List && questions.isNotEmpty) {
    final first = questions.first;
    if (first is Map && first['question'] is String) {
      return (first['question'] as String).trim();
    }
  }
  return _firstString(args);
}

String _readDetail(Map<String, dynamic> args, {String? cwd, String? home}) {
  final path = _firstString(args);
  if (path.isEmpty) return '';
  final offset = args['offset'];
  final limit = args['limit'];
  final lines = offset is num
      ? (limit is num
            ? ':${offset.toInt()}-${limit.toInt()}'
            : ':${offset.toInt()}')
      : '';
  return '${_briefPath(path, cwd: cwd, home: home)}$lines';
}

String _actionDetail(Map<String, dynamic> args) {
  final action = _firstString(args);
  final id = args['id'];
  return id is String && id.isNotEmpty ? '$action $id' : action;
}

/// Collapses a leading `cd <dir> && …` compound to the meaningful tail
/// (issue #366): the directory is job-site plumbing, the tail is the news.
String collapseCd(String command) {
  final match = RegExp(r'^cd\s+.+?\s*&&\s*(\S.*)$').firstMatch(command);
  return match == null ? command : match.group(1)!;
}

/// Project-relative when under [cwd], `~`-collapsed when under [home],
/// otherwise untouched (issue #366 point 4).
String briefPath(String path, {String? cwd, String? home}) =>
    _briefPath(path, cwd: cwd, home: home);

String _briefPath(String path, {String? cwd, String? home}) {
  var p = path;
  final c = cwd ?? '';
  if (c.isNotEmpty && (p == c || p.startsWith('$c/'))) {
    p = p == c ? '.' : p.substring(c.length + 1);
  }
  final h = home ?? '';
  if (h.isNotEmpty && (p == h || p.startsWith('$h/'))) {
    p = '~${p.substring(h.length)}';
  }
  return p;
}

/// The first String value in insertion order, whitespace-flattened — the
/// generic fallback that keeps unknown/MCP tools inside the grammar without
/// ever JSON-encoding an envelope.
String _firstString(Map<String, dynamic> args) {
  for (final value in args.values) {
    if (value is String && value.trim().isNotEmpty) return _flatten(value);
  }
  return '';
}

/// One display row, one line: newlines flatten to spaces, whitespace runs
/// collapse (a two-line compound command stays a single row).
String _flatten(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
