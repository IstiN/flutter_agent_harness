/// The structured compaction engine (issue #148).
///
/// Two passes, in order:
///
/// 1. **Hide** (reversible): a judge model reads the context ledger and
///    picks whole segments it deems safe to hide — stale scaffold noise,
///    superseded tool results, dead ends. Hidden records become one-line
///    markers at their original position, expandable on demand. The judge
///    runs again while the window is still over pressure (bounded).
/// 2. **Checkpoint** (summary): when pressure remains, the oldest
///    hideable range is summarized into a text checkpoint whose marker
///    lists every expand id it covers. Checkpoints nest up to the depth
///    cap; beyond that the deepest level folds into the new checkpoint.
///
/// On hard failure or residual overflow the engine reports failure and
/// the host falls back to the classic prefix compactor — the classic
/// summary then renders under structured projection as an opaque
/// `legacy-ckpt` marker segment (flowchart S7).
///
/// Failure-safety contract mirrors the classic engine: a failed pass
/// appends NOTHING; `state.messages` is only rebuilt after a successful
/// append.
library;

import '../../agent/agent.dart' show AgentState;
import '../../cancel_token.dart' show CancelToken;
import '../../session/session_record.dart';
import '../../session/session_tree.dart';
import '../../types.dart';
import '../compaction.dart';
import '../token_estimation.dart';
import 'judge.dart';
import 'ledger.dart';
import 'markers.dart';
import 'projection.dart';

/// Progress surface for the structured engine.
abstract interface class StructuredCompactorHooks {
  /// The judge/summary stream tail (busy-row echo).
  void onDelta(String delta);

  /// A completed hide or checkpoint pass.
  void onPass(StructuredCompactionPass pass);
}

/// One hide or checkpoint pass outcome.
final class StructuredCompactionPass {
  const StructuredCompactionPass({
    required this.kind,
    required this.pass,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.ok,
    this.error,
    this.judgeCalls = 0,
    this.hiddenCount = 0,
  });

  /// `'hide'` or `'checkpoint'`.
  final String kind;

  /// 1-based pass number within the run.
  final int pass;

  /// Estimated tokens before the pass.
  final int tokensBefore;

  /// Estimated tokens after the pass.
  final int tokensAfter;

  /// Whether the pass appended state.
  final bool ok;

  /// The error that failed the pass, when [ok] is `false`.
  final Object? error;

  /// LLM calls this pass consumed (AC5 instrumentation).
  final int judgeCalls;

  /// Records hidden this pass (hide passes).
  final int hiddenCount;
}

/// The structured compaction engine.
final class StructuredCompactor {
  /// Creates a compactor over [session]/[state].
  StructuredCompactor({
    required this.session,
    required this.state,
    required this.window,
    required this.settings,
    required this.judge,
    required this.summarize,
    required this.checkpointPrompt,
    this.hooks,
    this.maxHidePasses = 3,
    this.maxCheckpointPasses = 4,
    this.protectLastN = 8,
    this.depthCap = 4,
    this.cancelToken,
  });

  /// The session being compacted.
  final Session session;

  /// The agent state whose `messages` get refreshed after each pass.
  final AgentState state;

  /// The conversation window in tokens.
  final int window;

  /// Compaction thresholds (reserve / keep-recent).
  final CompactionSettings settings;

  /// The hide judge (pass 1).
  final HideJudgeFn judge;

  /// The summarizer (pass 2).
  final SummarizeFn summarize;

  /// The checkpoint instruction tail (from the prompt file).
  final String checkpointPrompt;

  /// Optional progress hooks.
  final StructuredCompactorHooks? hooks;

  /// Bound on judge iterations per run.
  final int maxHidePasses;

  /// Bound on checkpoint iterations per run.
  final int maxCheckpointPasses;

  /// How many trailing ledger entries are never hidden.
  final int protectLastN;

  /// Maximum checkpoint nesting depth before flattening.
  final int depthCap;

  /// Cancellation for the LLM calls.
  final CancelToken? cancelToken;

  int _pass = 0;

  /// Runs both passes; returns whether the context ended under pressure.
  Future<bool> run({bool force = false}) async {
    if (window <= 0) return true;
    final trigger = window - settings.reserveTokens;
    if (!force && estimateContextTokens(state.messages).tokens <= trigger) {
      return true;
    }
    if (!await _runHidePasses(trigger)) return false;
    if (!await _runCheckpointPasses(trigger)) return false;
    return estimateContextTokens(state.messages).tokens <= trigger;
  }

  Future<bool> _runHidePasses(int trigger) async {
    for (var i = 0; i < maxHidePasses; i++) {
      final before = estimateContextTokens(state.messages).tokens;
      if (before <= trigger) return true;
      final view = await _buildView();
      if (view == null) return true;
      if (_hideableEntries(view.ledger).isEmpty) break;

      final answer = await judge(view.ledger.render());
      // F1: a failed or empty judge answer is a NO-OP — never an empty
      // hide list, never hide-everything.
      if (answer == null) break;
      final picks = parseHidePicks(answer);
      if (picks == null || picks.isEmpty) break;
      final ids = validateHidePicks(
        picks,
        view.ledger,
        protectLastN: protectLastN,
      );
      if (ids.isEmpty) break;

      await session.appendHiddenRange(recordIds: ids.toList()..sort());
      final after = await _refreshState();
      hooks?.onPass(
        StructuredCompactionPass(
          kind: 'hide',
          pass: ++_pass,
          tokensBefore: before,
          tokensAfter: after,
          ok: true,
          judgeCalls: 1,
          hiddenCount: ids.length,
        ),
      );
    }
    return true;
  }

  Future<bool> _runCheckpointPasses(int trigger) async {
    for (var i = 0; i < maxCheckpointPasses; i++) {
      final before = estimateContextTokens(state.messages).tokens;
      if (before <= trigger) return true;
      final range = await _pickCheckpointRange();
      if (range == null) break;

      final flattened = _flattenForDepthCap(range);
      final text = await _summarizeRange(range, flattened);
      // Summary failure appends nothing (failure-safe).
      if (text == null) return false;

      await session.appendCompactCheckpoint(
        firstRecordId: range.firstRecordId,
        lastRecordId: range.lastRecordId,
        text: text,
        coversRecordIds: range.coveredRecordIds,
        flattenedRecordIds: [for (final ckpt in flattened) ckpt.id],
      );
      final after = await _refreshState();
      hooks?.onPass(
        StructuredCompactionPass(
          kind: 'checkpoint',
          pass: ++_pass,
          tokensBefore: before,
          tokensAfter: after,
          ok: true,
          judgeCalls: 1,
        ),
      );
    }
    return true;
  }

  List<LedgerEntry> _hideableEntries(ContextLedger ledger) {
    final tailStart = ledger.entries.length - protectLastN < 0
        ? 0
        : ledger.entries.length - protectLastN;
    return [
      for (var i = 0; i < tailStart; i++)
        if (!ledger.entries[i].exempt) ledger.entries[i],
    ];
  }

  Future<_LedgerView?> _buildView() async {
    final path = classicTransform(await session.getBranch());
    final viewState = buildStructuredViewState(path);
    final visible = _visiblePath(path, viewState);
    if (visible.isEmpty) return null;
    final seqs = RecordSeqIndex(await session.getEntries());
    return _LedgerView(
      buildContextLedger(visiblePath: visible, seqs: seqs),
      viewState,
      visible,
      seqs,
    );
  }

  List<SessionRecord> _visiblePath(
    List<SessionRecord> transformed,
    StructuredViewState viewState,
  ) => [
    for (final record in transformed)
      if (!viewState.isCovered(record.id) &&
          record is! HiddenRangeRecord &&
          !viewState.hiddenRecordIds.contains(record.id) &&
          _projects(record))
        record,
  ];

  bool _projects(SessionRecord record) =>
      record is MessageRecord ||
      record is CustomMessageRecord ||
      record is CompactionRecord ||
      record is BranchSummaryRecord ||
      record is CompactCheckpointRecord;

  /// Rebuilds `state.messages` from the session projection, zeroing usage
  /// anchors on rebuilt transcripts (the classic engine's convention —
  /// rebuilt messages carry no trustworthy usage).
  Future<int> _refreshState() async {
    final rebuilt = await session.buildContextMessages();
    state.messages = [
      for (final message in rebuilt)
        message is AssistantMessage
            ? message.copyWith(usage: Usage.zero)
            : message,
    ];
    return estimateContextTokens(state.messages).tokens;
  }

  /// Picks the next checkpoint range: the oldest visible records up to
  /// the keep-recent boundary, snapped outward to pair groups.
  Future<_CkptRange?> _pickCheckpointRange() async {
    final view = await _buildView();
    if (view == null) return null;
    final entries = view.ledger.entries;
    if (entries.isEmpty) return null;

    // The protected tail: newest records totalling the keep-recent budget
    // never enter a range.
    var tailBudget = settings.keepRecentTokens;
    var cut = entries.length;
    for (var i = entries.length - 1; i >= 0; i--) {
      tailBudget -= entries[i].tokens;
      if (tailBudget <= 0) {
        cut = i;
        break;
      }
    }
    // Snap inward at group boundaries: a range never splits a pair.
    while (cut > 1 && _sharesGroup(entries, cut, view.ledger)) {
      cut--;
    }
    if (cut <= 0) return null;
    final members = entries.take(cut).toList();
    if (members.isEmpty) return null;

    final coveredIds = <String>{};
    for (final member in members) {
      coveredIds.add(member.recordId);
      coveredIds.addAll(view.ledger.groupOf(member.recordId));
    }
    return _CkptRange(
      firstRecordId: members.first.recordId,
      lastRecordId: members.last.recordId,
      coveredRecordIds: coveredIds.toList()..sort(),
      state: view.state,
      visible: view.visible,
      seqs: view.seqs,
    );
  }

  bool _sharesGroup(List<LedgerEntry> entries, int cut, ContextLedger ledger) {
    if (cut >= entries.length) return false;
    return ledger
        .groupOf(entries[cut - 1].recordId)
        .contains(entries[cut].recordId);
  }

  /// Depth-cap flattening (D5): when the new checkpoint would nest deeper
  /// than [depthCap], the covered checkpoints already at the cap fold
  /// their text into the new prompt; their ids persist as flattened and
  /// become dead nodes for future depth computation.
  List<CompactCheckpointRecord> _flattenForDepthCap(_CkptRange range) {
    final byId = {for (final ckpt in range.state.checkpoints) ckpt.id: ckpt};
    final covered = range.coveredRecordIds.toSet();
    return [
      for (final ckpt in range.state.checkpoints)
        if (covered.contains(ckpt.id) && _depthOf(ckpt, byId, {}) >= depthCap)
          ckpt,
    ];
  }

  int _depthOf(
    CompactCheckpointRecord ckpt,
    Map<String, CompactCheckpointRecord> byId,
    Set<String> visiting,
  ) {
    if (!visiting.add(ckpt.id)) return 1; // Cycle defense: treat as leaf.
    var depth = 1;
    for (final id in ckpt.coversRecordIds) {
      final inner = byId[id];
      if (inner == null) continue;
      if (ckpt.flattenedRecordIds.contains(id)) continue; // Dead node.
      final innerDepth = _depthOf(inner, byId, visiting);
      if (innerDepth + 1 > depth) depth = innerDepth + 1;
    }
    visiting.remove(ckpt.id);
    return depth;
  }

  Future<String?> _summarizeRange(
    _CkptRange range,
    List<CompactCheckpointRecord> flattened,
  ) async {
    final rangeRecords = <MessageRecord>[
      for (final record in range.visible)
        if (range.coveredRecordIds.contains(record.id) &&
            record is MessageRecord)
          record,
    ];
    final messages = [for (final record in rangeRecords) record.message];
    final coversSeqs = <int>[];
    for (final id in range.coveredRecordIds) {
      final seq = range.seqs.seqOf(id);
      if (seq != null) coversSeqs.add(seq);
    }
    final coversRanges = idsToRanges(coversSeqs);
    final openAsks = userRequestCandidateLines(
      messages,
      recordIds: [for (final record in rangeRecords) record.id],
    );
    final prompt = StringBuffer()
      ..writeln('<conversation>')
      ..writeln(serializeConversation(messages))
      ..writeln('</conversation>')
      ..writeln(
        '<covers>The checkpoint replaces these expand ids: '
        '$coversRanges. List them in your summary.</covers>',
      );
    if (openAsks.isNotEmpty) {
      prompt
        ..writeln('<open-user-requests>')
        ..writeln(openAsks.join('\n'))
        ..writeln('</open-user-requests>');
    }
    for (final folded in flattened) {
      prompt
        ..writeln('<folded-checkpoint>')
        ..writeln(folded.text)
        ..writeln('</folded-checkpoint>');
    }
    prompt.writeln(checkpointPrompt);
    try {
      final result = await summarize(
        SummarizationRequest(
          prompt: prompt.toString(),
          cancelToken: cancelToken,
        ),
      );
      final text = result.text?.trim();
      return (text == null || text.isEmpty) ? null : text;
    } catch (_) {
      return null;
    }
  }
}

/// Applies the classic compaction cut to a branch path: everything before
/// the LAST [CompactionRecord]'s first-kept entry drops away, the
/// [CompactionRecord] itself (its summary) heads the result. A path with
/// no classic compaction passes through unchanged.
List<SessionRecord> classicTransform(List<SessionRecord> path) {
  CompactionRecord? compaction;
  for (final entry in path) {
    if (entry is CompactionRecord) compaction = entry;
  }
  if (compaction == null) return [...path];
  final entries = <SessionRecord>[compaction];
  final index = path.indexOf(compaction);
  var foundFirstKept = false;
  for (var i = 0; i < index; i++) {
    if (path[i].id == compaction.firstKeptEntryId) foundFirstKept = true;
    if (foundFirstKept) entries.add(path[i]);
  }
  for (var i = index + 1; i < path.length; i++) {
    entries.add(path[i]);
  }
  return entries;
}

final class _LedgerView {
  const _LedgerView(this.ledger, this.state, this.visible, this.seqs);

  final ContextLedger ledger;
  final StructuredViewState state;
  final List<SessionRecord> visible;
  final RecordSeqIndex seqs;
}

final class _CkptRange {
  const _CkptRange({
    required this.firstRecordId,
    required this.lastRecordId,
    required this.coveredRecordIds,
    required this.state,
    required this.visible,
    required this.seqs,
  });

  final String firstRecordId;
  final String lastRecordId;
  final List<String> coveredRecordIds;
  final StructuredViewState state;
  final List<SessionRecord> visible;
  final RecordSeqIndex seqs;
}
