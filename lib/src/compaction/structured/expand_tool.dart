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
import 'engine.dart' show classicTransform, refreshAgentState;
import '../compaction.dart' show isSyntheticUserText;
import 'judge.dart' show hideProtectTailEntries;
import 'ledger.dart';
import 'markers.dart'
    show formatMarkerTokens, hiddenMarker, idsToRanges, markerPreview;
import 'projection.dart'
    show
        RecordSeqIndex,
        buildStructuredViewState,
        hiddenIndexHeading,
        markerKindFor,
        recordPreviewSource,
        recordTokens,
        visibleStructuredPath;

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
        'action': {
          'type': 'string',
          'description':
              'Tier 2 segment management (issue #1379). With a target: '
              '"hide" folds a dead-weight segment into its expandable '
              'marker right now, without waiting for pressure; "pin" '
              'shields a segment from every hide/compact path; "unpin" '
              'releases it. Omit to expand the target.',
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

    final action = (args['action'] as String?)?.trim();
    if (action != null && action.isNotEmpty) {
      return _segmentAction(live, seqs, validIds, action, args['target']);
    }

    final (range, parseError) = _parseRangeArg(args['target']);
    if (parseError != null) return ToolExecutionResult.text(parseError);
    if (range == null) {
      // Discovery is free (AC2): the index never consumes the budget.
      return ToolExecutionResult.text(
        await _discover(live, seqs, validIds, query: args['query'] as String?),
      );
    }

    final (expandable, _) = await _expandabilityOf(live);
    final (blocks, skipped, blocked, label) = _gatherBlocks(
      seqs,
      range.$1,
      range.$2,
      (record) => expandable(record.id),
    );
    if (blocks.isEmpty) {
      return ToolExecutionResult.text(
        _emptyReason(skipped, blocked, label, validIds),
      );
    }
    return _paged(args, blocks, skipped, blocked, label);
  }

  /// Tier 2 (issue #1379): agent-initiated hide / pin / unpin over the
  /// same validated surface the judge hides through — ids exist, pairs
  /// snap whole, pins and the protected tail hold — but every rejection
  /// is a structured error, never a silent narrowing (AC1).
  Future<ToolExecutionResult> _segmentAction(
    Session live,
    RecordSeqIndex seqs,
    String validIds,
    String action,
    Object? rawTarget,
  ) async {
    final unknown = _unknownActionError(action);
    if (unknown != null) return unknown;
    final (target, targetError) = _actionTarget(action, rawTarget);
    if (targetError != null) return targetError;
    final (start, end, label) = target!;
    final (targets, resolveError) = _resolveRangeTargets(
      seqs,
      start,
      end,
      label,
      validIds,
    );
    if (resolveError != null) return resolveError;
    // Real user turns are exempt from every path (F8) — say so instead
    // of silently no-oping.
    final pinning = action == 'pin' || action == 'unpin';
    final userTurnError = _realUserTurnRejection(targets, label, pinning);
    if (userTurnError != null) return userTurnError;
    if (pinning) return _pinAction(live, targets, label, action == 'pin');
    return _hideAction(live, seqs, targets, label);
  }

  /// The structured rejection for an unrecognized action name (AC1) —
  /// null when [action] is one of "hide", "pin", "unpin".
  ToolExecutionResult? _unknownActionError(String action) {
    final pinning = action == 'pin' || action == 'unpin';
    if (!pinning && action != 'hide') {
      return ToolExecutionResult.text(
        'unknown action "$action" — use "hide", "pin" or "unpin"',
      );
    }
    return null;
  }

  /// The validated target of a segment action, flattened to
  /// `(start, end, label)` — or the structured rejection: an unparsable
  /// target names the parse error, a missing target asks for one (AC1).
  ((int, int, String)?, ToolExecutionResult?) _actionTarget(
    String action,
    Object? rawTarget,
  ) {
    final (range, parseError) = _parseRangeArg(rawTarget);
    if (parseError != null) {
      return (null, ToolExecutionResult.text(parseError));
    }
    if (range == null) {
      return (
        null,
        ToolExecutionResult.text(
          'action "$action" requires a target id or range',
        ),
      );
    }
    return ((range.$1, range.$2, _rangeLabel(range.$1, range.$2)), null);
  }

  /// The target records of the validated seq range in order — or the
  /// structured rejection when a seq has no record (AC1). The records
  /// companion is unused whenever the error is non-null.
  (List<SessionRecord>, ToolExecutionResult?) _resolveRangeTargets(
    RecordSeqIndex seqs,
    int start,
    int end,
    String label,
    String validIds,
  ) {
    final targets = <SessionRecord>[];
    for (var seq = start; seq <= end; seq++) {
      final record = seqs.recordAt(seq);
      if (record == null) {
        return (
          targets,
          ToolExecutionResult.text(expandNoRecordMsg(label, validIds)),
        );
      }
      targets.add(record);
    }
    return (targets, null);
  }

  /// The structured rejection when any target is a real user turn (F8:
  /// exempt from every path) — say so instead of silently no-oping.
  /// Null when none is.
  ToolExecutionResult? _realUserTurnRejection(
    List<SessionRecord> targets,
    String label,
    bool pinning,
  ) {
    for (final record in targets) {
      if (record is MessageRecord && _realUserTurn(record)) {
        return ToolExecutionResult.text(
          'records $label are real user turns — always exempt, '
          '${pinning ? 'pinning changes nothing' : 'never hidden'}',
        );
      }
    }
    return null;
  }

  /// Pin / unpin: appends a [SegmentPinRecord] (replay: last one wins).
  Future<ToolExecutionResult> _pinAction(
    Session live,
    List<SessionRecord> targets,
    String label,
    bool pinned,
  ) async {
    final viewState = buildStructuredViewState(
      classicTransform(await live.getBranch()),
    );
    final allSet = targets.every(
      (record) => viewState.pinnedRecordIds.contains(record.id) == pinned,
    );
    if (allSet) {
      return ToolExecutionResult.text(
        pinned
            ? 'records $label are already pinned'
            : 'records $label are not pinned',
      );
    }
    await live.appendSegmentPin(
      recordIds: [for (final record in targets) record.id]..sort(),
      pinned: pinned,
    );
    return ToolExecutionResult.text(
      pinned
          ? 'pinned records $label — judge, pressure, LRU re-hide and '
                'compact_expand hide can no longer touch them'
          : 'unpinned records $label — hide and compaction may process '
                'them again',
    );
  }

  /// The agent-initiated hide (AC1): the engine's validation class,
  /// structured errors, then a state refresh so the very next request of
  /// this turn renders the new markers (the host's per-message
  /// persistence keeps session and state in sync — the same contract the
  /// engine's state refresh relies on).
  Future<ToolExecutionResult> _hideAction(
    Session live,
    RecordSeqIndex seqs,
    List<SessionRecord> targets,
    String label,
  ) async {
    final path = classicTransform(await live.getBranch());
    final viewState = buildStructuredViewState(path);
    final pathIds = {for (final record in path) record.id};
    for (final record in targets) {
      if (!pathIds.contains(record.id)) {
        return ToolExecutionResult.text(
          'records $label are off the active branch — nothing to hide',
        );
      }
    }
    final visibleTargets = [
      for (final record in targets)
        if (!viewState.hiddenRecordIds.contains(record.id)) record,
    ];
    if (visibleTargets.isEmpty) {
      return ToolExecutionResult.text('records $label are already hidden');
    }
    final ledger = buildContextLedger(
      visiblePath: visibleStructuredPath(path, viewState),
      seqs: seqs,
    );
    final protectedTail = protectedTailIds(ledger, hideProtectTailEntries);
    // Whole pair groups or never (D6 / #85): the hide snaps OUTWARD, and
    // any group member in the protected tail or pinned set vetoes the
    // whole ask with one honest message.
    final ids = <String>{};
    for (final record in visibleTargets) {
      final group = ledger.groupOf(record.id);
      for (final id in group) {
        if (protectedTail.contains(id)) {
          return ToolExecutionResult.text(
            'records $label touch the protected recent tail '
            '(last $hideProtectTailEntries entries) — not hidden',
          );
        }
        if (viewState.pinnedRecordIds.contains(id)) {
          return ToolExecutionResult.text(
            'records $label are pinned — unpin first (action "unpin")',
          );
        }
      }
      ids.addAll(group);
    }
    var freedTokens = 0;
    for (final id in ids) {
      final seq = seqs.seqOf(id);
      if (seq != null) freedTokens += ledger.entryAtSeq(seq)?.tokens ?? 0;
    }
    await live.appendHiddenRange(recordIds: ids.toList()..sort());
    await refreshAgentState(live, _agent.state);
    final seqsOf = [for (final id in ids) seqs.seqOf(id) ?? 0]..sort();
    final groupLabel = _rangeLabel(seqsOf.first, seqsOf.last);
    return ToolExecutionResult.text(
      'hid records $groupLabel (~${formatMarkerTokens(freedTokens)}tok) — '
      'they render as markers now; compact_expand reopens them',
    );
  }

  /// Whether [record] is a real user turn (F8 exempt): a UserMessage
  /// whose content is not a synthetic system marker. Block-list content
  /// is never synthetic — always a real user turn.
  bool _realUserTurn(MessageRecord record) {
    final message = record.message;
    if (message is! UserMessage) return false;
    final content = message.content;
    return content is! String || !isSyntheticUserText(content);
  }

  /// Parses + validates the `target` arg: `(null, null)` = discovery mode,
  /// `(range, null)` = expand mode, `(_, error)` = honest failure.
  ((int, int)?, String?) _parseRangeArg(Object? rawTarget) {
    final range = rawTarget == null ? null : _parseTarget(rawTarget);
    if (rawTarget != null && range == null) {
      return (
        null,
        'target must be a numeric id or range from a marker, '
            'e.g. "5" or "2-6" (got: $rawTarget)',
      );
    }
    if (range == null) return (null, null);
    final (start, end) = range;
    if (end < start) {
      return (null, 'inverted range $start-$end — use "min-max"');
    }
    return (range, null);
  }

  /// The F2 predicate: hidden, checkpoint-covered, folded away by a
  /// classic summary, or off-branch → expandable (visible is not).
  /// The F2 predicate (expandable ids) plus the pinned id set — discovery
  /// marks pinned rows and hides must never target them (issue #1379
  /// tier 2).
  Future<(bool Function(String id), Set<String>)> _expandabilityOf(
    Session live,
  ) async {
    final path = classicTransform(await live.getBranch());
    final state = buildStructuredViewState(path);
    final pathIds = {for (final record in path) record.id};
    bool expandable(String id) =>
        !pathIds.contains(id) ||
        state.hiddenRecordIds.contains(id) ||
        state.isCovered(id);
    return (expandable, state.pinnedRecordIds);
  }

  /// One honest message per empty-gather failure class (AC3).
  String _emptyReason(
    List<int> skipped,
    List<int> blocked,
    String label,
    String validIds,
  ) {
    if (skipped.isNotEmpty) return expandNoRecordMsg(label, validIds);
    if (blocked.isNotEmpty) return expandVisibleMsg(label);
    return expandNoContentMsg(label);
  }

  /// Validates the page arg, charges the delivered page against the
  /// per-turn budget (S6), and renders header + slice + paging footer.
  ToolExecutionResult _paged(
    Map<String, dynamic> args,
    List<String> blocks,
    List<int> skipped,
    List<int> blocked,
    String label,
  ) {
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
    return ToolExecutionResult.text(
      '${_header(label, skipped, blocked)}\n$slice${_footer(label, page, pages)}',
    );
  }

  String _header(String label, List<int> skipped, List<int> blocked) {
    final header = StringBuffer('[expand $label');
    if (skipped.isNotEmpty) {
      header.write(' · out of range: ${idsToRanges(skipped)}');
    }
    if (blocked.isNotEmpty) {
      header.write(' · visible: ${idsToRanges(blocked)}');
    }
    header.write(' · ${expandBudgetLeft(turnBudgetTokens - _spentTokens)}]');
    return header.toString();
  }

  String _footer(String label, int page, int pages) {
    if (pages <= 1) return '';
    if (page < pages) {
      return '\n\n[page $page/$pages — continue with compact_expand '
          '{"target": "$label", "page": ${page + 1}}]';
    }
    return '\n\n[end of record $label]';
  }

  /// The hidden-segment index (no `target`), optionally filtered and
  /// ranked by [query] (F1b): preview/kind hits rank above content hits.
  Future<String> _discover(
    Session live,
    RecordSeqIndex seqs,
    String validIds, {
    String? query,
  }) async {
    final (expandable, pinnedIds) = await _expandabilityOf(live);
    final rows = <(int, int, String)>[];
    for (var seq = 2; seq <= seqs.entries.length + 1; seq++) {
      final record = seqs.recordAt(seq)!;
      if (!expandable(record.id)) continue; // renders in context
      final row = _discoverRow(
        seq,
        record,
        query,
        pinned: pinnedIds.contains(record.id),
      );
      if (row != null) rows.add(row);
    }
    // seq is the tiebreak so equal ranks stay in file order regardless
    // of sort stability.
    rows.sort((a, b) => a.$1 != b.$1 ? b.$1 - a.$1 : a.$2 - b.$2);
    return _formatIndex(rows, query, validIds);
  }

  /// `(rank, seq, marker)` for one hidden segment; null when [query]
  /// filters it out.
  (int, int, String)? _discoverRow(
    int seq,
    SessionRecord record,
    String? query, {
    required bool pinned,
  }) {
    final content = recordPreviewSource(record);
    final block = _renderRecord(seq, record) ?? content;
    final pages = (block.length / pageChars).ceil();
    final preview = markerPreview(content);
    final rank = _rank(preview, content, markerKindFor(record), query);
    if (rank == 0) return null;
    var marker = hiddenMarker(
      seq: seq,
      kind: markerKindFor(record),
      tokens: recordTokens(record),
      preview: preview,
      pinned: pinned,
    );
    if (pages > 1) {
      marker = '${marker.substring(0, marker.length - 1)}·pages:$pages]';
    }
    return (rank, seq, marker);
  }

  int _rank(String preview, String content, String kind, String? query) {
    final needle = query?.toLowerCase();
    if (needle == null) return 1;
    if (preview.toLowerCase().contains(needle) || kind.contains(needle)) {
      return 2;
    }
    if (content.toLowerCase().contains(needle)) return 1;
    return 0;
  }

  String _formatIndex(
    List<(int, int, String)> rows,
    String? query,
    String validIds,
  ) {
    if (query == null) {
      if (rows.isEmpty) {
        return 'no hidden segments — everything in this session is visible '
            'in context';
      }
      return '$hiddenIndexHeading\n${_topRows(rows)}';
    }
    if (rows.isEmpty) {
      return 'no hidden segments match "$query" — valid ids $validIds '
          '(drop query for the full index)';
    }
    return '${rows.length} hidden segments match "$query" (best first):\n'
        '${_topRows(rows, hint: 'narrow query')}';
  }

  String _topRows(
    List<(int, int, String)> rows, {
    String hint = 'narrow with query',
  }) {
    final lines = [for (final row in rows.take(maxDiscoverRows)) row.$3];
    if (rows.length > maxDiscoverRows) {
      lines.add('…and ${rows.length - maxDiscoverRows} more — $hint');
    }
    return lines.join('\n');
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
