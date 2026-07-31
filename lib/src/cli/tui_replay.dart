import '../context.dart';
import '../types.dart';

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
  const maxRows = 20;
  switch (message) {
    case UserMessage(:final content):
      final text = content is String
          ? content
          : (content as List<ContentBlock>)
                .whereType<TextContent>()
                .map((b) => b.text)
                .join('\n');
      if (text.trim().isEmpty) return const [];
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
      final rows = texts.split('\n');
      final head = rows.take(maxRows).toList();
      if (rows.length > maxRows) head[head.length - 1] = '${head.last} …';
      final calls = content
          .whereType<ToolCall>()
          .map((c) => '[${c.name}]')
          .join(' ');
      return [...head, if (calls.isNotEmpty) dim(calls)];
    default:
      return const [];
  }
}

/// One compact line-mode replay entry (≤ [maxRows] rows), or none for
/// messages the replay skips (tool results — their calls are already
/// shown).
List<String> replayLines(Message message, {required int maxRows}) {
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
  final head = rows.take(maxRows).toList();
  final suffix = rows.length > maxRows ? ' …' : '';
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

/// Builds the replay entries for a restored session's transcript: compact
/// per-message rows (user/assistant/tool calls, each capped to a couple of
/// rows) filling [rowBudget] from the END — a typical session replays in
/// full, only marathon ones truncate. Consecutive tool-call-only assistant
/// messages collapse into a single `[name] [name]` row: they dominated the
/// tail with zero recap value. Returns the entries (oldest first) and the
/// index of the first replayed message (for the "last N of M" header).
(List<List<String>> entries, int firstIndex) buildReplayEntries(
  List<Message> messages, {
  required bool tui,
  required int width,
  required String Function(String) dim,
  int rowBudget = 190,
  int maxRowsPerMessage = 2,
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
  return (collector.entries, collector.firstIndex);
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
