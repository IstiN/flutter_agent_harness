import '../context.dart';
import '../session/session_tree.dart'
    show branchSummaryPrefix, compactionSummaryPrefix;
import '../types.dart';
import 'system_notice_render.dart';
import 'tool_rows.dart';
import 'tui_theme.dart';

/// The restored-transcript renderer (issue #446): ONE pipeline for live and
/// replayed history. Every row type the live TUI draws is drawn here by the
/// SAME builder — tool rows through [layoutToolRow]/[toolRowDetail] with the
/// live end-row paints, system notices through [renderSystemNoticeLines],
/// assistant text as raw markdown the view styles at render time — so a
/// reopened session looks exactly like the moment the terminal was closed.
///
/// The only permitted live/replay difference is honest lossy bits: replayed
/// tool rows carry no live durations (the `—` elapsed zone where a live row
/// shows `3s`) and spinners never render from replay.

/// A code-fence opener/closer line (```). Tracked by the replay so a
/// truncated message never leaves a dangling fence: the view formats the
/// whole history as ONE markdown stream, and an unclosed fence would render
/// everything after it as verbatim code (raw `**`, tables, links).
final _fenceLineRe = RegExp(r'^\s*```');

/// The streamed-assistant prefix (`>_Fa `), byte-identical live and
/// replayed: bold first-accent `>_` plus bold `Fa`. The live stream emits it
/// once per assistant message before the first text delta; the replay puts
/// it on the replayed message's first text row.
String assistantStreamPrefix() =>
    '\x1b[1m${tuiAccentSoft('>_')}\x1b[0m\x1b[1mFa\x1b[0m ';

/// Appends a synthetic closing fence when [rows] (a truncated assistant
/// message) ends inside a fenced code block.
void _closeDanglingFence(List<String> rows) {
  final open = rows.fold<bool>(
    false,
    (open, row) => open != _fenceLineRe.hasMatch(row),
  );
  if (open) rows.add('```');
}

/// The tool row a persisted [ToolCall] replays as — the live end-row
/// builder ([layoutToolRow] + the `_onToolExecutionEnd` paints) fed from the
/// record itself: name + args preview, the attached result on errors. A
/// call whose result never landed (crash mid-turn) renders in its
/// interrupted `✗` state from the args — never a bare `[name]` marker.
/// [styled] paints with the live theme roles (TUI); line mode keeps the
/// plain grammar.
String replayToolRow(
  ToolCall call,
  ToolResultMessage? result, {
  required int width,
  String? cwd,
  String? home,
  bool styled = true,
}) {
  final failed = result == null || result.isError;
  var detail = toolRowDetail(call.name, call.arguments, cwd: cwd, home: home);
  var glyphPaint = tuiAccentSoft;
  var detailPaint = tuiDim;
  if (result != null && result.isError) {
    // The failure text is the news: bright first line, like the live row.
    glyphPaint = tuiError;
    detailPaint = (s) => s;
    detail = result.content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join()
        .split('\n')
        .first;
  }
  final row = layoutToolRow(
    // Settled state without live durations: the `—` elapsed zone is the
    // one permitted live/replay difference (issue #446 contract point 2).
    ToolRowSegments(
      glyph: failed ? '✗' : '✓',
      label: call.name,
      detail: detail,
      elapsed: '—',
    ),
    width,
  );
  return styled
      ? row.style(glyph: glyphPaint, label: tuiAccent2, dim: detailPaint)
      : row.join();
}

/// The TUI-mode projection of a restored user message: the same background
/// echo box the live submit draws; compaction/branch summaries render as
/// one compact chrome row; `<system-notice>` blocks ride the SAME
/// system-row renderer the live output path uses ([renderSystemNoticeLines]
/// — dim `> ⚙` blockquotes, never the raw fallback marker).
List<String> _replayUserTui(
  Object content,
  int width,
  String Function(String) dim,
) {
  final text = _blocksText(content);
  if (text.trim().isEmpty) return const [];
  final summary = _summaryMarker(text);
  if (summary != null) {
    final (label, firstLine) = summary;
    final hint = firstLine.isEmpty ? '' : ' — $firstLine';
    final markerLine = '$label$hint';
    // The marker fits the terminal width — a wrapped chrome row desyncs
    // the renderer.
    final line = markerLine.length > width
        ? '${markerLine.substring(0, width - 1)}…'
        : markerLine;
    return [dim('─' * width), dim(line), ''];
  }
  if (needsSystemNoticeRewrite(text)) return renderSystemNoticeLines(text);
  final bg = tuiUserMessageBgSgr();
  const reset = '\x1b[0m';
  return [
    dim('─' * width),
    for (final line in text.split('\n')) '$bg$line$reset',
    '',
  ];
}

/// The text of a message content: the raw string, or its text blocks joined.
String _blocksText(Object content) {
  return content is String
      ? content
      : (content as List<ContentBlock>)
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n');
}

/// The one-line chrome marker for a compaction/branch summary, or null.
String? _summaryMarkerLine(String text) {
  final summary = _summaryMarker(text);
  if (summary == null) return null;
  final (label, firstLine) = summary;
  final hint = firstLine.isEmpty ? '' : ' — $firstLine';
  return '$label$hint';
}

(String label, String firstLine)? _summaryMarker(String text) {
  final isCompaction = text.startsWith(compactionSummaryPrefix);
  if (!isCompaction && !text.startsWith(branchSummaryPrefix)) return null;
  final body = text.substring(
    (isCompaction ? compactionSummaryPrefix : branchSummaryPrefix).length,
  );
  var firstLine = '';
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('<')) {
      firstLine = trimmed;
      break;
    }
  }
  return (
    isCompaction
        ? '⋮ context compacted into a summary'
        : '⋮ summary of the detour branch',
    firstLine,
  );
}

/// Whether the text is replay chrome (system notice / compaction or branch
/// summary) the composer's ↑ input history must skip. Rendering goes
/// through the row builders; this is detection only.
bool _isChromeText(String text) =>
    needsSystemNoticeRewrite(text) || _summaryMarker(text) != null;

/// TUI-mode replay entry in the ACTIVE session's format: the user message
/// as the live submit echo box (notices via the system-row renderer), the
/// assistant message as dimmed thinking rows, the `>_Fa `-prefixed raw
/// markdown text the view styles exactly like a live stream, and one
/// settled tool row per persisted call ([replayToolRow]).
List<String> replayLinesTui(
  Message message, {
  required int width,
  required String Function(String) dim,
  Map<String, ToolResultMessage> results = const {},
  String? cwd,
  String? home,
}) {
  switch (message) {
    case UserMessage(:final content):
      return _replayUserTui(content, width, dim);
    case AssistantMessage(:final content):
      final rows = <String>[];
      for (final block in content.whereType<ThinkingContent>()) {
        // Reasoning replays dim like the live stream showed it (TUI only
        // live; the dim rows are the restored transcript's memory of it).
        rows.addAll(
          block.thinking
              .split('\n')
              .map((line) => line.trim().isEmpty ? line : dim(line)),
        );
      }
      final texts = content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n')
          .trim();
      var firstText = true;
      if (texts.isNotEmpty) {
        for (final line in texts.split('\n')) {
          // The live stream prints the `>_Fa ` prefix once per message,
          // before the first text delta — the replay mirrors it.
          rows.add(firstText ? '${assistantStreamPrefix()}$line' : line);
          firstText = false;
        }
      }
      for (final call in content.whereType<ToolCall>()) {
        rows.add(
          replayToolRow(
            call,
            results[call.id],
            width: width,
            cwd: cwd,
            home: home,
          ),
        );
      }
      return rows;
    default:
      return const [];
  }
}

/// One line-mode replay entry: the compact `you: `/`fa:  ` prefixed
/// projection. `maxRows <= 0` (the default through [buildReplayEntries])
/// replays the message IN FULL — the global row budget bounds which
/// messages replay instead. Assistant text renders plain (line mode has no
/// markdown), tool calls as unpainted tool rows — the same
/// [replayToolRow] grammar, never `[name]` markers.
List<String> replayLines(
  Message message, {
  required int maxRows,
  Map<String, ToolResultMessage> results = const {},
  String? cwd,
  String? home,
}) {
  if (message case UserMessage(:final content)) {
    final text = _blocksText(content);
    final summaryLine = _summaryMarkerLine(text);
    if (summaryLine != null) return [summaryLine];
    if (needsSystemNoticeRewrite(text)) return renderSystemNoticeLines(text);
  }
  final (prefix, body) = switch (message) {
    UserMessage(:final content) => ('you: ', _blocksText(content)),
    AssistantMessage(:final content) => (
      'fa:  ',
      [
        content.whereType<TextContent>().map((b) => b.text).join('\n').trim(),
        for (final call in content.whereType<ToolCall>())
          replayToolRow(
            call,
            results[call.id],
            width: 80,
            cwd: cwd,
            home: home,
            styled: false,
          ),
      ].where((s) => s.isNotEmpty).join('\n'),
    ),
    _ => ('', ''),
  };
  if (body.trim().isEmpty) return const [];
  final rows = body.split('\n');
  final head = maxRows > 0 ? rows.take(maxRows).toList() : rows;
  final suffix = maxRows > 0 && rows.length > maxRows ? ' …' : '';
  if (suffix.isNotEmpty) _closeDanglingFence(head);
  final indent = ' ' * prefix.length;
  return [
    for (var i = 0; i < head.length; i++)
      '${i == 0 ? prefix : indent}${head[i]}${i == head.length - 1 ? suffix : ''}',
  ];
}

/// The TUI composer's submitted-message history for a restored session:
/// the plain user-typed messages, oldest first — the same set live submits
/// record (no slash/bang commands, no system-notice/compaction chrome,
/// consecutive duplicates collapsed, last 100 kept). Restoring it makes ↑
/// recall the previous message right after a resume instead of scrolling
/// the transcript (issue #47).
List<String> restoredInputHistory(List<Message> messages) {
  final history = <String>[];
  for (final message in messages) {
    if (message is! UserMessage) continue;
    final text = _blocksText(message.content);
    if (text.trim().isEmpty ||
        text.startsWith('/') ||
        text.startsWith('!') ||
        _isChromeText(text)) {
      continue;
    }
    if (history.isEmpty || history.last != text) history.add(text);
  }
  return history.length > 100 ? history.sublist(history.length - 100) : history;
}

/// Builds the replay entries for a restored session's transcript: whole
/// per-message entries (user/assistant in FULL — no per-message head caps;
/// [maxRowsPerMessage] <= 0 means unlimited) filling [rowBudget] from the
/// END. A typical session replays verbatim; a marathon one drops OLDER
/// WHOLE messages rather than decapitating the tail's content. Tool results
/// attach to their calls' rows (see [replayToolRow]); they never render
/// standalone.
(List<List<String>> entries, int firstIndex) buildReplayEntries(
  List<Message> messages, {
  required bool tui,
  required int width,
  required String Function(String) dim,
  String? cwd,
  String? home,
  int rowBudget = 1900,
  int maxRowsPerMessage = 0,
}) {
  // Pair persisted results with their calls up front so each replayed call
  // renders its attached result (name + args preview + result), the same
  // material the live end row had.
  final results = {
    for (final message in messages)
      if (message is ToolResultMessage) message.toolCallId: message,
  };
  final entries = <List<String>>[];
  var firstIndex = messages.length;
  var rows = 0;
  for (var i = messages.length - 1; i >= 0; i--) {
    // Boot budget guard: nothing further from the head can fit — stop
    // BEFORE formatting it (monster messages are the boot-cost driver).
    if (entries.isNotEmpty && rows >= rowBudget) break;
    final message = messages[i];
    if (message is ToolResultMessage) {
      // Results render attached to their call's row, never standalone —
      // but a skipped result still counts as the replay's first message.
      firstIndex = i;
      continue;
    }
    var entry = tui
        ? replayLinesTui(
            message,
            width: width,
            dim: dim,
            results: results,
            cwd: cwd,
            home: home,
          )
        : replayLines(
            message,
            maxRows: maxRowsPerMessage,
            results: results,
            cwd: cwd,
            home: home,
          );
    if (entry.isNotEmpty &&
        entries.isNotEmpty &&
        rows + entry.length > rowBudget) {
      break;
    }
    if (entry.isEmpty) {
      firstIndex = i;
      continue;
    }
    // A single marathon message must not stall the boot replay: clip its
    // head with an explicit marker (the tail stays intact — messages at
    // the END are kept whole as long as the row budget lasts).
    const perMessageCap = 48;
    if (entry.length > perMessageCap) {
      entry = [
        ...entry.take(perMessageCap - 1),
        dim('… (replay clipped: ${entry.length - perMessageCap + 1} more rows)'),
      ];
    }
    entries.insert(0, entry);
    rows += entry.length;
    firstIndex = i;
  }
  // The kept region may begin INSIDE a fenced code block whose opener was
  // dropped with the over-budget head: the view formats the history as one
  // markdown stream, so the region's first (originally closing) fence would
  // toggle state ON and swallow everything after it. Open a synthetic fence
  // to keep the kept region's fence lines balanced.
  if (firstIndex > 0 &&
      entries.isNotEmpty &&
      _fenceOpenBefore(messages, firstIndex)) {
    entries.insert(0, const ['```']);
  }
  return (entries, firstIndex);
}

/// Whether the text of messages BEFORE [firstIndex] leaves a code fence
/// open (mirrors what the replay emits: user text and assistant text; tool
/// results never render). Every fence line toggles the state, so the count
/// of fence lines decides — one regex pass, no per-line list allocations
/// (a 30k-record resume must not materialize the whole transcript here).
bool _fenceOpenBefore(List<Message> messages, int firstIndex) {
  var fences = 0;
  for (var i = 0; i < firstIndex; i++) {
    final message = messages[i];
    final String? text = switch (message) {
      UserMessage(:final content) => _blocksText(content),
      AssistantMessage(:final content) =>
        content.whereType<TextContent>().map((b) => b.text).join('\n'),
      _ => null,
    };
    if (text == null) continue;
    fences += _fenceLineRe.allMatches(text).length;
  }
  return fences.isOdd;
}
