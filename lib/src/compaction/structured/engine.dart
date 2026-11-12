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
import 'dart:math' show max, min;

import '../../agent/agent.dart' show AgentState;
import '../../cancel_token.dart' show CancelToken, CancelTokenSource;
import '../../session/session_record.dart';
import '../../session/session_tree.dart';
import '../../context.dart';
import '../../types.dart';
import '../compaction.dart';
import '../summary_sanitizer.dart';
import '../token_estimation.dart';
import 'judge.dart';
import 'judge_health.dart';
import 'ledger.dart';
import 'markers.dart';
import 'projection.dart';
import '../../exceptions.dart' show CompactionException;

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
    this.marginTokens,
    this.bandTokens,
    this.hideableRemaining,
    this.judgeInputEntries,
    this.judgeInputTokens,
    this.judgeElapsedMs,
    this.judgeLatched = false,
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

  /// gh-2044 fragile-band escalation (optional metadata, never content):
  /// the settled margin `trigger - tokensBefore` that triggered the
  /// escalation pass. Null on every other pass kind.
  final int? marginTokens;

  /// gh-2044: the band the margin was measured against
  /// (`settings.reserveTokens`). Null on every other pass kind.
  final int? bandTokens;

  /// gh-2044: remaining hideable-entry count at escalation time — a
  /// diagnostic count only (the rejected "hides exhausted" gate must not
  /// grow back as a hidden precondition). Null on every other pass kind.
  final int? hideableRemaining;

  /// gh-2096 timeout diagnosis (judge-failure and probe receipts): the
  /// attempt shape — the rendered judge input's entry count. Null on
  /// every other pass kind.
  final int? judgeInputEntries;

  /// gh-2096: the rendered judge input's estimated token size. Null on
  /// every other pass kind.
  final int? judgeInputTokens;

  /// gh-2096: the wall-clock time the judged attempt consumed. Null on
  /// every other pass kind.
  final int? judgeElapsedMs;

  /// gh-2096: whether this pass was decided by the cross-run judge-health
  /// latch (a latched skip or a probe receipt). Never content — a count
  /// and a flag only, like the escalation metadata above.
  final bool judgeLatched;
}

/// Rebuilds [state.messages] from the session projection, zeroing usage
/// anchors on rebuilt transcripts (rebuilt messages carry no trustworthy
/// usage). The ONE refresh both the engine passes and the agent-initiated
/// hide use (issue #1379 tier 2) — a single contract, not two copies.
Future<void> refreshAgentState(Session session, AgentState state) async {
  final rebuilt = await session.buildContextMessages();
  // ignore: avoid_print
  print('DBG refreshAgentState t=${DateTime.now()} rebuilt=${rebuilt.length} prev=${state.messages.length} prevRoles=${state.messages.map((m) => m.role).toList()}');
  state.messages = [
    for (final message in rebuilt)
      message is AssistantMessage
          ? message.copyWith(usage: Usage.zero)
          : message,
  ];
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
    this.protectLastN = hideProtectTailEntries,
    this.depthCap = 4,
    this.summarizerWindow,
    this.cancelToken,
    this.budgetSource,
    this.attemptBudget = const Duration(seconds: 300),
    this.judgeTarget = 'role=default',
    this.judgeProbeAfter = const Duration(minutes: 10),
    this.pinnedOperativeBlock,
    this.pinnedLines = const {},
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

  /// The summarizer model's own context window (issue #729) — the smol
  /// role's when it differs from the main model's. `null` falls back to
  /// [window]; when set, a checkpoint prompt that would not fit the
  /// summarizer's payload budget is summarized CHUNK-WISE (each chunk's
  /// summary threaded into the next as a `<folded-checkpoint>`), so no
  /// summarization request ever exceeds the summarizer's window.
  final int? summarizerWindow;

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

  /// Who the judge call talks to, for the named failure line (issue
  /// #541 AC3): `role=smol, model=kimi-k2 @ gate.example.ai` — a dead
  /// judge must never surface as an anonymous TimeoutException.
  final String judgeTarget;

  /// gh-2096: how long a latched judge goes unprobed. While the
  /// cross-run health latch holds, every run takes the deterministic
  /// hide and pays NO judge budget; once this window has elapsed since
  /// the newest health record — or the configured class changed, which
  /// probes at once — the run pays ONE probe call: success unlatches,
  /// failure re-arms the window. The budget tax becomes once per window
  /// instead of once per run.
  final Duration judgeProbeAfter;

  /// gh-1409 E7: the rendered PINNED OPERATIVE LINES block (verbatim-
  /// preserve duty) inserted into every checkpoint prompt. `null` →
  /// prompts are byte-identical to the pre-pin engine (F4 compat guard).
  final String? pinnedOperativeBlock;

  /// gh-1409 AC4: the raw pin lines the sanitizer protects when healing
  /// folded checkpoints re-entering the prompt.
  final Set<String> pinnedLines;

  /// Consecutive judge failures before the deterministic fallback hide
  /// engages (issue #541): one retry, then the judge-less hide. The
  /// threshold itself is [judgeLatchAfter] — the same count persists
  /// across runs through the health latch (gh-2096).
  int _consecutiveJudgeFailures = 0;

  /// gh-2096: the persisted cross-run judge-health state (the newest
  /// `structured_judge_health` record on the branch) and whether the
  /// latch currently holds. Loaded at the start of every hide-pass run.
  JudgeHealthState _judgeHealth = JudgeHealthState.fresh;
  bool _judgeLatched = false;

  /// The token passed into every LLM call: the budget source when the
  /// factory provided one, else the plain external [cancelToken].
  CancelToken? get _effectiveToken => budgetSource?.token ?? cancelToken;

  int _pass = 0;

  /// Issue #1499: per-run ledger entry memo — the judge/LRU/checkpoint
  /// passes each rebuild the ledger over the whole visible path, and the
  /// memo turns every rebuild after the first into O(changed records)
  /// instead of re-tokenizing the session's history.
  final LedgerEntryCache _ledgerCache = LedgerEntryCache();

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
    // ignore: avoid_print
    print('DBG engine.run t=${DateTime.now()} window=$window force=$force');
    if (window <= 0) return true;
    final trigger = window - settings.reserveTokens;
    if (!force && _requestTokens() <= trigger) {
      return true;
    }
    // Tier 2 LRU re-hide (issue #1379): evict least-recently-used
    // expansion artifacts first — the oldest expand call/result pairs
    // re-fold into markers before the judge ever sees the ledger.
    await _runLruRehidePasses(trigger);
    if (!await _runHidePasses(trigger)) return false;
    if (!await _runCheckpointPasses(trigger)) return false;
    // gh-2044 fragile-band escalation: an automatic run that settled with
    // less than one full reserve of headroom deepens once through the
    // checkpoint machinery, whether or not hideable entries remain. The
    // deterministic fallback (issue #541) and the pass loops stop at the
    // trigger, so a degraded run ducks under by a sliver and the next
    // turn or two crosses the trigger again (sid 01a17c9c). Forced runs —
    // manual `/compact` and the message-cap channel (`force || cap`) —
    // keep their existing behavior; `maxCheckpointPasses == 0` keeps
    // meaning "no checkpoint work".
    if (!force && maxCheckpointPasses > 0) {
      final settled = _requestTokens();
      final margin = trigger - settled;
      if (margin >= 0 && margin < settings.reserveTokens) {
        if (!await _runCheckpointEscalationPass(trigger, margin)) {
          return false;
        }
      }
    }
    return _requestTokens() <= trigger;
  }

  /// Tier 2 LRU re-hide (issue #1379): after an expand storm, the oldest
  /// expand call/result pairs re-fold into markers at the next pressure
  /// event — the newest expansion is always kept. LRU order is derived
  /// from file order alone (an expansion's recency IS its record position;
  /// nothing extra is stored), so replay is deterministic. The re-hidden
  /// segments themselves never left hidden-but-expandable state — their
  /// markers stay in the session — so the lossless invariant (#148 AC2)
  /// is untouched.
  Future<void> _runLruRehidePasses(int trigger) async {
    final before = _requestTokens();
    final over = before - trigger;
    if (over <= 0) return;
    final view = await _buildView();
    if (view == null) return;
    final groups = _rehideCandidates(view);
    if (groups.length <= 1) return;
    final evictions = _pickRehideEvictions(
      groups,
      over,
      protectedTailIds(view.ledger, protectLastN),
      view.state.pinnedRecordIds,
    );
    if (evictions.isEmpty) return;
    await session.appendHiddenRange(recordIds: evictions.toList()..sort());
    final after = await _refreshState();
    hooks?.onPass(
      StructuredCompactionPass(
        kind: 'hide-lru',
        pass: ++_pass,
        tokensBefore: before,
        tokensAfter: after,
        ok: true,
        judgeCalls: 0,
        hiddenCount: evictions.length,
      ),
    );
  }

  /// The visible expand-carrier groups oldest-first — the LRU eviction
  /// candidates (issue #1379 tier 2): every visible assistant carrier of
  /// a compact_expand call as its whole pair group, newest last.
  List<(int, Set<String>, int)> _rehideCandidates(_LedgerView view) {
    final byId = {for (final record in view.path) record.id: record};
    final candidates = <(int, Set<String>, int)>[];
    for (final record in view.path) {
      final message = _rehideCandidateMessage(view, record);
      if (message == null || !_isExpandCarrier(message)) continue;
      final (group, tokens, hasResult) = _carrierGroupWeight(
        view,
        byId,
        record.id,
      );
      // An unanswered carrier (no result yet) is not an expansion —
      // hiding it would orphan a live tool call on the wire (#85).
      if (!hasResult) continue;
      candidates.add((view.seqs.seqOf(record.id) ?? 0, group, tokens));
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    return candidates;
  }

  /// The carrier [AssistantMessage] when [record] is a re-hide candidate
  /// at all — a visible assistant record (never hidden, never
  /// checkpoint-covered). Null otherwise.
  AssistantMessage? _rehideCandidateMessage(
    _LedgerView view,
    SessionRecord record,
  ) {
    final message = record is MessageRecord ? record.message : null;
    if (message is! AssistantMessage) return null;
    if (view.state.hiddenRecordIds.contains(record.id)) return null;
    if (view.state.isCovered(record.id)) return null;
    return message;
  }

  /// Whether [message] carries a compact_expand tool call.
  bool _isExpandCarrier(AssistantMessage message) => message.content.any(
    (block) => block is ToolCall && block.name == compactExpandToolName,
  );

  /// The candidate's whole pair group with its token weight and whether a
  /// result message rode along (#85 pair integrity).
  (Set<String>, int, bool) _carrierGroupWeight(
    _LedgerView view,
    Map<String, SessionRecord> byId,
    String carrierId,
  ) {
    final ledger = view.ledger;
    final group = ledger.groupOf(carrierId);
    var tokens = 0;
    var hasResult = false;
    for (final id in group) {
      final other = byId[id];
      if (other is MessageRecord && other.message is ToolResultMessage) {
        hasResult = true;
      }
      final seq = view.seqs.seqOf(id);
      if (seq != null) tokens += ledger.entryAtSeq(seq)?.tokens ?? 0;
    }
    return (group, tokens, hasResult);
  }

  /// The groups to re-fold now: oldest first until [over] tokens are
  /// freed, never touching the newest group, the protected tail, or a
  /// pinned expansion (AC3).
  Set<String> _pickRehideEvictions(
    List<(int, Set<String>, int)> groups,
    int over,
    Set<String> protectedTail,
    Set<String> pinnedRecordIds,
  ) {
    final ids = <String>{};
    var freed = 0;
    for (final (_, group, tokens) in groups.take(groups.length - 1)) {
      if (freed >= over) break;
      // The protected tail holds here exactly as in the judge path, and a
      // pinned expansion stays on the wire (AC3).
      if (group.any(protectedTail.contains)) continue;
      if (group.any(pinnedRecordIds.contains)) continue;
      ids.addAll(group);
      freed += tokens;
    }
    return ids;
  }

  /// gh-2044: the total-budget latch. [cancelBudget] is the factory's
  /// total-budget race kill (issue #515) — the ONE caller — so once it
  /// fires the run's outcome is the factory's authoritative timeout path:
  /// the escalation must not start another attempt after budget
  /// exhaustion, and must not append (nor report) after that outcome.
  /// Deliberately separate from [budgetSource]: per-call attempt-budget
  /// kills cancel the budget token too, and the incident's judge timeouts
  /// must not suppress the escalation (gh-2044 AC1).
  final CancelTokenSource _totalBudgetSource = CancelTokenSource();

  /// Whether the factory's total-budget race has killed this run.
  bool get _totalBudgetSpent => _totalBudgetSource.token.isCancelled;

  /// Cancels the budget token — the factory's total-budget race calls
  /// this so the wedged call dies at the provider layer.
  void cancelBudget(Object? reason) {
    budgetSource?.cancel(reason);
    _totalBudgetSource.cancel(reason);
  }

  /// gh-2044: whether a user/run cancellation killed this run — checked
  /// around the escalation so a cancelled deepening surfaces the abort
  /// (issue #1085 parity) instead of dissolving into "optional pass
  /// failed, success stands". The budget token latches per-call budget
  /// kills too (issue #515 provider-layer aborts carry a
  /// [TimeoutException] reason) — those are NOT cancels: the incident's
  /// judge timeouts must still escalate. Any other reason reached this
  /// token only through the factory's run-token link — a user abort.
  bool get _runCancelled {
    if (cancelToken?.isCancelled ?? false) return true;
    final source = budgetSource;
    if (source == null) return false;
    return source.token.isCancelled &&
        source.token.cancelReason is! TimeoutException;
  }

  /// The named [TimeoutException] a budget expiry throws (issue #515).
  TimeoutException _budgetTimeout(String what, Duration budget) =>
      TimeoutException(
        'structured compaction $what exceeded the '
        '${budget.inSeconds}s budget (issue #515)',
        budget,
      );

  Future<bool> _runHidePasses(int trigger) async {
    // gh-2096: the consecutive-failure counter is PERSISTED per session —
    // it seeds from the newest judge-health record instead of resetting
    // every run (the incident re-paid the full budget on every run for as
    // long as the configured class stayed slow).
    final health = await _loadJudgeHealth();
    _judgeHealth = health;
    _consecutiveJudgeFailures = health.consecutiveFailures;
    _judgeLatched = health.latched;
    for (var i = 0; i < maxHidePasses; i++) {
      final before = _requestTokens();
      if (before <= trigger) return true;
      final view = await _buildView();
      if (view == null) return true;
      if (_hideableEntries(view.ledger).isEmpty) break;

      // gh-2096: the cross-run latch gate — while latched the judge
      // contributes nothing unless the probe window elapsed (or the
      // configured class changed, which probes at once). This run makes
      // exactly one judge decision, then the deterministic hide decides;
      // a non-null gate result is that decision — both skip outcomes
      // converge on the loop's own successful-verdict return.
      if (await _latchedGate(trigger, before) != null) return true;

      final call = await _callJudge(view);
      // F1: a failed judge call hides nothing — but since #541 it is
      // COUNTED, not fatal: one retry, then the deterministic
      // judge-less hide, so a dead judge can no longer brick the run.
      // A garbage answer decided nothing — a failure like any other.
      final picks = call.failure == null ? parseHidePicks(call.answer!) : null;
      if (picks == null) {
        if (!await _handleJudgeFailure(
          trigger,
          call.failure ??
              const CompactionException(
                'hide judge returned an unparseable answer',
              ),
          shape: call.shape,
        )) {
          return true;
        }
        continue;
      }
      _consecutiveJudgeFailures = 0;
      // gh-2096: a parsed answer is a live judge — clear the persisted
      // latch (additive unlatch record; a no-op write when the session
      // was never unhealthy, keeping the legacy flow write-free).
      await _recordJudgeSuccess();
      if (picks.isEmpty) break;
      final ids = validateHidePicks(
        picks,
        view.ledger,
        protectLastN: protectLastN,
        pinnedRecordIds: view.state.pinnedRecordIds,
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

  /// gh-2096: the cross-run latch gate. While latched the judge
  /// contributes nothing this run unless the probe window elapsed (or
  /// the configured class changed, which probes at once): the skip
  /// receipt names the consequence ("budget unwinnable for the
  /// configured class") and the deterministic hide decides. Returns
  /// `null` when the judge may be called; a non-null result means the
  /// run is decided — the skip's outcomes converge on the same
  /// successful-verdict return the loop's natural end produces.
  Future<bool?> _latchedGate(int trigger, int before) async {
    if (!_judgeLatched || _latchedProbeDue) return null;
    return _latchedSkipHide(trigger, before);
  }

  /// One counted judge failure (issue #541 F1): a failed call or a
  /// garbage answer decides nothing — it is COUNTED, not fatal. Returns
  /// whether the hide-pass loop continues. While latched the call WAS
  /// the one probe-per-window: the probe paid the budget and lost, so
  /// count + persist, then the deterministic hide decides — NO retry
  /// (the retry ladder is the tax the latch exists to end) and the run
  /// is decided either way. A fresh failure retries toward
  /// [judgeLatchAfter] and the deterministic judge-less hide; `false`
  /// means that hide decided against continuing — the run ends with the
  /// loop's own successful verdict.
  Future<bool> _handleJudgeFailure(
    int trigger,
    Object failure, {
    JudgeAttemptShape? shape,
  }) async {
    if (_judgeLatched) {
      await _persistProbeFailure();
      await _registerJudgeFailure(
        trigger,
        failure,
        shape: shape,
        latched: true,
      );
      return false;
    }
    return _registerJudgeFailure(trigger, failure, shape: shape);
  }

  /// One judge call under the attempt budget (issue #515). A budget
  /// expiry cancels the budget token — aborting the wedged provider
  /// call — but since #541 it is a JUDGE failure, not a run failure:
  /// the caller counts it and falls toward the deterministic hide.
  ///
  /// gh-2096: the call runs under a PER-CALL child token — a timeout
  /// aborts ONLY the in-flight call, while the retry and the later LM
  /// stages of the run keep a live token (the incident's retry was born
  /// cancelled: the run-wide budget token died with the first timeout
  /// and every later call failed in ~75 ms). The attempt's measured
  /// shape — input entries, estimated tokens, elapsed — rides every
  /// failure receipt.
  Future<({String? answer, Object? failure, JudgeAttemptShape shape})>
  _callJudge(_LedgerView view) async {
    final ledgerText = view.ledger.render();
    final perCall = CancelTokenSource();
    // gh-2096: forward the run-wide token's cancel (a user abort, a
    // total-budget kill) into the in-flight call; a per-call budget
    // expiry cancels ONLY the child — the retry and later stages keep a
    // live parent. One listener per call, bounded by the pass caps.
    final parent = _effectiveToken;
    if (parent != null) {
      unawaited(
        parent.onCancel.then((_) => perCall.cancel(parent.cancelReason)),
      );
    }
    JudgeAttemptShape shapeOf(Duration elapsed) => (
      entries: min(
        view.ledger.entries.length,
        ContextLedger.judgePreviewEntries,
      ),
      tokens: estimateStringTokens(ledgerText),
      elapsed: elapsed,
    );
    final watch = Stopwatch()..start();
    try {
      final answer = await judge(ledgerText, perCall.token).timeout(
        attemptBudget,
        onTimeout: () {
          final timeout = _judgeTimeout(shapeOf(watch.elapsed));
          // gh-2096: the child token dies — the parent (the retry and
          // the summarizer stages) stays live.
          perCall.cancel(timeout);
          throw timeout;
        },
      );
      watch.stop();
      // HideJudgeFn contract: null IS a failed call (F1) — count it.
      return (
        answer: answer,
        failure: answer == null
            ? const CompactionException('hide judge failed call')
            : null,
        shape: shapeOf(watch.elapsed),
      );
    } on Object catch (error) {
      watch.stop();
      // Timeout and adapter/provider failures alike: a judge failure like
      // any other; the run must not die on it.
      return (answer: null, failure: error, shape: shapeOf(watch.elapsed));
    }
  }

  /// Records a judge failure (issue #541): a named pass report, then —
  /// after [judgeLatchAfter] consecutive failures — the deterministic
  /// judge-less hide. gh-2096: the failure receipt carries the attempt
  /// [shape] and the [latched] flag, and the threshold crossing PERSISTS
  /// the latch (an additive record) so the next run skips the judge.
  /// Returns whether the hide loop continues.
  Future<bool> _registerJudgeFailure(
    int trigger,
    Object error, {
    JudgeAttemptShape? shape,
    bool latched = false,
  }) async {
    _consecutiveJudgeFailures++;
    final tokens = _requestTokens();
    hooks?.onPass(
      StructuredCompactionPass(
        kind: 'hide',
        pass: ++_pass,
        tokensBefore: tokens,
        tokensAfter: tokens,
        ok: false,
        error: error,
        judgeInputEntries: shape?.entries,
        judgeInputTokens: shape?.tokens,
        judgeElapsedMs: shape?.elapsed.inMilliseconds,
        judgeLatched: latched,
      ),
    );
    if (_consecutiveJudgeFailures < judgeLatchAfter) return true;
    if (!_judgeLatched) {
      // The latch engages NOW: persist it (best-effort) so the next run
      // takes the deterministic hide without re-paying the budget, and
      // mirror the state in memory (a still-over run keeps skipping).
      await _persistJudgeHealth(
        consecutiveFailures: _consecutiveJudgeFailures,
        target: judgeTarget,
      );
      _judgeLatched = true;
      _judgeHealth = JudgeHealthState(
        consecutiveFailures: _consecutiveJudgeFailures,
        target: judgeTarget,
        updatedAt: DateTime.now(),
      );
    }
    return _deterministicHide(trigger);
  }

  /// gh-2096: whether the latched judge gets its probe this run — the
  /// probe window elapsed since the newest health record, or the
  /// configured class changed since the latch (a new class deserves an
  /// immediate chance; the latch is about the class, not the session).
  bool get _latchedProbeDue {
    final health = _judgeHealth;
    final target = health.target;
    if (target != null && target != judgeTarget) return true;
    final updated = health.updatedAt;
    if (updated == null) return true;
    return DateTime.now().difference(updated) >= judgeProbeAfter;
  }

  /// gh-2096: the latched skip — the judge contributes nothing this run.
  /// The receipt names the consequence explicitly ("budget unwinnable
  /// for the configured class"), then the deterministic hide decides.
  Future<bool> _latchedSkipHide(int trigger, int before) async {
    hooks?.onPass(
      StructuredCompactionPass(
        kind: 'hide',
        pass: ++_pass,
        tokensBefore: before,
        tokensAfter: before,
        ok: false,
        error: CompactionException(
          'judge latched: budget unwinnable for the configured class '
          '(consecutive judge failures: $_consecutiveJudgeFailures) — '
          'skipping the judge this run (gh-2096)',
        ),
        judgeLatched: true,
      ),
    );
    return _deterministicHide(trigger);
  }

  /// gh-2096: the probe's failure count grew — persist it (best-effort)
  /// and re-arm the probe window before the fallback decides the run.
  Future<void> _persistProbeFailure() async {
    await _persistJudgeHealth(
      consecutiveFailures: _consecutiveJudgeFailures + 1,
      target: judgeTarget,
    );
    _judgeHealth = JudgeHealthState(
      consecutiveFailures: _consecutiveJudgeFailures + 1,
      target: judgeTarget,
      updatedAt: DateTime.now(),
    );
  }

  /// gh-2096: a parsed judge answer is a live judge — persist the
  /// unlatch when the session was ever unhealthy. A legacy session
  /// (never latched) writes nothing, keeping the healthy flow
  /// byte-identical.
  Future<void> _recordJudgeSuccess() async {
    if (!_judgeLatched && _judgeHealth.consecutiveFailures == 0) return;
    _judgeLatched = false;
    _judgeHealth = JudgeHealthState.fresh;
    await _persistJudgeHealth(consecutiveFailures: 0, target: judgeTarget);
  }

  /// Loads the persisted judge-health state from the branch path
  /// (gh-2096). A read failure degrades to fresh — the latch must never
  /// fail a run.
  Future<JudgeHealthState> _loadJudgeHealth() async {
    try {
      return judgeHealthFromPath(await session.getBranch()) ??
          JudgeHealthState.fresh;
    } on Object catch (_) {
      return JudgeHealthState.fresh;
    }
  }

  /// Appends the additive health record (gh-2096). Best-effort: a sealed
  /// or read-only session keeps its in-memory decision and never fails
  /// the compaction over the latch bookkeeping.
  Future<void> _persistJudgeHealth({
    required int consecutiveFailures,
    String? target,
  }) async {
    try {
      await session.appendCustomEntry(
        customType: judgeHealthRecordType,
        data: judgeHealthPayload(
          consecutiveFailures: consecutiveFailures,
          target: target,
        ),
      );
    } on Object catch (_) {
      // Best-effort by contract — see the doc comment.
    }
  }

  /// The deterministic judge-less hide (issue #541): the judge is down
  /// after N consecutive failures — hide oldest-first, whole pair
  /// groups, past the recency floor, until the request fits under the
  /// trigger again. No LLM: the session always makes progress, even
  /// with every judge endpoint dark.
  Future<bool> _deterministicHide(int trigger) async {
    if (cancelToken?.isCancelled ?? false) return false;
    final view = await _buildView();
    if (view == null) return false;
    final ledger = view.ledger;
    final before = _requestTokens();
    final over = before - trigger;
    final protectedTail = protectedTailIds(ledger, protectLastN);
    final tokensById = {
      for (final entry in ledger.entries) entry.recordId: entry.tokens,
    };
    final ids = <String>{};
    var freed = 0;
    for (final entry in ledger.entries) {
      if (freed >= over) break;
      if (entry.exempt ||
          ids.contains(entry.recordId) ||
          protectedTail.contains(entry.recordId)) {
        continue;
      }
      // Pair integrity (#85/D6): a group hides whole or never — the
      // veto lives in the token helper below.
      final group = ledger.groupOf(entry.recordId);
      final groupTokens = _hideableGroupTokens(
        tokensById,
        group,
        protectedTail,
      );
      if (groupTokens == null) continue;
      // Tier 2 pin (issue #1379): the fallback never hides a pinned group.
      if (group.any(view.state.pinnedRecordIds.contains)) continue;
      ids.addAll(group);
      freed += groupTokens;
    }
    if (ids.isEmpty) {
      // E1: even oldest-first cannot free anything — name the largest
      // remaining record instead of looping silently.
      hooks?.onPass(
        StructuredCompactionPass(
          kind: 'hide',
          pass: ++_pass,
          tokensBefore: before,
          tokensAfter: before,
          ok: false,
          error: CompactionException(
            'deterministic fallback found nothing hideable past the '
            'recency floor; largest remaining record: '
            '${_largestEntry(ledger)}',
          ),
        ),
      );
      return false;
    }
    await session.appendHiddenRange(recordIds: ids.toList()..sort());
    final after = await _refreshState();
    hooks?.onPass(
      StructuredCompactionPass(
        kind: 'hide-fallback',
        pass: ++_pass,
        tokensBefore: before,
        tokensAfter: after,
        ok: true,
        hiddenCount: ids.length,
      ),
    );
    return true;
  }

  String _largestEntry(ContextLedger ledger) {
    LedgerEntry largest = ledger.entries.first;
    for (final entry in ledger.entries) {
      if (entry.tokens > largest.tokens) largest = entry;
    }
    return '[${largest.seq}] ${largest.kind} ~${largest.tokens}tok';
  }

  /// Returns the group's token weight, or null when vetoed.
  int? _hideableGroupTokens(
    Map<String, int> tokensById,
    Iterable<String> group,
    Set<String> protectedTail,
  ) {
    var groupTokens = 0;
    for (final id in group) {
      if (protectedTail.contains(id)) return null;
      groupTokens += tokensById[id] ?? 0;
    }
    return groupTokens;
  }

  /// The named judge-timeout error (issue #541 AC3): role, model and
  /// endpoint of the dead call — never an anonymous TimeoutException.
  /// gh-2096: the attempt shape rides the line — input entries, estimated
  /// tokens, elapsed — so "slow-reasoning class" vs "wedged/queueing
  /// endpoint" is distinguishable from logs alone.
  TimeoutException _judgeTimeout(JudgeAttemptShape shape) => TimeoutException(
    'structured compaction judge timeout '
    '($judgeTarget, ${attemptBudget.inSeconds}s budget, '
    'entries=${shape.entries}, ~${shape.tokens} tok, '
    'elapsed=${shape.elapsed.inMilliseconds}ms) (issue #515)',
    attemptBudget,
  );

  Future<bool> _runCheckpointPasses(int trigger) async {
    for (var i = 0; i < maxCheckpointPasses; i++) {
      final before = _requestTokens();
      if (before <= trigger) return true;
      // Relief is required here (the pass only runs over the trigger), so
      // the whole-world decline does not apply: a transcript whose every
      // ledger token fits keepRecentTokens — typically one huge tool
      // result — still folds, or the flutter_app over-window relief AC
      // starves (gh-2044 rework, UT-ESC-13).
      final range = await _pickCheckpointRange(wholeWorldDeclines: false);
      if (range == null) break;

      final flattened = _flattenForDepthCap(range);
      final String text;
      try {
        // The ladder receipt keeps its historical `judgeCalls: 1` shape;
        // the call counts ride the escalation receipt (gh-2044 thread 4).
        text = (await _summarizeRange(range, flattened)).text ?? '';
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

  /// gh-2044 fragile-band escalation: exactly ONE extra checkpoint pass
  /// after an automatic run (`force == false` — enforced by the caller)
  /// settled with thin relief, `0 <= trigger - settled <
  /// settings.reserveTokens`. The deterministic fallback (issue #541) is
  /// intentionally minimal — it hides just enough to duck under the
  /// trigger — so a degraded run lands right back on pressure within a
  /// turn or two; this pass deepens with the EXISTING checkpoint
  /// machinery instead (projection invariants, marker consolidation, the
  /// #729 chunked fold — all inherited, not reimplemented).
  ///
  /// Contract:
  /// - Thin settled headroom is the ONLY gate. Hideable entries may
  ///   remain (the minimal fallback cannot prove exhaustion); the count
  ///   rides the report as a diagnostic.
  /// - Bounded: at most one pass, never a hide re-entry, never a loop —
  ///   a still-thin post-escalation result keeps the existing verdict.
  /// - Failure safety: a no-work outcome (no foldable range), an empty
  ///   summary or an append error keeps the pre-escalation under-trigger
  ///   verdict and emits ONE explicit failed escalation report.
  /// - A cancellation or a budget expiry is NOT an ordinary failure: a
  ///   cancelled run reports failure so the factory surfaces the abort
  ///   (issue #1085); a [TimeoutException] propagates to the factory's
  ///   #515/#1425 outcome path and no further attempt starts after the
  ///   total-budget kill.
  /// - Marker-only ranges consolidate deterministically — no LLM call is
  ///   made, and none is reported.
  ///
  /// Returns whether the run's verdict stands (false only to surface a
  /// cancellation).
  Future<bool> _runCheckpointEscalationPass(int trigger, int margin) async {
    if (_runCancelled || _totalBudgetSpent) return false;
    final band = settings.reserveTokens;
    final before = _requestTokens();
    final view = await _buildView();
    // Diagnostic count only — never rendered content.
    final hideableRemaining = _hideableRemainingOf(view);
    void emit({
      required int after,
      required bool ok,
      Object? error,
      int judgeCalls = 0,
      int summarizedCount = 0,
      String? summary,
    }) {
      hooks?.onPass(
        _escalationReceipt(
          before: before,
          after: after,
          ok: ok,
          error: error,
          judgeCalls: judgeCalls,
          summarizedCount: summarizedCount,
          summary: summary,
          margin: margin,
          band: band,
          hideableRemaining: hideableRemaining,
        ),
      );
    }

    // The deepening pass declines the whole-world regime unconditionally
    // (gh-2044 semantic 5): it only runs under the trigger, so folding the
    // live world would be pure live-tail destruction.
    final range = await _pickCheckpointRange(
      view: view,
      wholeWorldDeclines: true,
    );
    if (range == null) {
      // Bounded no-op (gh-2044 semantic 5): nothing foldable below the
      // keep-recent boundary — e.g. an entirely pinned/exempt foldable
      // prefix. The pre-escalation verdict stands; no classic/lossy
      // escape.
      emit(
        after: before,
        ok: false,
        error: const CompactionException(
          'checkpoint escalation found no foldable range below the '
          'keep-recent boundary',
        ),
      );
      return true;
    }
    final outcome = await _runEscalationFold(range);
    // gh-2044 semantic 7: the factory's total-budget kill is the
    // authoritative outcome — no append and no report after it, whether
    // the in-flight call died with the budget or raced it.
    if (outcome.budgetSpent) return true;
    if (outcome.cancelled) return false;
    if (outcome.error != null) {
      emit(after: before, ok: false, error: outcome.error);
      return true;
    }
    final after = await _refreshState();
    final (:summarizedCount, :visibleMessages) = _escalationCounts(range);
    emit(
      after: after,
      ok: true,
      // The REAL call count: 0 for the marker-only deterministic
      // consolidation (issue #387, gh-2044 semantic 9), 1 for a single
      // in-window fold, N for a #729 chunked fold — observability is this
      // pass's whole purpose (gh-2044 review thread 4).
      judgeCalls: visibleMessages == 0 ? 0 : outcome.summarizerCalls,
      summarizedCount: summarizedCount,
      summary: outcome.text,
    );
    return true;
  }

  /// The escalation's fold work, extracted so the pass body keeps only
  /// its decision flow (gh-2044 rework: CRAP ratchet). [budgetSpent] is
  /// the factory's authoritative total-budget kill (gh-2044 semantic 7 —
  /// no receipt may follow it); [cancelled] outranks any error receipt
  /// (issue #1085 — a cancelled run is never a mere failed pass);
  /// [error] is the failure-safety receipt error, `null` on success.
  Future<
    ({
      bool budgetSpent,
      bool cancelled,
      Object? error,
      String? text,
      int summarizerCalls,
    })
  >
  _runEscalationFold(_CkptRange range) async {
    final flattened = _flattenForDepthCap(range);
    final String? text;
    int summarizerCalls = 0;
    try {
      final summarized = await _summarizeRange(range, flattened);
      text = summarized.text;
      summarizerCalls = summarized.summarizerCalls;
    } on TimeoutException {
      // A budget kill must surface as a named error (issue #515), not
      // dissolve into the optional-pass null — the factory's #515/#1425
      // outcome path owns it.
      rethrow;
    }
    if (_totalBudgetSpent) {
      return (
        budgetSpent: true,
        cancelled: false,
        error: null,
        text: null,
        summarizerCalls: summarizerCalls,
      );
    }
    if (text == null || text.isEmpty) {
      if (_runCancelled) {
        return (
          budgetSpent: false,
          cancelled: true,
          error: null,
          text: null,
          summarizerCalls: summarizerCalls,
        );
      }
      return (
        budgetSpent: false,
        cancelled: false,
        error: const CompactionException(
          'checkpoint escalation summarizer returned no text',
        ),
        text: null,
        summarizerCalls: summarizerCalls,
      );
    }
    final appended = await _appendEscalationCheckpoint(range, flattened, text);
    if (appended != null) {
      if (_runCancelled) {
        return (
          budgetSpent: false,
          cancelled: true,
          error: null,
          text: null,
          summarizerCalls: summarizerCalls,
        );
      }
      return (
        budgetSpent: false,
        cancelled: false,
        error: appended,
        text: null,
        summarizerCalls: summarizerCalls,
      );
    }
    return (
      budgetSpent: false,
      cancelled: false,
      error: null,
      text: text,
      summarizerCalls: summarizerCalls,
    );
  }

  /// The escalation receipt (kind + the fragile-band metadata), extracted
  /// so the pass's report shape stays in one place (gh-2044 rework: CRAP
  /// ratchet — the pass body keeps its decision flow only).
  StructuredCompactionPass _escalationReceipt({
    required int before,
    required int after,
    required bool ok,
    required int margin,
    required int band,
    required int hideableRemaining,
    Object? error,
    int judgeCalls = 0,
    int summarizedCount = 0,
    String? summary,
  }) => StructuredCompactionPass(
    kind: 'checkpoint-escalation',
    pass: ++_pass,
    tokensBefore: before,
    tokensAfter: after,
    ok: ok,
    error: error,
    judgeCalls: judgeCalls,
    summarizedCount: summarizedCount,
    summary: summary,
    marginTokens: margin,
    bandTokens: band,
    hideableRemaining: hideableRemaining,
  );

  /// Diagnostic count only — never rendered content.
  int _hideableRemainingOf(_LedgerView? view) =>
      view == null ? 0 : _hideableEntries(view.ledger).length;

  /// Failure-safety append: returns the append error, or `null` on
  /// success. A [TimeoutException] still propagates (issue #515 — the
  /// budget kill is the factory's outcome, never an ordinary append
  /// failure).
  Future<Object?> _appendEscalationCheckpoint(
    _CkptRange range,
    List<CompactCheckpointRecord> flattened,
    String text,
  ) async {
    try {
      await session.appendCompactCheckpoint(
        firstRecordId: range.firstRecordId,
        lastRecordId: range.lastRecordId,
        text: text,
        coversRecordIds: range.coveredRecordIds,
        flattenedRecordIds: [for (final ckpt in flattened) ckpt.id],
      );
      return null;
    } on TimeoutException {
      rethrow;
    } on Object catch (error) {
      return error;
    }
  }

  /// Covered MessageRecord count and the covered-and-visible message
  /// count the receipt's real `judgeCalls` decision reads (gh-2044 review
  /// thread 4).
  ({int summarizedCount, int visibleMessages}) _escalationCounts(
    _CkptRange range,
  ) {
    var summarizedCount = 0;
    for (final id in range.coveredRecordIds) {
      final seq = range.seqs.seqOf(id);
      if (seq == null) continue;
      if (range.seqs.recordAt(seq) is MessageRecord) summarizedCount++;
    }
    var visibleMessages = 0;
    for (final record in range.visible) {
      if (record is MessageRecord &&
          range.coveredRecordIds.contains(record.id)) {
        visibleMessages++;
      }
    }
    return (summarizedCount: summarizedCount, visibleMessages: visibleMessages);
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
    final visible = visibleStructuredPath(path, viewState);
    if (visible.isEmpty) return null;
    final seqs = RecordSeqIndex(await session.getEntries());
    return _LedgerView(
      buildContextLedger(visiblePath: visible, seqs: seqs, cache: _ledgerCache),
      viewState,
      visible,
      seqs,
      path,
    );
  }

  /// Rebuilds `state.messages` from the session projection, zeroing usage
  /// anchors on rebuilt transcripts (the classic engine's convention —
  /// rebuilt messages carry no trustworthy usage).
  Future<int> _refreshState() async {
    await refreshAgentState(session, state);
    return _requestTokens();
  }

  /// Projects the view path into sized entries: visible records at their
  /// full token cost, hidden ones at their marker's (issue #387 - a
  /// checkpoint must see the marker bytes it would consolidate).
  List<_ProjectedEntry> _projectedEntries(_LedgerView view) {
    final projected = <_ProjectedEntry>[];
    for (final record in view.path) {
      if (!view.state.isCovered(record.id) && projectsStructured(record)) {
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
  /// the keep-recent boundary, snapped inward to pair groups. The
  /// gh-2044 escalation passes its own prebuilt [view] so the range and
  /// the diagnostic counts measure the same ledger; the ordinary pass
  /// ladder builds its own.
  ///
  /// Issue #387: the walk projects HIDDEN records at their marker size —
  /// a checkpoint covering a marker run consolidates the per-record
  /// marker lines into one text summary, so marker overhead cannot grow
  /// without bound. Without this, hide passes accumulate one-line
  /// markers that no later pass ever folds (they are invisible to the
  /// ledger), and the wire payload creeps back toward the window.
  /// Whether the whole-world regime declines. The escalation's deepening
  /// pass (gh-2044 semantic 5) must never fold the live world: when its
  /// foldable path fits keepRecentTokens entirely, folding would swallow
  /// the live tail for zero needed relief (the escalation only runs under
  /// the trigger). Ladder passes waive the decline — they run only over
  /// the trigger, where the fold IS the relief (UT-ESC-13).
  bool _wholeWorldDeclines(
    _LedgerView view_,
    List<_ProjectedEntry> foldable,
    bool wholeWorldDeclines,
  ) {
    if (!wholeWorldDeclines) return false;
    final hiddenIds = view_.state.hiddenRecordIds;
    return foldable.any((entry) => !hiddenIds.contains(entry.recordId));
  }

  Future<_CkptRange?> _pickCheckpointRange({
    _LedgerView? view,
    required bool wholeWorldDeclines,
  }) async {
    final view_ = view ?? await _buildView();
    if (view_ == null) return null;
    final projected = _projectedEntries(view_);
    if (projected.isEmpty) return null;

    // The foldable prefix: pins and their whole pair groups drop out
    // BEFORE the keep-recent walk (issue #1379 tier 2 rework). They
    // can never fold, so they consume no keep-recent budget and never
    // clamp the window — the walk measures foldable bytes only. A deep
    // pin cannot starve checkpointing: every pass still folds the
    // oldest unpinned content wherever the pin sits, while pinned
    // records keep rendering at their positions, unswallowed and
    // unsummarized. The only stall left is an empty foldable prefix —
    // the same honest nothing-to-fold an exempt range gives, never a
    // pin-induced fallback to the lossy classic path (the judge,
    // deterministic and LRU passes still run).
    final foldable = [
      for (final entry in projected)
        if (!view_.ledger
            .groupOf(entry.recordId)
            .any(view_.state.pinnedRecordIds.contains))
          entry,
    ];
    if (foldable.isEmpty) return null;
    var tailBudget = settings.keepRecentTokens;
    var cut = foldable.length;
    for (var i = foldable.length - 1; i >= 0; i--) {
      tailBudget -= foldable[i].tokens;
      if (tailBudget <= 0) {
        cut = i;
        break;
      }
    }
    // gh-2044 rework (CI regression): when the walk above never exhausts
    // its budget, the ENTIRE foldable path fits INSIDE the keep-recent
    // region — the default `cut = foldable.length` then folds everything
    // and keeps zero recent context, swallowing the live tail (the newest
    // user ask and assistant turn included). Nothing below the keep-recent
    // boundary means nothing to fold — except an all-markers path (every
    // record already hidden), whose deterministic consolidation (issue
    // #387) is lossless and touches no live content. The decline applies
    // only to the escalation's deepening (semantic 5); ladder passes run
    // over the trigger and fold for relief (UT-ESC-13).
    if (cut == foldable.length &&
        _wholeWorldDeclines(view_, foldable, wholeWorldDeclines)) {
      return null;
    }
    // Snap inward at group boundaries: a range never splits a pair.
    while (cut > 1 && _sharesGroup(foldable, cut, view_.ledger)) {
      cut--;
    }
    final members = foldable.take(cut).toList();
    if (members.isEmpty) return null;

    final coveredIds = <String>{};
    for (final member in members) {
      coveredIds.add(member.recordId);
      coveredIds.addAll(view_.ledger.groupOf(member.recordId));
    }
    return _CkptRange(
      firstRecordId: members.first.recordId,
      lastRecordId: members.last.recordId,
      coveredRecordIds: coveredIds.toList()..sort(),
      state: view_.state,
      visible: view_.visible,
      seqs: view_.seqs,
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

  /// Summarizes one checkpoint range. Returns the summary text (`null` on
  /// failure-safety) together with the REAL number of summarizer calls the
  /// fold made — 0 for the deterministic marker-only consolidation
  /// (issue #387), 1 for a single in-window call, N for a #729 chunked
  /// fold — so pass receipts can report actual work instead of a hardcoded
  /// `1` (gh-2044 review thread 4).
  Future<({String? text, int summarizerCalls})> _summarizeRange(
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
      return (
        text:
            'Earlier records already hidden behind expand markers '
            '(${idsToRanges(coversSeqs)}) were consolidated here to bound '
            'marker overhead. Use compact_expand on any id to reopen a '
            'record.',
        summarizerCalls: 0,
      );
    }
    final openAsks = userRequestCandidateLines(
      messages,
      recordIds: [for (final record in rangeRecords) record.id],
    );
    // Identity map for chunk-scoped open asks (#729 E2): the whole-range
    // ask lines are #81-uncapped, so riding them in every chunk's envelope
    // can exceed the budget on its own. Each chunk carries only its own
    // asks; earlier ones survive through the threaded fold, which the
    // `<covers>` instruction tells to restate them.
    final askIdOf = <Message, String>{
      for (final record in rangeRecords)
        if (record.message.role == 'user') record.message: record.id,
    };
    List<String> asksFor(List<Message> chunk) => userRequestCandidateLines(
      [
        for (final m in chunk)
          if (askIdOf.containsKey(m)) m,
      ],
      recordIds: [
        for (final m in chunk)
          if (askIdOf.containsKey(m)) askIdOf[m]!,
      ],
    );

    String build(String conversation, List<String> asks, String? priorFold) {
      final prompt = StringBuffer()
        ..writeln('<conversation>')
        ..writeln(conversation)
        ..writeln('</conversation>')
        ..writeln(
          '<covers>The checkpoint replaces these expand ids: '
          '$coversRanges. List them in your summary.</covers>',
        );
      if (asks.isNotEmpty) {
        prompt
          ..writeln('<open-user-requests>')
          ..writeln(asks.join('\n'))
          ..writeln('</open-user-requests>');
      }
      // gh-1409 E7: the verbatim-preserve block rides every checkpoint
      // prompt (and every chunk of a chunked fold — `build` builds those
      // too), before the folded checkpoints it must not paraphrase over.
      if (pinnedOperativeBlock != null) {
        prompt
          ..writeln(pinnedOperativeBlock)
          ..writeln();
      }
      for (final folded in flattened) {
        prompt
          ..writeln('<folded-checkpoint>')
          // Issue #1131: older persisted checkpoints re-enter this prompt
          // verbatim — heal them so poison cannot be paraphrased forward.
          // gh-1409: pins inside heal protected (AC4).
          ..writeln(
            sanitizeSummary(folded.text, protectedLines: pinnedLines).text,
          )
          ..writeln('</folded-checkpoint>');
      }
      if (priorFold != null) {
        // Issue #729 chunked fold: the running summary of the chunks
        // summarized so far rides the same folded-checkpoint envelope the
        // depth-cap flattening uses.
        prompt
          ..writeln('<folded-checkpoint>')
          ..writeln(priorFold)
          ..writeln('</folded-checkpoint>');
      }
      prompt.writeln(checkpointPrompt);
      return prompt.toString();
    }

    final budget = summarizerWindow == null
        ? null
        : summarizationPayloadBudget(summarizerWindow!, settings);
    var prompt = build(serializeConversation(messages), openAsks, null);
    if (budget != null && estimateStringTokens(prompt) > budget) {
      // Issue #729: the dropped region does not fit the summarizer's
      // window — summarize chunk-wise and thread each chunk's summary into
      // the next, so the request that finally lands is bounded even when
      // the whole checkpoint range is not.
      return _chunkedFold(
        messages,
        build: build,
        asksFor: asksFor,
        budget: budget,
      );
    }
    final text = await _callSummarizer(prompt);
    return (text: text, summarizerCalls: 1);
  }

  /// The #729 chunked fold: splits [messages] into budget-sized chunks and
  /// folds them chunk-wise — each chunk's summary rides the next prompt via
  /// [priorFold] (`<folded-checkpoint>`), the last fold becomes the range
  /// summary. A summarizer failure mid-fold is failure-safe (`null`).
  Future<({String? text, int summarizerCalls})> _chunkedFold(
    List<Message> messages, {
    required String Function(
      String conversation,
      List<String> asks,
      String? priorFold,
    )
    build,
    required List<String> Function(List<Message> chunk) asksFor,
    required int budget,
  }) async {
    var priorFold = '';
    var calls = 0;
    final chunks = chunkSummarizableMessages(
      messages,
      max(budget - _checkpointEnvelopeReserveTokens, 256),
    );
    for (final chunk in chunks) {
      var conversation = serializeConversation(chunk);
      final empty = build('', const [], priorFold.isEmpty ? null : priorFold);
      final envelopeChars = empty.length - 1; // minus writeln('')'s newline
      conversation = truncateForSummaryBudget(
        conversation,
        budgetTokens: budget,
        envelopeChars: envelopeChars,
      );
      final text = await _callSummarizer(
        build(
          conversation,
          asksFor(chunk),
          priorFold.isEmpty ? null : priorFold,
        ),
      );
      calls++;
      if (text == null) return (text: null, summarizerCalls: calls);
      priorFold = text;
    }
    return (text: priorFold, summarizerCalls: calls);
  }

  /// One summarizer call under the attempt budget (issue #515). Returns
  /// the trimmed summary text, `null` on failure-safety (empty/failed).
  Future<String?> _callSummarizer(String prompt) async {
    try {
      final result =
          await summarize(
            SummarizationRequest(prompt: prompt, cancelToken: _effectiveToken),
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
      if (text == null || text.isEmpty) return null;
      // Issue #1131: checkpoints re-render every turn — strip ephemeral,
      // time-scoped claims the summarizer may have copied from context.
      // gh-1409 AC4: pin-carrying lines are exempt (the pin rides in the
      // envelope, structurally protected; raw lines protected here too).
      return sanitizeSummary(text, protectedLines: pinnedLines).text;
    } on TimeoutException {
      // A budget kill surfaces as a named error (issue #515) — the pass
      // loop must not dissolve it into the failure-safety null.
      rethrow;
    } catch (_) {
      return null;
    }
  }
}

/// Envelope reserve for a chunked checkpoint prompt (issue #729): tags,
/// covers line, open asks, folded checkpoints and the instruction tail.
/// The exact per-chunk fit is enforced by the measured envelope truncation
/// in [_summarizeRange]; this only sizes the chunk plan.
const _checkpointEnvelopeReserveTokens = 2048;

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
