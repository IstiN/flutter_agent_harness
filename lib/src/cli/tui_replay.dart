import '../context.dart';
import '../session/session_tree.dart'
    show branchSummaryPrefix, compactionSummaryPrefix;
import '../types.dart';

/// A code-fence opener/closer line (```). Tracked by the replay so a
/// truncated message never leaves a dangling fence: the view formats the
/// whole history as ONE markdown stream, and an unclosed fence would render
/// everything after it as verbatim code (raw `**`, tables, links).
final _fenceLineRe = RegExp(r'^\s*```');

/// Appends a synthetic closing fence when [rows] (a truncated assistant
/// message) ends inside a fenced code block.
void _closeDanglingFence(List<String> rows) {
  var open = false;
  for (final row in rows) {
    if (_fenceLineRe.hasMatch(row)) open = !open;
  }
  if (open) rows.add('```');
}

/// A transcript message projected from a compaction/branch summary starts
/// with one of the known prefixes and carries the whole `<summary>` block —
/// replaying it verbatim dumps a wall of XML-ish tags and file lists into
/// the history. The replay instead shows one compact marker row with the
/// summary's first line as a hint. Returns null for non-summary messages;
/// a summary without a plain-text line yields an empty hint.
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

/// A user message that is PURELY a `<system-notice>` (background-shell job
/// settles, inter-agent mail, task results): steering context for the
/// model, not reading material — replaying it verbatim dumps the full
/// command text, log paths and the closing tag into the restored
/// transcript. The replay instead shows one compact row with the notice's
/// first informative line (Command:/Log:/meta lines dropped). Returns null
/// for anything else — mixed content replays verbatim.
(String label, String firstLine)? _systemNoticeMarker(String text) {
  final match = RegExp(
    r'^\s*<system-notice>\n?([\s\S]*?)\n?</system-notice>\s*$',
  ).firstMatch(text);
  if (match == null) return null;
  for (final line in (match.group(1) ?? '').split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('<') ||
        trimmed.startsWith('Command:') ||
        trimmed.startsWith('Log:') ||
        trimmed.startsWith('Check the result')) {
      continue;
    }
    return ('⚙ $trimmed', '');
  }
  return ('⚙ system notice', '');
}

/// TUI-mode replay entry in the ACTIVE session's format: the user message
/// as the same background echo box the TUI draws at submit time, the
/// assistant text as raw markdown ([AnsiMarkdown] styles it at render
/// time, exactly like a live stream), and the tool calls of a
/// text-bearing message as one dim indicator row. Call-only assistant
/// messages collapse through the pending-runs machinery instead.
List<String> replayLinesTui(
  Message message, {
  required int width,
  required String Function(String) dim,
}) {
  switch (message) {
    case UserMessage(:final content):
      final text = content is String
          ? content
          : (content as List<ContentBlock>)
                .whereType<TextContent>()
                .map((b) => b.text)
                .join('\n');
      if (text.trim().isEmpty) return const [];
      final notice = _systemNoticeMarker(text);
      if (notice != null) {
        // The notice fits the terminal width — a wrapped chrome row desyncs
        // the renderer (same rule as the summary marker below).
        final marker = notice.$1;
        final line = marker.length > width
            ? '${marker.substring(0, width - 1)}…'
            : marker;
        return [dim('─' * width), dim(line), ''];
      }
      final summary = _summaryMarker(text);
      if (summary != null) {
        // A projected compaction/branch summary renders compact: the raw
        // block is model context, not reading material. The marker fits the
        // terminal width — a wrapped chrome row desyncs the renderer.
        final (label, firstLine) = summary;
        final hint = firstLine.isEmpty ? '' : ' — $firstLine';
        final marker = '$label$hint';
        final line = marker.length > width
            ? '${marker.substring(0, width - 1)}…'
            : marker;
        return [dim('─' * width), dim(line), ''];
      }
      const bg = '\x1b[48;2;30;34;42m';
      const reset = '\x1b[0m';
      return [
        dim('─' * width),
        for (final line in text.split('\n')) '$bg$line$reset',
        '',
      ];
    case AssistantMessage(:final content):
      final texts = content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n')
          .trim();
      if (texts.isEmpty) return const [];
      // Full replay: a restored answer reads like a live one — heads
      // truncated to a fixed row count hid the actual reply behind a `…`
      // (user-visible regression report). The global row budget still bounds
      // WHICH messages replay; a budget cut between messages keeps whole
      // messages intact instead of decapitating every single one.
      final rows = texts.split('\n');
      final calls = content
          .whereType<ToolCall>()
          .map((c) => '[${c.name}]')
          .join(' ');
      return [...rows, if (calls.isNotEmpty) dim(calls)];
    default:
      return const [];
  }
}

/// One line-mode replay entry. `maxRows <= 0` (the default through
/// [buildReplayEntries]) replays the message IN FULL — per-message head
/// caps hid restored answers behind a `…`; the global row budget bounds
/// which messages replay instead, keeping every included one whole.
/// Or none for messages the replay skips (tool results — their calls are
/// already shown).
List<String> replayLines(Message message, {required int maxRows}) {
  if (message case UserMessage(:final content)) {
    final text = _userReplayText(content);
    final notice = _systemNoticeMarker(text);
    if (notice != null) return [notice.$1];
    final summary = _summaryMarker(text);
    if (summary != null) {
      final (label, firstLine) = summary;
      final hint = firstLine.isEmpty ? '' : ' — $firstLine';
      return ['$label$hint'];
    }
  }
  final (prefix, text) = switch (message) {
    UserMessage(:final content) => ('you: ', _userReplayText(content)),
    AssistantMessage(:final content) => (
      'fa:  ',
      _assistantReplayText(content),
    ),
    _ => ('', ''),
  };
  if (text.trim().isEmpty) return const [];
  final rows = text.split('\n');
  final head = maxRows > 0 ? rows.take(maxRows).toList() : rows;
  final suffix = maxRows > 0 && rows.length > maxRows ? ' …' : '';
  if (suffix.isNotEmpty) _closeDanglingFence(head);
  final indent = ' ' * prefix.length;
  return [
    for (var i = 0; i < head.length; i++)
      '${i == 0 ? prefix : indent}${head[i]}${i == head.length - 1 ? suffix : ''}',
  ];
}

/// The user message's replay text: the raw string, or its text blocks
/// joined.
String _userReplayText(Object content) {
  return content is String
      ? content
      : (content as List<ContentBlock>)
            .whereType<TextContent>()
            .map((b) => b.text)
            .join(' ');
}

/// The assistant message's replay text: text blocks plus `[tool]` markers.
String _assistantReplayText(List<ContentBlock> content) {
  final texts = content
      .whereType<TextContent>()
      .map((b) => b.text)
      .join(' ')
      .trim();
  final calls = content
      .whereType<ToolCall>()
      .map((c) => '[${c.name}]')
      .join(' ');
  return [texts, calls].where((s) => s.isNotEmpty).join(' ');
}

/// Whether a message is an assistant turn carrying ONLY tool calls (no
/// text) — the replay collapses runs of these into one row.
bool isToolCallOnlyAssistant(Message message) {
  if (message is! AssistantMessage) return false;
  final hasText = message.content.whereType<TextContent>().any(
    (b) => b.text.trim().isNotEmpty,
  );
  if (hasText) return false;
  return message.content.whereType<ToolCall>().isNotEmpty;
}

/// Builds the replay entries for a restored session's transcript: whole
/// per-message entries (user/assistant in FULL — no per-message head caps;
/// [maxRowsPerMessage] <= 0 means unlimited) filling [rowBudget] from the
/// END. A typical session replays verbatim; a marathon one drops OLDER
/// WHOLE messages rather than decapitating the tail's content.
/// Consecutive tool-call-only assistant messages still collapse into a
/// single `[name] [name]` row: they dominated the tail with zero recap
/// value. Returns the entries (oldest first) and the index of the first
/// replayed message (for the "last N of M" header).
(List<List<String>> entries, int firstIndex) buildReplayEntries(
  List<Message> messages, {
  required bool tui,
  required int width,
  required String Function(String) dim,
  int rowBudget = 1900,
  int maxRowsPerMessage = 0,
  int maxCollapsedCalls = 12,
}) {
  final collector = _ReplayCollector(
    messages.length,
    tui: tui,
    dim: dim,
    maxCollapsedCalls: maxCollapsedCalls,
  );
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message is ToolResultMessage) {
      // Tool results never render in the replay, and they must NOT break
      // a collapsing run of tool-call-only assistant messages (a run is
      // assistant(calls), result, assistant(calls), result, ...).
      collector.markFirst(i);
      continue;
    }
    if (isToolCallOnlyAssistant(message)) {
      collector.addCalls((message as AssistantMessage).content, i);
      continue;
    }
    final entry = tui
        ? replayLinesTui(message, width: width, dim: dim)
        : replayLines(message, maxRows: maxRowsPerMessage);
    if (collector.overBudget(entry.length, rowBudget)) break;
    collector.flushInto();
    if (entry.isEmpty) continue;
    collector.addEntry(entry, i);
  }
  collector.flushInto();
  // The kept region may begin INSIDE a fenced code block whose opener was
  // dropped with the over-budget head: the view formats the history as one
  // markdown stream, so the region's first (originally closing) fence would
  // toggle state ON and swallow everything after it. Open a synthetic fence
  // to keep the kept region's fence lines balanced.
  if (collector.firstIndex > 0 &&
      collector.entries.isNotEmpty &&
      _fenceOpenBefore(messages, collector.firstIndex)) {
    collector.entries.insert(0, const ['```']);
  }
  return (collector.entries, collector.firstIndex);
}

/// Whether the text of messages BEFORE [firstIndex] leaves a code fence
/// open (mirrors what the replay emits: user text and assistant text; tool
/// results never render).
bool _fenceOpenBefore(List<Message> messages, int firstIndex) {
  var open = false;
  for (var i = 0; i < firstIndex; i++) {
    final message = messages[i];
    final String text;
    switch (message) {
      case UserMessage(:final content):
        text = _userReplayText(content);
      case AssistantMessage(:final content):
        text = content.whereType<TextContent>().map((b) => b.text).join('\n');
      default:
        continue;
    }
    for (final line in text.split('\n')) {
      if (_fenceLineRe.hasMatch(line)) open = !open;
    }
  }
  return open;
}

/// Row accumulator for [buildReplayEntries]: the entry list with its row
/// budget accounting, the collapse run of tool-call-only messages, and the
/// first-replayed-index tracking.
final class _ReplayCollector {
  _ReplayCollector(
    this.firstIndex, {
    required this.tui,
    required this.dim,
    required this.maxCollapsedCalls,
  }) : _pendingFirstIndex = firstIndex;

  /// TUI rows dim like the live tool indicators; line mode uses the compact
  /// fa:-prefixed row.
  final bool tui;

  /// The dim style for TUI indicator rows.
  final String Function(String) dim;

  /// Cap on collapsed tool names before a `…` marker.
  final int maxCollapsedCalls;

  /// The replay rows (oldest first), one entry per message or collapse run.
  final entries = <List<String>>[];

  /// Index of the first replayed message.
  int firstIndex;

  int _pendingFirstIndex;
  final _pendingCalls = <String>[];
  var rows = 0;

  /// Marks [i] as the first replayed index (skipped messages still count).
  void markFirst(int i) => firstIndex = i;

  /// Prepends a tool-call-only message's `[name]` markers to the collapse
  /// run (the loop walks messages newest-first).
  void addCalls(List<ContentBlock> content, int i) {
    _pendingCalls.insertAll(0, [
      for (final c in content.whereType<ToolCall>()) '[${c.name}]',
    ]);
    _pendingFirstIndex = i;
  }

  /// Whether an entry of [entryLength] rows would exceed [rowBudget] (the
  /// first entry always fits).
  bool overBudget(int entryLength, int rowBudget) =>
      entryLength > 0 && entries.isNotEmpty && rows + entryLength > rowBudget;

  /// Prepends a rendered message entry.
  void addEntry(List<String> entry, int i) {
    entries.insert(0, entry);
    rows += entry.length;
    firstIndex = i;
  }

  /// Flushes the collapse run as one indicator row (TUI: dimmed like the
  /// live indicators; line mode: the compact fa:-prefixed row).
  void flushInto() {
    if (_pendingCalls.isEmpty) return;
    final names = _pendingCalls.length > maxCollapsedCalls
        ? [..._pendingCalls.sublist(0, maxCollapsedCalls), '…']
        : List.of(_pendingCalls);
    _pendingCalls.clear();
    firstIndex = _pendingFirstIndex;
    final joined = names.join(' ');
    entries.insert(0, [tui ? dim(joined) : 'fa:  $joined']);
    rows++;
  }
}
