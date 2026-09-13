/// The `compact_expand` tool (issue #148 D3, agent UX #266): pulls a
/// hidden or compacted context segment back into the conversation by its
/// numeric marker id — and, with no `target`, surfaces what is hidden at
/// all.
///
/// Context markers (`[3:hidden·tool_result·4.2k·"first line…"]`,
/// `[2-6:ckpt·38k→40tok·covers:3,5]`) are render-time projections — the
/// underlying records stay in the session file. With a `target` the tool
/// resolves the marker's numeric id (or range) through [RecordSeqIndex]
/// and returns the original content with the record wrapper stripped,
/// paged for giant segments and capped by a per-turn expand budget (Q6:
/// 32k tokens/turn); every success states the budget left. Only hidden /
/// checkpoint-covered / summary-folded records expand — a visible record
/// is told apart honestly (one message per failure class, #266 F2).
///
/// With no `target` the tool returns the hidden-segment index (id, kind,
/// size, preview, page count); a `query` filters and ranks it, scanning
/// hidden content too (F1b). Discovery never consumes the budget.
///
/// The session file never changes: expanded content enters context as a
/// normal tool result and may be re-hidden by the next pressure event.
/// The zero-tool fallback — `read $FAH_SESSION_FILE:<line>` — resolves
/// the same records raw.
library;

import '../../agent/agent.dart' show Agent;
import '../../agent/agent_loop.dart'
    show AgentEvent, MessageStartEvent, ToolExecutionResult, ToolUpdateCallback;
import '../../agent/agent_tool.dart';
import '../../approval/approval.dart' show ApprovalTier;
import '../../cancel_token.dart' show CancelToken;
import '../../context.dart';
import '../../prompts/prompts.g.dart' show compactExpandToolDescriptionPrompt;
import '../../session/session_record.dart';
import '../../session/session_tree.dart' show Session;
import '../../types.dart';
import 'engine.dart' show classicTransform;
import 'markers.dart' show hiddenMarker, idsToRanges, markerPreview;
import 'projection.dart'
    show
        RecordSeqIndex,
        buildStructuredViewState,
        hiddenIndexHeading,
        markerKindFor,
        recordPreviewSource,
        recordTokens;

// ignore_for_file: prefer_initializing_formals

/// The `compact_expand` tool name.
const compactExpandToolName = 'compact_expand';

/// Per-turn expand budget in (estimated) tokens (Q6 proposal, pinned).
const defaultExpandTurnBudgetTokens = 32 * 1024;

/// Characters per page: ~24k tokens at the chars/4 heuristic, past the
/// `read` tool's 50 KB cap so a giant segment pages instead of truncating.
const defaultExpandPageChars = 96 * 1024;

/// Index rows returned per discovery call before the agent is told to
/// narrow with `query` (# ponytail: fixed cap; raise when sessions hide
/// thousands of segments routinely).
const maxDiscoverRows = 200;

/// The production chars/4 heuristic (see `token_estimation.dart`).
int _tokensForChars(int chars) => chars ~/ 4;

/// Extracts the numeric id or range from a marker or bare target:
/// `5`, `2-6`, or a pasted `[5:hidden·tool_result·4.5k]`.
final RegExp _targetPattern = RegExp(r'(\d+)(?:-(\d+))?');

/// One honest message per failure class (issue #266 F2 / AC3) — the
/// exact strings `UT-msgs` snapshot-pins. One fact, one phrasing.

/// Out of range: `no record 1 — valid ids 2-2397`.
String expandNoRecordMsg(String label, String validIds) =>
    'no record $label — valid ids $validIds';

/// Target exists but renders in context: nothing to reopen.
String expandVisibleMsg(String label) =>
    'record $label is visible, nothing to expand';

/// Hide-state or system record with no expandable text.
String expandNoContentMsg(String label) =>
    'record $label carries no content to expand';

/// Per-turn budget spent (#266 F2: the reset is part of the fact).
String expandBudgetMsg(int budgetTokens) =>
    'expand budget exhausted for this turn '
    '(${budgetTokens ~/ 1024}k tokens) — it resets on the next user turn';

/// Remaining per-turn budget appended to every SUCCESS response (AC3):
/// `expand budget left: ~18k tokens`.
String expandBudgetLeft(int remainingTokens) => remainingTokens >= 1024
    ? 'expand budget left: ~${remainingTokens ~/ 1024}k tokens'
    : 'expand budget left: ~$remainingTokens tokens';

/// The valid-id range over a session's file order (`2-2397`): the header
/// is line 1, records are lines 2..N+1.
String expandValidIds(int entryCount) =>
    entryCount == 0 ? 'none (session is empty)' : '2-${entryCount + 1}';

/// Owns the per-turn expand budget and the [compact_expand] tool for one
/// agent. Created next to [builtinTools] (see [CheckpointRewindController]);
/// the budget resets when a new user turn starts.
final class CompactExpandController {
  /// Creates the controller and attaches the turn-reset listener to
  /// [agent]. [session] resolves the LIVE session per call — hosts switch
  /// sessions without rebuilding the tool surface.
  CompactExpandController({
    required Agent agent,
    required this.session,
    this.turnBudgetTokens = defaultExpandTurnBudgetTokens,
    this.pageChars = defaultExpandPageChars,
  }) : _agent = agent {
    _unsubscribe = _agent.subscribe(_onAgentEvent);
  }

  final Agent _agent;
  final Session? Function() session;
  final int turnBudgetTokens;
  final int pageChars;
  int _spentTokens = 0;
  void Function()? _unsubscribe;

  /// The `compact_expand` tool bound to this controller.
  late final AgentTool tool = AgentTool(
    name: compactExpandToolName,
    description: compactExpandToolDescriptionPrompt,
    tier: ApprovalTier.read,
    parameters: const {
      'type': 'object',
      'properties': {
        'target': {
          'type': 'string',
          'description':
              'Numeric id or range from a context marker, '
              'e.g. "5" or "2-6". Omit to list the hidden-segment index.',
        },
        'query': {
          'type': 'string',
          'description':
              'Search the hidden segments (preview and full content) when '
              'you know WHAT you need but not the id. Free — no budget.',
        },
        'page': {
          'type': 'integer',
          'description': '1-based page for giant segments (default 1)',
          'minimum': 1,
        },
      },
      'required': [],
    },
    execute: _execute,
  );

  /// Tokens spent on expands this turn so far.
  int get spentTokens => _spentTokens;

  /// Detaches from the agent.
  void dispose() {
    _unsubscribe?.call();
    _unsubscribe = null;
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken cancelToken) async {
    // A new user turn opens a fresh budget (Q6: per-TURN).
    if (event is MessageStartEvent && event.message is UserMessage) {
      _spentTokens = 0;
    }
  }

  Future<ToolExecutionResult> _execute(
    Map<String, dynamic> args,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
    final live = session();
    if (live == null) {
      return ToolExecutionResult.text('no active session to expand from');
    }
    final entries = await live.getEntries();
    final seqs = RecordSeqIndex(entries);
    final validIds = expandValidIds(entries.length);

    final rawTarget = args['target'];
    final range = rawTarget == null ? null : _parseTarget(rawTarget);
    if (rawTarget != null && range == null) {
      return ToolExecutionResult.text(
        'target must be a numeric id or range from a marker, '
        'e.g. "5" or "2-6" (got: $rawTarget)',
      );
    }
    if (range == null) {
      // Discovery is free (AC2): the index never consumes the budget.
      return ToolExecutionResult.text(
        await _discover(live, seqs, validIds, query: args['query'] as String?),
      );
    }
    final (start, end) = range;
    if (end < start) {
      return ToolExecutionResult.text(
        'inverted range $start-$end — use "min-max"',
      );
    }

    // Which records still render in context? Everything else — hidden,
    // checkpoint-covered, folded away by a classic summary, off-branch —
    // expands (#266 F2: a visible record is not expandable).
    final path = classicTransform(await live.getBranch());
    final state = buildStructuredViewState(path);
    final pathIds = {for (final record in path) record.id};
    bool expandable(SessionRecord record) =>
        !pathIds.contains(record.id) ||
        state.hiddenRecordIds.contains(record.id) ||
        state.isCovered(record.id);

    final (blocks, skipped, blocked, label) = _gatherBlocks(
      seqs,
      start,
      end,
      expandable,
    );
    if (blocks.isEmpty) {
      if (skipped.isNotEmpty) {
        return ToolExecutionResult.text(expandNoRecordMsg(label, validIds));
      }
      if (blocked.isNotEmpty) {
        return ToolExecutionResult.text(expandVisibleMsg(label));
      }
      return ToolExecutionResult.text(expandNoContentMsg(label));
    }

    final content = blocks.join('\n\n');
    final pages = (content.length / pageChars).ceil();
    final page = (args['page'] as num?)?.toInt() ?? 1;
    if (page < 1 || page > pages) {
      return ToolExecutionResult.text(
        'page $page out of range (1-$pages) for target $label',
      );
    }
    final slice = _pageSlice(content, page, pages, pageChars);
    // Budget charges the DELIVERED page, not the whole segment: paging a
    // 20 MB record through the turn must stay possible — the sum over all
    // pages converges to the segment cost (S6).
    final cost = _tokensForChars(slice.length + 1);
    if (_spentTokens + cost > turnBudgetTokens) {
      return ToolExecutionResult.text(expandBudgetMsg(turnBudgetTokens));
    }
    _spentTokens += cost;

    final header = StringBuffer('[expand $label');
    if (skipped.isNotEmpty) {
      header.write(' · out of range: ${idsToRanges(skipped)}');
    }
    if (blocked.isNotEmpty) {
      header.write(' · visible: ${idsToRanges(blocked)}');
    }
    header.write(' · ${expandBudgetLeft(turnBudgetTokens - _spentTokens)}]');
    final footer = pages > 1
        ? page < pages
              ? '\n\n[page $page/$pages — continue with compact_expand '
                    '{"target": "$label", "page": ${page + 1}}]'
              : '\n\n[end of record $label]'
        : '';
    return ToolExecutionResult.text('$header\n$slice$footer');
  }

  /// The hidden-segment index (no `target`), optionally filtered and
  /// ranked by [query] (F1b): preview/kind hits rank above content hits.
  Future<String> _discover(
    Session live,
    RecordSeqIndex seqs,
    String validIds, {
    String? query,
  }) async {
    final path = classicTransform(await live.getBranch());
    final state = buildStructuredViewState(path);
    final pathIds = {for (final record in path) record.id};

    // (rank, seq, line): seq is the tiebreak so equal ranks stay in file
    // order regardless of sort stability.
    final rows = <(int, int, String)>[];
    for (var seq = 2; seq <= seqs.entries.length + 1; seq++) {
      final record = seqs.recordAt(seq)!;
      if (pathIds.contains(record.id) &&
          !state.hiddenRecordIds.contains(record.id) &&
          !state.isCovered(record.id)) {
        continue; // renders in context — nothing to discover
      }
      final content = recordPreviewSource(record);
      final block = _renderRecord(seq, record) ?? content;
      final pages = (block.length / pageChars).ceil();
      final preview = markerPreview(content);
      final needle = query?.toLowerCase();
      var rank = 1;
      if (needle != null) {
        rank = 0;
        if (preview.toLowerCase().contains(needle) ||
            markerKindFor(record).contains(needle)) {
          rank = 2;
        } else if (content.toLowerCase().contains(needle)) {
          rank = 1;
        }
      }
      if (rank == 0) continue;
      var marker = hiddenMarker(
        seq: seq,
        kind: markerKindFor(record),
        tokens: recordTokens(record),
        preview: preview,
      );
      if (pages > 1) {
        marker = '${marker.substring(0, marker.length - 1)}·pages:$pages]';
      }
      rows.add((rank, seq, marker));
    }
    rows.sort((a, b) => a.$1 != b.$1 ? b.$1 - a.$1 : a.$2 - b.$2);

    if (query == null) {
      if (rows.isEmpty) {
        return 'no hidden segments — everything in this session is visible '
            'in context';
      }
      final lines = [for (final row in rows.take(maxDiscoverRows)) row.$3];
      if (rows.length > maxDiscoverRows) {
        lines.add(
          '…and ${rows.length - maxDiscoverRows} more — '
          'narrow with query',
        );
      }
      return '$hiddenIndexHeading\n${lines.join('\n')}';
    }
    if (rows.isEmpty) {
      return 'no hidden segments match "$query" — valid ids $validIds '
          '(drop query for the full index)';
    }
    final lines = [for (final row in rows.take(maxDiscoverRows)) row.$3];
    if (rows.length > maxDiscoverRows) {
      lines.add('…and ${rows.length - maxDiscoverRows} more — narrow query');
    }
    return '${rows.length} hidden segments match "$query" (best first):\n'
        '${lines.join('\n')}';
  }
}

/// Parses the target arg (`5`, `2-6`, or a pasted marker) into its
/// inclusive id range; null when no numeric target is present.
(int, int)? _parseTarget(Object? raw) {
  final match = _targetPattern.firstMatch('$raw');
  if (match == null) return null;
  final start = int.parse(match.group(1)!);
  final end = match.group(2) == null ? start : int.parse(match.group(2)!);
  return (start, end);
}

/// Renders every expandable record in `start..end`; ids with no record
/// land in `skipped`, visible ids in `blocked` — each feeds its honest
/// failure class or success note.
(List<String>, List<int>, List<int>, String) _gatherBlocks(
  RecordSeqIndex seqs,
  int start,
  int end,
  bool Function(SessionRecord) expandable,
) {
  final blocks = <String>[];
  final skipped = <int>[];
  final blocked = <int>[];
  for (var seq = start; seq <= end; seq++) {
    final record = seqs.recordAt(seq);
    if (record == null) {
      skipped.add(seq);
      continue;
    }
    if (record is HiddenRangeRecord) {
      continue; // pure hide state — the ids it names expand directly
    }
    if (!expandable(record)) {
      blocked.add(seq);
      continue;
    }
    final block = _renderRecord(seq, record);
    if (block != null) blocks.add(block);
  }
  return (blocks, skipped, blocked, _rangeLabel(start, end));
}

/// `'5'` or `'2-6'` — the range label used in every expand string.
String _rangeLabel(int start, int end) =>
    start == end ? '$start' : '$start-$end';

/// The 1-based [page] slice of a paged segment (the whole content when
/// it fits one page).
String _pageSlice(String content, int page, int pages, int pageChars) =>
    pages == 1
    ? content
    : content.substring(
        (page - 1) * pageChars,
        page == pages ? content.length : page * pageChars,
      );

/// Renders one record's clean content (the record wrapper stripped), or
/// null for pure state records ([HiddenRangeRecord]) that carry none.
String? _renderRecord(int seq, SessionRecord record) {
  switch (record) {
    case MessageRecord(:final message):
      return switch (message) {
        UserMessage() => '[$seq user]\n${_userText(message.content)}',
        AssistantMessage() => '[$seq assistant]\n${_assistantText(message)}',
        ToolResultMessage(:final toolName, :final content) =>
          '[$seq tool_result · $toolName]\n${_blockTexts(content)}',
        _ => '[$seq ${message.role}]',
      };
    case CustomMessageRecord(:final content):
      return '[$seq context]\n${_userText(content)}';
    case CompactCheckpointRecord(:final text, :final coversRecordIds):
      return '[$seq ckpt · covers ${coversRecordIds.length} ids]\n$text';
    case CompactionRecord(:final summary):
      return '[$seq legacy-ckpt · classic · not-expandable]\n$summary';
    case BranchSummaryRecord(:final summary):
      return summary.isEmpty ? null : '[$seq branch-summary]\n$summary';
    case HiddenRangeRecord():
      return null; // Pure hide state — the records it names expand directly.
    default:
      return '[$seq ${record.runtimeType}]\n(system record — no content)';
  }
}

String _userText(Object content) =>
    content is String ? content : _blockTexts(content as List<ContentBlock>);

String _assistantText(AssistantMessage message) {
  final parts = <String>[];
  for (final block in message.content) {
    switch (block) {
      case TextContent(:final text):
        parts.add(text);
      case ThinkingContent(:final thinking):
        parts.add('<thinking>\n$thinking\n</thinking>');
      case ToolCall(:final name, :final arguments):
        parts.add('tool_call $name(${_shortArgs(arguments)})');
      case ImageContent():
        parts.add('[image]');
    }
  }
  return parts.join('\n');
}

String _blockTexts(List<ContentBlock> blocks) => [
  for (final block in blocks)
    switch (block) {
      TextContent(:final text) => text,
      ImageContent() => '[image]',
      _ => '[${block.runtimeType}]',
    },
].join('\n');

String _shortArgs(Map<String, dynamic> arguments) {
  const cap = 200;
  final text = arguments.toString();
  return text.length <= cap ? text : '${text.substring(0, cap)}…';
}
