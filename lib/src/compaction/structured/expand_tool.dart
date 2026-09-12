/// The `compact_expand` tool (issue #148 D3): pulls a hidden or compacted
/// context segment back into the conversation by its numeric marker id.
///
/// Context markers (`[3:hidden·tool_result·4.2k]`,
/// `[2-6:ckpt·38k→40tok·covers:3,5]`) are render-time projections — the
/// underlying records stay in the session file. This tool resolves the
/// marker's numeric id (or range) through [RecordSeqIndex] and returns the
/// original content with the record wrapper stripped, paged for giant
/// segments and capped by a per-turn expand budget (Q6: 32k tokens/turn) —
/// an expand storm returns a structured note, never a crash.
///
/// The session file never changes: expanded content enters context as a
/// normal tool result and may be re-hidden by the next pressure event.
/// The zero-tool fallback — `read $FAH_SESSION_FILE:<line>` — resolves the
/// same records raw.
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
import 'markers.dart' show idsToRanges;
import 'projection.dart' show RecordSeqIndex;

// ignore_for_file: prefer_initializing_formals

/// The `compact_expand` tool name.
const compactExpandToolName = 'compact_expand';

/// Per-turn expand budget in (estimated) tokens (Q6 proposal, pinned).
const defaultExpandTurnBudgetTokens = 32 * 1024;

/// Characters per page: ~24k tokens at the chars/4 heuristic, past the
/// `read` tool's 50 KB cap so a giant segment pages instead of truncating.
const defaultExpandPageChars = 96 * 1024;

/// The production chars/4 heuristic (see `token_estimation.dart`).
int _tokensForChars(int chars) => chars ~/ 4;

/// Extracts the numeric id or range from a marker or bare target:
/// `5`, `2-6`, or a pasted `[5:hidden·tool_result·4.5k]`.
final RegExp _targetPattern = RegExp(r'(\d+)(?:-(\d+))?');

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
              'e.g. "5" or "2-6"',
        },
        'page': {
          'type': 'integer',
          'description': '1-based page for giant segments (default 1)',
          'minimum': 1,
        },
      },
      'required': ['target'],
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
    final match = _targetPattern.firstMatch('${args['target'] ?? ''}');
    if (match == null) {
      return ToolExecutionResult.text(
        'target must be a numeric id or range from a marker, '
        'e.g. "5" or "2-6" (got: ${args['target']})',
      );
    }
    final start = int.parse(match.group(1)!);
    final end = match.group(2) == null ? start : int.parse(match.group(2)!);
    if (end < start) {
      return ToolExecutionResult.text(
        'inverted range $start-$end — use "min-max"',
      );
    }

    final seqs = RecordSeqIndex(await live.getEntries());
    final blocks = <String>[];
    final skipped = <int>[];
    for (var seq = start; seq <= end; seq++) {
      final record = seqs.recordAt(seq);
      if (record == null) {
        skipped.add(seq);
        continue;
      }
      final block = _renderRecord(seq, record);
      if (block != null) blocks.add(block);
    }
    if (blocks.isEmpty) {
      return ToolExecutionResult.text(
        'no expandable records at ${start == end ? '$start' : '$start-$end'} '
        '(valid ids: 2-${seqs.entries.length + 1})'
        '${skipped.isEmpty ? '' : '; out of range: ${idsToRanges(skipped)}'}',
      );
    }

    var content = blocks.join('\n\n');
    final pages = (content.length / pageChars).ceil();
    final page = (args['page'] as num?)?.toInt() ?? 1;
    if (page < 1 || page > pages) {
      return ToolExecutionResult.text(
        'page $page out of range (1-$pages) for target '
        '${start == end ? '$start' : '$start-$end'}',
      );
    }
    final slice = pages == 1
        ? content
        : content.substring(
            (page - 1) * pageChars,
            page == pages ? content.length : page * pageChars,
          );
    // Budget counts the REQUESTED segment (not just this page's slice):
    // re-paging a giant segment must not multiply the budget.
    final cost = _tokensForChars(content.length);
    if (_spentTokens + cost > turnBudgetTokens) {
      return ToolExecutionResult.text(
        '($_spentTokens/$turnBudgetTokens tokens spent; this segment '
        'would add ~$cost). Expand selectively; smaller targets fit.',
      );
    }
    _spentTokens += cost;

    final header = StringBuffer(
      '[expand ${start == end ? '$start' : '$start-$end'}',
    );
    if (skipped.isNotEmpty) {
      header.write(' · out of range: ${idsToRanges(skipped)}');
    }
    header.write(']');
    final footer = pages > 1
        ? '\n\n[page $page/$pages — compact_expand target='
              '${start == end ? '$start' : '$start-$end'}, page: ${page + 1} '
              'continues]'
        : '';
    return ToolExecutionResult.text('$header\n$slice$footer');
  }
}

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
