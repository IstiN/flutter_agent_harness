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

import 'dart:async';

import '../../agent/agent.dart' show AgentState;
import '../../cancel_token.dart' show CancelToken, CancelTokenSource;
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
    this.summarizedCount = 0,
    this.summary,
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

  /// Message records folded into the checkpoint (checkpoint passes).
  final int summarizedCount;

  /// The checkpoint text this pass wrote; `null` for hide passes.
  final String? summary;
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
    this.budgetSource,
    this.attemptBudget = const Duration(seconds: 90),
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

  /// Writable side of the token the factory handed to the judge and
  /// summarizer adapters; the attempt/total budgets cancel it so a wedged
  /// call dies at the provider layer (issue #515).
  final CancelTokenSource? budgetSource;

  /// Wall-clock budget for ONE judge/summarizer call (issue #515). The
  /// call site's host watchdogs are disarmed by the time compaction runs,
  /// so a provider that accepts the request and never answers must die
  /// here: on expiry the budget token aborts the underlying HTTP call and
  /// a named [TimeoutException] fails the run.
  final Duration attemptBudget;

  /// The token passed into every LLM call: the budget source when the
  /// factory provided one, else the plain external [cancelToken].
  CancelToken? get _effectiveToken => budgetSource?.token ?? cancelToken;

  int _pass = 0;

  /// The live request-size estimate in the ONE basis the ctx meter, the
  /// loop's over-window guard, and the classic compactor all enforce:
  /// transcript estimate plus the system-prompt / tool-schema overhead
  /// whenever no provider-usage anchor prices them in.
  int _requestTokens() => estimateRequestTokens(
    state.messages,
    systemPrompt: state.systemPrompt,
    tools: state.tools,
  );

  /// Runs both passes; returns whether the context ended under pressure.
  Future<bool> run({bool force = false}) async {
    if (window <= 0) return true;
    final trigger = window - settings.reserveTokens;
    if (!force && _requestTokens() <= trigger) {
      return true;
    }
    if (!await _runHidePasses(trigger)) return false;
    if (!await _runCheckpointPasses(trigger)) return false;
    return _requestTokens() <= trigger;
  }

  /// Cancels the budget token — the factory's total-budget race calls
  /// this so the wedged call dies at the provider layer.
  void cancelBudget(Object? reason) => budgetSource?.cancel(reason);

  /// The named [TimeoutException] a budget expiry throws (issue #515).
  TimeoutException _budgetTimeout(String what, Duration budget) =>
      TimeoutException(
        'structured compaction $what exceeded the '
        '${budget.inSeconds}s budget (issue #515)',
        budget,
      );

  Future<bool> _runHidePasses(int trigger) async {
    for (var i = 0; i < maxHidePasses; i++) {
      final before = _requestTokens();
      if (before <= trigger) return true;
      final view = await _buildView();
      if (view == null) return true;
      if (_hideableEntries(view.ledger).isEmpty) break;

      final answer = await judge(view.ledger.render()).timeout(
        attemptBudget,
        onTimeout: () {
          final timeout = _budgetTimeout('hide judge', attemptBudget);
          budgetSource?.cancel(timeout);
          throw timeout;
        },
      );
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
      final before = _requestTokens();
      if (before <= trigger) return true;
      final range = await _pickCheckpointRange();
      if (range == null) break;

      final flattened = _flattenForDepthCap(range);
      final String text;
      try {
        text = await _summarizeRange(range, flattened) ?? '';
      } on TimeoutException {
        // A budget kill must surface as a named error (issue #515), not
        // dissolve into the ordinary failure-safety null.
        rethrow;
      }
      if (text.isEmpty) return false;

      await session.appendCompactCheckpoint(
        firstRecordId: range.firstRecordId,
        lastRecordId: range.lastRecordId,
        text: text,
        coversRecordIds: range.coveredRecordIds,
        flattenedRecordIds: [for (final ckpt in flattened) ckpt.id],
      );
      final after = await _refreshState();
      var summarizedCount = 0;
      for (final id in range.coveredRecordIds) {
        final seq = range.seqs.seqOf(id);
        if (seq != null && range.seqs.recordAt(seq) is MessageRecord) {
          summarizedCount++;
        }
      }
      hooks?.onPass(
        StructuredCompactionPass(
          kind: 'checkpoint',
          pass: ++_pass,
          tokensBefore: before,
          tokensAfter: after,
          ok: true,
          judgeCalls: 1,
          summarizedCount: summarizedCount,
          summary: text,
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
      path,
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
    return _requestTokens();
  }

  /// Projects the view path into sized entries: visible records at their
  /// full token cost, hidden ones at their marker's (issue #387 - a
  /// checkpoint must see the marker bytes it would consolidate).
  List<_ProjectedEntry> _projectedEntries(_LedgerView view) {
    final projected = <_ProjectedEntry>[];
    for (final record in view.path) {
      if (!view.state.isCovered(record.id) && _projects(record)) {
        final seq = view.seqs.seqOf(record.id) ?? 0;
        final hidden = view.state.hiddenRecordIds.contains(record.id);
        projected.add(
          _ProjectedEntry(
            record.id,
            hidden ? hiddenMarkerTokens(record, seq) : recordTokens(record),
          ),
        );
      }
    }
    return projected;
  }

  /// Picks the next checkpoint range: the oldest PROJECTED records up to
  /// the keep-recent boundary, snapped inward to pair groups.
  ///
  /// Issue #387: the walk projects HIDDEN records at their marker size —
  /// a checkpoint covering a marker run consolidates the per-record
  /// marker lines into one text summary, so marker overhead cannot grow
  /// without bound. Without this, hide passes accumulate one-line
  /// markers that no later pass ever folds (they are invisible to the
  /// ledger), and the wire payload creeps back toward the window.
  Future<_CkptRange?> _pickCheckpointRange() async {
    final view = await _buildView();
    if (view == null) return null;
    final projected = _projectedEntries(view);
    if (projected.isEmpty) return null;

    // The protected tail: newest projected bytes totalling the keep-recent
    // budget never enter a range (issue #388 keep-recent floor).
    var tailBudget = settings.keepRecentTokens;
    var cut = projected.length;
    for (var i = projected.length - 1; i >= 0; i--) {
      tailBudget -= projected[i].tokens;
      if (tailBudget <= 0) {
        cut = i;
        break;
      }
    }
    // Snap inward at group boundaries: a range never splits a pair.
    while (cut > 1 && _sharesGroup(projected, cut, view.ledger)) {
      cut--;
    }
    if (cut <= 0) return null;
    final members = projected.take(cut).toList();
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

  bool _sharesGroup(
    List<_ProjectedEntry> entries,
    int cut,
    ContextLedger ledger,
  ) {
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
    // Issue #387 marker consolidation: a range with no visible message
    // records folds a pure marker run — nothing is left to summarize, so
    // a deterministic note replaces the LLM call. Every id stays
    // expandable (the covers list still names them); the summarizer is
    // never invoked on marker-only ranges.
    if (rangeRecords.isEmpty) {
      return 'Earlier records already hidden behind expand markers '
          '(${idsToRanges(coversSeqs)}) were consolidated here to bound '
          'marker overhead. Use compact_expand on any id to reopen a '
          'record.';
    }
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
      final result =
          await summarize(
            SummarizationRequest(
              prompt: prompt.toString(),
              cancelToken: _effectiveToken,
            ),
          ).timeout(
            attemptBudget,
            onTimeout: () {
              final timeout = _budgetTimeout(
                'checkpoint summarizer',
                attemptBudget,
              );
              budgetSource?.cancel(timeout);
              throw timeout;
            },
          );
      final text = result.text?.trim();
      return (text == null || text.isEmpty) ? null : text;
    } on TimeoutException {
      // A budget kill surfaces as a named error (issue #515) — the pass
      // loop must not dissolve it into the failure-safety null.
      rethrow;
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
  const _LedgerView(
    this.ledger,
    this.state,
    this.visible,
    this.seqs,
    this.path,
  );

  final ContextLedger ledger;
  final StructuredViewState state;
  final List<SessionRecord> visible;
  final RecordSeqIndex seqs;

  /// The whole (post-classic-transform) branch: visible AND hidden
  /// records. The checkpoint walk projects this to weigh hidden records
  /// at their marker size (issue #387 consolidation).
  final List<SessionRecord> path;
}

/// One record in the projected checkpoint walk: its id and its wire
/// cost (payload tokens for visible records, marker tokens for hidden).
final class _ProjectedEntry {
  const _ProjectedEntry(this.recordId, this.tokens);

  final String recordId;
  final int tokens;
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
