/// The gh-1933 v2 per-tool row content: what each settled transcript row
/// SAYS beyond the label — read `path + selector + lines-read`, edit/write
/// diffstat `+N −M`, bash intent label + output-lines count + dim command
/// preview, thinking `> Thought for Ns`, and the child/span/secret
/// contracts for task, checkpoint, and request_secret rows.
///
/// PURE derivation from persisted record material only (call arguments +
/// result text): no filesystem access, no re-derivation from live state —
/// a replayed session renders the same rows from the same records
/// (gh-1933 AC5, rendering-only). Width/layout math and palette escapes
/// stay with the callers (`tool_rows.dart` / `tui_chrome.dart`); the
/// diffstat label is RAW text painted through [paintDiffstat] at emit
/// time.
library;

import '../hashline/hashline.dart'
    show HashlineDelete, HashlineInsert, HashlinePatch;
import '../tools/read_selector.dart'
    show
        LineRange,
        ReadSelectorLines,
        ReadSelectorRaw,
        parseSel,
        splitPathAndSel;
import '../types.dart' show ContentBlock, TextContent;
import 'tool_rows.dart'
    show briefPath, collapseCd, shellJobCommandPreview, toolRowDetail;
import 'tui_chrome.dart'
    show failureFirstLine, paintDiffstat, settledToolCardRows;

/// Lines added/removed by one applied change (gh-1933 AC2).
final class DiffStat {
  const DiffStat(this.added, this.removed);

  /// Lines the change introduced.
  final int added;

  /// Lines the change removed.
  final int removed;

  /// Whether nothing changed (an empty stat renders no fragment).
  bool get isEmpty => added == 0 && removed == 0;

  /// The RAW `+N −M` label: an ASCII `+`, then U+212 MINUS SIGN before
  /// the removal count, between regular spaces — matching the ticket
  /// grammar (and [paintDiffstat]'s `^\+(\d+) −(\d+)$`) verbatim.
  String get label => isEmpty ? '' : '+$added −$removed';
}

/// Line-level diffstat between the old and new text of an applied change:
/// multiset accounting — a line old has and new lacks was REMOVED, a line
/// new has and old lacks was ADDED (reordered identical lines cancel, so
/// a pure reorder is a no-op and duplicates count per occurrence).
DiffStat diffStatLines(String oldText, String newText) {
  final oldCounts = _lineCounts(oldText);
  final newCounts = _lineCounts(newText);
  var added = 0;
  var removed = 0;
  for (final entry in newCounts.entries) {
    final have = oldCounts[entry.key] ?? 0;
    if (entry.value > have) added += entry.value - have;
  }
  for (final entry in oldCounts.entries) {
    final have = newCounts[entry.key] ?? 0;
    if (entry.value > have) removed += entry.value - have;
  }
  return DiffStat(added, removed);
}

/// Line multiset of [text]: one trailing newline does not add a line
/// (the file's last line is real; the terminator is not).
Map<String, int> _lineCounts(String text) {
  final lines = text.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  final counts = <String, int>{};
  for (final line in lines) {
    counts[line] = (counts[line] ?? 0) + 1;
  }
  return counts;
}

/// The diffstat of an `edit` call's arguments (gh-1933 AC2): exact-match
/// mode diffs `oldText` against `newText`; hashline mode parses the patch
/// and counts the lowered edits (inserts added, deletes removed — a SWAP
/// hunk lands as its replacement rows plus its consumed range). Anything
/// not derivable from the arguments returns null — never a guess.
DiffStat? diffStatFromEditArgs(Map<String, dynamic> args) {
  final patch = args['patch'];
  if (patch is String && patch.trim().isNotEmpty) {
    return _diffStatFromPatch(patch);
  }
  final oldText = args['oldText'];
  final newText = args['newText'];
  if (oldText is String && newText is String) {
    return diffStatLines(oldText, newText);
  }
  return null;
}

DiffStat? _diffStatFromPatch(String patch) {
  try {
    final parsed = HashlinePatch.parse(patch);
    var added = 0;
    var removed = 0;
    for (final section in parsed.sections) {
      for (final edit in section.edits) {
        switch (edit) {
          case HashlineInsert():
            added++;
          case HashlineDelete():
            removed++;
        }
      }
    }
    return DiffStat(added, removed);
  } on Object {
    // An unparsable patch contributes no diffstat — the result carries
    // the error (a rejected patch renders its error summary, AC2).
    return null;
  }
}

/// The read row's `path + selector` detail (gh-1933 AC1): the brief path
/// plus the trailing selector rendered compactly per shape — none (bare
/// path), `:N`/`:A-B` (ranges; `..` normalizes to `-`, `:A+C` to its
/// inclusive end), multi-ranges comma-joined, `:raw`, compounds
/// (`:50-100:raw`). Archive (`a.zip:inner/file`) and SQLite
/// (`db.sqlite:table`) colon syntax is never peeled — it stays part of
/// the path, which IS those targets' compact shape. Legacy `offset`/
/// `limit` arguments render their `:A-B`/`:A-` window.
String readRowSelector(
  String rawPath, {
  Object? offset,
  Object? limit,
  String? cwd,
  String? home,
}) {
  final split = splitPathAndSel(rawPath);
  final base = briefPath(split.path, cwd: cwd, home: home);
  final sel = split.sel != null
      ? _selectorToken(split.sel!)
      : _offsetLimitToken(offset, limit);
  return sel.isEmpty ? base : '$base:$sel';
}

String _offsetLimitToken(Object? offset, Object? limit) {
  if (offset is! num) return '';
  return limit is num
      ? '${offset.toInt()}-${limit.toInt()}'
      : '${offset.toInt()}-';
}

/// The compact token for a recognized selector tail (omp's grammar).
String _selectorToken(String sel) {
  final parsed = parseSel(sel);
  return switch (parsed) {
    ReadSelectorRaw() => 'raw',
    ReadSelectorLines(:final ranges, :final raw) =>
      '${ranges.map(_rangeToken).join(',')}${raw ? ':raw' : ''}',
    // Unrecognized (defensive — [splitPathAndSel] only peels recognized
    // tails): keep the authored text.
    _ => sel,
  };
}

String _rangeToken(LineRange range) => range.endLine == null
    ? '${range.startLine}-'
    : '${range.startLine}-${range.endLine}';

/// The read outcome count (gh-1933 AC1): `20 lines read` from the result
/// text; a head-truncated read reports shown-of-total from its
/// continuation notice — anchored to the result's LAST line (review
/// thread PRRT_kwDOTXdlLc6w5WAf: a read whose CONTENT quotes a past
/// notice — session JSONLs, harness logs — must not misreport). Empty
/// results contribute no fragment.
String? readOutcomeMeta(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final notice = trimmed.split('\n').last;
  final match = RegExp(
    r'^\[Showing lines (\d+)-(\d+) of (\d+)\.',
  ).firstMatch(notice);
  if (match != null) {
    final shown = int.parse(match.group(2)!) - int.parse(match.group(1)!) + 1;
    return '$shown of ${match.group(3)} lines read';
  }
  final lines = trimmed.split('\n').length;
  return lines == 1 ? '1 line read' : '$lines lines read';
}

/// The bash row's intent label (gh-1933 AC3): the `cd`-collapsed,
/// heredoc-aware command's first words — the full one-liner stays one
/// keypress away in the dim preview below the row (and in line mode /
/// headless, unchanged).
const _bashIntentWords = 6;

String bashIntentLabel(String command) {
  if (command.trim().isEmpty) return '';
  final preview = shellJobCommandPreview(collapseCd(command));
  final words = preview
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.length <= _bashIntentWords) return preview;
  return '${words.take(_bashIntentWords).join(' ')}…';
}

/// The bash row's output-lines count (`15 lines`, `1 line`); empty output
/// contributes no fragment.
String? bashOutputMeta(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final lines = trimmed.split('\n').length;
  return lines == 1 ? '1 line' : '$lines lines';
}

/// The collapsed thinking row's label (gh-1933 AC4): `> Thought for Ns`
/// from the streamed window; a replayed block has no duration on the
/// record and carries the honest `—` (the same lossy bit as the replayed
/// elapsed cell, issue #446 contract point 2).
String thinkingRowLabel(int? seconds) =>
    seconds == null ? 'Thought for —' : 'Thought for ${seconds}s';

/// The thinking rows for one block: the collapsed `> Thought for Ns` row,
/// or — expanded (the `/transcript expand all` state) — the same label
/// row followed by the block's full persisted text (everything today's
/// dim streaming showed, gh-1933 AC4/AC5).
List<String> thinkingCollapsedRows({
  required String text,
  int? seconds,
  bool expanded = false,
}) => ['> ${thinkingRowLabel(seconds)}', if (expanded) ...text.split('\n')];

/// One settled row's derived content (gh-1933 capability surface).
final class ToolRowContent {
  const ToolRowContent({
    this.detail = '',
    this.meta = const [],
    this.diffstat,
    this.preview = const [],
  });

  /// The human detail under the label (path+selector, intent, question…).
  final String detail;

  /// Dim meta fragments (outcome counts).
  final List<String> meta;

  /// The RAW `+N −M` diffstat label, when the applied change derives one.
  final String? diffstat;

  /// The dim preview line(s) under the row (the bash command one-liner).
  final List<String> preview;
}

/// The per-tool content derivation for a settled row: arguments and
/// result text in, detail/meta/diffstat/preview out (the capability
/// table's content contract). Error results lead with the failure line
/// and carry no counts (the failure IS the news, #366). The dispatcher
/// is a flat switch over the collapsed row kind ([_rowKind]); each arm's
/// body lives in its per-tool helper (the `toolRowDetail` house shape —
/// the CRAP ratchet pins the dispatcher complexity).
ToolRowContent toolRowContent(
  String toolName,
  Map<String, dynamic> args, {
  List<ContentBlock> resultContent = const [],
  bool isError = false,
  String? cwd,
  String? home,
}) {
  if (isError) {
    return ToolRowContent(detail: failureFirstLine(resultContent));
  }
  return switch (_rowKind(toolName)) {
    'read' => _readRowContent(args, resultContent, cwd: cwd, home: home),
    'write' => _writeRowContent(toolName, args, cwd: cwd, home: home),
    'bash' => _bashRowContent(args, resultContent),
    'task' => ToolRowContent(detail: _taskDetail(args)),
    'task_send' => ToolRowContent(detail: _childDetail(args)),
    'checkpoint' => ToolRowContent(detail: _checkpointDetail(toolName, args)),
    'request_secret' => _secretRowContent(args),
    // The #366 fallback grammar (ask question text, unknown tools'
    // first string argument) stays the contract for everything else.
    _ => ToolRowContent(
      detail: toolRowDetail(toolName, args, cwd: cwd, home: home),
    ),
  };
}

/// Collapses the tool-name aliases onto one row grammar kind — `edit`
/// writes, `bash_job` bashes, `task_send`/`task_resume` child-update,
/// `rewind` checkpoints — so the [toolRowContent] dispatcher stays a
/// flat switch under the CRAP ratchet.
String _rowKind(String toolName) => switch (toolName) {
  'edit' => 'write',
  'bash_job' => 'bash',
  'task_send' || 'task_resume' => 'task_send',
  'rewind' => 'checkpoint',
  _ => toolName,
};

/// The read row: `path + selector` detail plus the lines-read meta.
ToolRowContent _readRowContent(
  Map<String, dynamic> args,
  List<ContentBlock> resultContent, {
  String? cwd,
  String? home,
}) => ToolRowContent(
  detail: readRowSelector(
    _stringArg(args, 'path'),
    offset: args['offset'],
    limit: args['limit'],
    cwd: cwd,
    home: home,
  ),
  meta: [?readOutcomeMeta(_resultText(resultContent))],
);

/// The edit/write row: the path detail plus the applied-change diffstat.
ToolRowContent _writeRowContent(
  String toolName,
  Map<String, dynamic> args, {
  String? cwd,
  String? home,
}) {
  final stat = toolName == 'edit'
      ? diffStatFromEditArgs(args)
      : _writeDiffStat(args);
  return ToolRowContent(
    detail: briefPath(_stringArg(args, 'path'), cwd: cwd, home: home),
    diffstat: stat == null || stat.isEmpty ? null : stat.label,
  );
}

/// The bash/bash_job row: intent detail, output-lines meta, and the dim
/// one-line command preview.
ToolRowContent _bashRowContent(
  Map<String, dynamic> args,
  List<ContentBlock> resultContent,
) {
  final command = _stringArg(args, 'command');
  return ToolRowContent(
    detail: bashIntentLabel(command),
    meta: [?bashOutputMeta(_resultText(resultContent))],
    preview: command.trim().isEmpty
        ? const []
        : [shellJobCommandPreview(collapseCd(command))],
  );
}

/// The request_secret row: the credential name (or the bare noun).
ToolRowContent _secretRowContent(Map<String, dynamic> args) {
  final name = _stringArg(args, 'name');
  return ToolRowContent(detail: name.isEmpty ? 'credential' : name);
}

/// `write` replaces the whole file: the change's add side is the written
/// line count (the old content is not in the persisted record — a
/// rendering-only row never re-derives it).
DiffStat _writeDiffStat(Map<String, dynamic> args) {
  final content = args['content'];
  if (content is! String) return const DiffStat(0, 0);
  final lines = content.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return DiffStat(lines.length, 0);
}

String _taskDetail(Map<String, dynamic> args) {
  final tasks = args['tasks'];
  if (tasks is! List || tasks.isEmpty) return _firstStringArg(args);
  final names = <String>[];
  var firstTask = '';
  for (final task in tasks) {
    if (task is! Map) continue;
    final name = task['name'];
    if (name is String && name.trim().isNotEmpty) names.add(name.trim());
    if (firstTask.isEmpty && task['task'] is String) {
      firstTask = bashIntentLabel(task['task'] as String);
    }
  }
  final who = names.isEmpty
      ? '${tasks.length} ${tasks.length == 1 ? 'child' : 'children'}'
      : names.join(', ');
  return firstTask.isEmpty ? who : '$who · $firstTask';
}

String _childDetail(Map<String, dynamic> args) {
  final id = _stringArg(args, 'id');
  final message = _stringArg(args, 'message');
  if (id.isEmpty) return message;
  return message.isEmpty ? id : '$id · $message';
}

String _checkpointDetail(String toolName, Map<String, dynamic> args) {
  if (toolName == 'checkpoint') {
    return bashIntentLabel(_stringArg(args, 'goal'));
  }
  // rewind: the span outcome is the retained report; a bare rewind
  // names the anchor it returned to.
  final report = bashIntentLabel(_stringArg(args, 'report'));
  return report.isEmpty ? 'back to the checkpoint anchor' : report;
}

String _stringArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  return value is String ? value.trim() : '';
}

String _firstStringArg(Map<String, dynamic> args) {
  for (final value in args.values) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

String _resultText(List<ContentBlock> content) =>
    content.whereType<TextContent>().map((block) => block.text).join();

/// The settled end-row BOTH edges paint for one executed call (gh-1933):
/// the per-tool content contract through the shared
/// [settledToolCardRows] builder. ONE source for the live
/// `_onToolExecutionEnd` and the replay `replayToolRow` — parity by
/// construction. [elapsed] is the live seconds cell or the replay's
/// honest `—`; null drops the right zone (a call whose clock never
/// started).
List<String> settledCallCardRows({
  required String toolName,
  required Map<String, dynamic> args,
  List<ContentBlock> resultContent = const [],
  bool isError = false,
  bool interrupted = false,
  required int width,
  String? elapsed,
  String? cwd,
  String? home,
}) {
  final content = toolRowContent(
    toolName,
    args,
    resultContent: resultContent,
    // Only a real error result flips the content to the failure line —
    // an INTERRUPTED call (replay-only) keeps its args preview over the
    // error phase (issue #446 contract point 1).
    isError: isError,
    cwd: cwd,
    home: home,
  );
  return settledToolCardRows(
    toolName: toolName,
    successDetail: content.detail,
    isError: isError,
    width: width,
    resultContent: resultContent,
    meta: content.meta,
    interrupted: interrupted,
    diffstat: content.diffstat ?? '',
    rightElapsed: elapsed ?? '',
    previewLines: content.preview,
  );
}

/// The expanded/collapsed transcript state (`/transcript expand all|none`,
/// gh-1933 interaction): thinking rows render collapsed (`> Thought for
/// Ns`) by default; `all` renders their persisted text under the label.
/// Affects rows emitted after the switch and the in-process `/resume`
/// replay; bash previews always render. Process-scoped: a restart replays
/// collapsed (review thread PRRT_kwDOTXdlLc6w5WCs — `/transcript` is not a
/// persisted setting).
var transcriptExpandDetails = false;
