/// The emergency compaction tier (gh-209): deterministic mid-turn
/// over-window relief — seconds, bounded wall time, NO language model.
///
/// The mid-turn reliefs (the loop's over-window guard, gh-1680's
/// message-cap self-heal) used to invoke a FULL auto-compact run — judge
/// first. With a slow or unusable judge model class that turned an
/// in-turn context overflow into a long silent stall (the relief was a
/// declared "long silent window": structured ≤15 min + classic ≤15
/// min). This tier is what those reliefs run instead:
///
/// 1. **Dedup repeated reads** — an older `read` tool-result group for a
///    path folds into a marker when a NEWER successful read group of the
///    same path exists (the newest content is on the wire; the old copy
///    stays expandable).
/// 2. **Keep-N-recent per tool class** — the newest [EmergencyKeepRecent]
///    pair groups of each class stay live; older stalest-first groups are
///    hide candidates until the over-target amount is freed.
/// 3. **Local trim valve** — when the hides cannot free enough, the
///    mechanical in-memory trim (`localTrimValve`) bounds the live
///    context: keep the most recent `keepRecentTokens`, repair tool
///    pairing, prefix a `[context trimmed locally]` marker. In-memory
///    only — the session file keeps every record.
///
/// Invariants shared with the quality tier (the structured engine): the
/// hide writes ONLY `session.appendHiddenRange` records (lossless — every
/// id stays expandable behind its marker), whole pair groups hide
/// atomically (pair integrity, #85/D6), real user turns and the protected
/// tail and pinned expansions never hide (F8/#1379), and the state is
/// re-anchored from the session projection BEFORE any measurement
/// (gh-2097's basis rule).
///
/// Both tiers reuse the same machinery — the deterministic hide and the
/// trim valve already existed bundled behind the judge (issue #541);
/// this library unbundles them for the emergency path.
library;

import '../agent/agent.dart' show AgentState;
import '../context.dart';
import '../session/session_record.dart';
import '../session/session_tree.dart' show Session;
import '../types.dart';
import '../agent/auto_compactor.dart' show localTrimValve;
import 'compaction.dart' show CompactionSettings;
import 'token_estimation.dart' show estimateRequestTokens;
import 'structured/engine.dart' show classicTransform, refreshAgentState;
import 'structured/judge.dart' show hideProtectTailEntries;
import 'structured/ledger.dart';
import 'structured/projection.dart';

/// Keep-N-recent defaults per tool class (gh-209): the newest N pair
/// groups of a class survive the emergency hide; older ones are the
/// stalest-first hide candidates. Tuned conservatively — the quality
/// tier still runs at the turn boundary — and overridable per host via
/// [EmergencyRelief.keepRecent].
const Map<String, int> defaultEmergencyKeepRecent = {
  'read': 2,
  'exec': 4,
  'other': 8,
};

/// The tool class a tool name buckets into for the keep-N-recent hide
/// (gh-209): file-content reads (`read`/`ls`), shell executions
/// (`bash`/`bash_job`), everything else. Pure.
String emergencyToolClass(String toolName) => switch (toolName) {
  'read' || 'ls' || 'inspect_image' => 'read',
  'bash' || 'bash_job' => 'exec',
  _ => 'other',
};

/// One emergency-relief run's outcome — counts only, never content.
final class EmergencyReliefOutcome {
  const EmergencyReliefOutcome({
    required this.ok,
    required this.alreadyUnder,
    required this.tokensBefore,
    required this.tokensAfter,
    this.hiddenRecords = 0,
    this.hiddenGroups = 0,
    this.dedupedPaths = 0,
    this.usedTrimValve = false,
    this.droppedMessages = 0,
  });

  /// Whether the live context ended under the target (`alreadyUnder`
  /// counts as success — there was nothing to do).
  final bool ok;

  /// The run found the context already under the target and did nothing.
  final bool alreadyUnder;

  /// Estimated request tokens before the run (post-re-anchor basis).
  final int tokensBefore;

  /// Estimated request tokens after the run.
  final int tokensAfter;

  /// Records hidden behind markers this run (0 on the trim-only path).
  final int hiddenRecords;

  /// Pair groups folded this run.
  final int hiddenGroups;

  /// Read paths whose older duplicate folded (the dedup pass).
  final int dedupedPaths;

  /// Whether the local trim valve bounded the live context.
  final bool usedTrimValve;

  /// Messages the trim valve dropped from the live context (in-memory
  /// only — the session file keeps every record).
  final int droppedMessages;
}

/// The deterministic emergency tier over one session.
final class EmergencyRelief {
  /// Creates a relief over [session]/[state].
  EmergencyRelief({
    required this.session,
    required this.state,
    required this.window,
    required this.settings,
    this.protectLastN = hideProtectTailEntries,
    this.keepRecent = defaultEmergencyKeepRecent,
    this.ledgerCache,
  });

  /// The session to read the projection from and to append hides to.
  final Session session;

  /// The agent state whose [AgentState.messages] is replaced with the
  /// relieved transcript.
  final AgentState state;

  /// The model's context window in tokens.
  final int window;

  /// Compaction thresholds — the trim valve and the default target read
  /// them.
  final CompactionSettings settings;

  /// The live-edge floor: the newest [protectLastN] ledger entries never
  /// hide (the same constant every quality-tier hide path uses).
  final int protectLastN;

  /// Keep-N-recent per tool class (see [defaultEmergencyKeepRecent]).
  final Map<String, int> keepRecent;

  /// Optional shared ledger-entry memo (issue #1499). Scope it to ONE
  /// session like every other cache owner.
  final LedgerEntryCache? ledgerCache;

  /// The marker allowance subtracted from the WINDOW for the buster
  /// floor: a hidden record still rides the wire as a one-line marker,
  /// so the fold must land under the window WITH the marker counted
  /// (the same ~64-token allowance the trim valve reserves).
  static const int _trimMarkerAllowance = 64;

  /// The live request-size estimate in the ONE basis the ctx meter, the
  /// loop's over-window guard, and both compaction engines enforce.
  int _requestTokens() => estimateRequestTokens(
    state.messages,
    systemPrompt: state.systemPrompt,
    tools: state.tools,
  );

  /// Runs the tier. Returns the outcome; never throws for a healthy
  /// session (a broken projection degrades to the trim valve; a failed
  /// hide append leaves the transcript untouched and reports `ok:
  /// false`). Pure-local: no LM call is attempted on ANY path.
  Future<EmergencyReliefOutcome> run({int? targetTokens}) async {
    if (window <= 0) {
      return _outcome(alreadyUnder: true);
    }
    // gh-2097 basis rule: re-anchor the live transcript from the session
    // projection BEFORE any measurement — the in-memory tail can lag the
    // projection (an in-flight persist, a second writer), and the stale
    // basis under-sizes every step of the run.
    await refreshAgentState(session, state);
    final target =
        targetTokens ?? window - settings.reserveTokens;
    final before = _requestTokens();
    if (before <= target) {
      return _outcome(alreadyUnder: true);
    }

    final view = await _buildView();
    var ids = <String>{};
    var dedupedPaths = 0;
    if (view != null) {
      final over = before - target;
      // Pass 1 — dedup repeated reads of the same path (surgical first:
      // the newest successful content of each path is already on the
      // wire, so folding the older copies loses nothing).
      final dedup = _dedupReadCandidates(view);
      ids.addAll(dedup.ids);
      dedupedPaths = dedup.paths;
      // Pass 2 — keep-N-recent per tool class, stalest-first, until the
      // over-target amount is freed (the dedup candidates count toward
      // the freed budget). The freed accounting is NET of the marker
      // overhead: a hidden record still rides the wire as a one-line
      // marker, so the raw group weight overstates what a fold saves —
      // counting it gross would stop the walk early (still over the
      // target) and fall to the trim valve for nothing.
      var freed = 0;
      final tokensById = {
        for (final entry in view.ledger.entries) entry.recordId: entry.tokens,
      };
      // The buster floor: a single result that ALONE exceeds the WINDOW
      // (minus the marker allowance) makes its group a fold candidate
      // regardless of the class budgets — the request can never fit with
      // it, so folding it (marker-reopenable) is the only deterministic
      // recovery (gh-209). Keyed on the window, not the relief target:
      // a result merely over the target can still ride a valid request
      // and belongs to the valve/keep-N passes.
      final busterFloor = window - _trimMarkerAllowance;
      for (final candidate in _stalestFirstHideCandidates(
        view,
        dedup.ids,
        busterFloor: busterFloor,
      )) {
        if (freed >= over) break;
        final group = view.ledger.groupOf(candidate.$1);
        if (group.any(ids.contains)) continue;
        ids.addAll(group);
        freed += _netGroupTokens(view, tokensById, group);
      }
    }
    var hiddenRecords = 0;
    if (ids.isNotEmpty) {
      try {
        await session.appendHiddenRange(recordIds: ids.toList()..sort());
        hiddenRecords = ids.length;
      } on Object {
        // Failure-safety (the quality tier's contract): a failed append
        // writes nothing — the transcript is re-anchored unchanged and
        // only the trim valve may still bound it.
        hiddenRecords = 0;
        dedupedPaths = 0;
      }
      await refreshAgentState(session, state);
    }
    var after = _requestTokens();
    var usedTrimValve = false;
    var dropped = 0;
    if (after > target) {
      final trimmed = localTrimValve(
        messages: state.messages,
        reason: 'the emergency relief could not free enough context '
            '(no model call is attempted here)',
        window: window,
        settings: settings,
        overheadTokens: estimateRequestTokens(
          const [],
          systemPrompt: state.systemPrompt,
          tools: state.tools,
        ),
      );
      if (trimmed != null) {
        state.messages = trimmed.messages;
        usedTrimValve = true;
        dropped = trimmed.dropped;
        after = _requestTokens();
      }
    }
    return EmergencyReliefOutcome(
      ok: after <= target,
      alreadyUnder: false,
      tokensBefore: before,
      tokensAfter: after,
      hiddenRecords: hiddenRecords,
      hiddenGroups: _groupCount(view, ids),
      dedupedPaths: dedupedPaths,
      usedTrimValve: usedTrimValve,
      droppedMessages: dropped,
    );
  }

  EmergencyReliefOutcome _outcome({required bool alreadyUnder}) =>
      EmergencyReliefOutcome(
        ok: alreadyUnder,
        alreadyUnder: alreadyUnder,
        tokensBefore: _requestTokens(),
        tokensAfter: _requestTokens(),
      );

  /// The group's NET wire saving: the records' ledger weight minus what
  /// their one-line markers will cost once hidden (issue #387's
  /// projection rule — hidden records render at marker size).
  int _netGroupTokens(
    _LedgerView view,
    Map<String, int> tokensById,
    Set<String> group,
  ) {
    var gross = 0;
    var markers = 0;
    for (final id in group) {
      gross += tokensById[id] ?? 0;
      final seq = view.seqs.seqOf(id);
      final record = seq == null ? null : view.seqs.recordAt(seq);
      if (record == null || seq == null) continue;
      markers += hiddenMarkerTokens(record, seq);
    }
    final net = gross - markers;
    return net > 0 ? net : 0;
  }

  int _groupCount(_LedgerView? view, Set<String> ids) {
    if (view == null || ids.isEmpty) return 0;
    final groups = <String>{};
    for (final id in ids) {
      groups.add(view.carrierOf[id] ?? id);
    }
    return groups.length;
  }

  Future<_LedgerView?> _buildView() async {
    final path = classicTransform(await session.getBranch());
    final viewState = buildStructuredViewState(path);
    final visible = visibleStructuredPath(path, viewState);
    if (visible.isEmpty) return null;
    final seqs = RecordSeqIndex(await session.getEntries());
    return _LedgerView._(
      buildContextLedger(
        visiblePath: visible,
        seqs: seqs,
        cache: ledgerCache,
      ),
      viewState,
      seqs,
      path,
    );
  }

  /// The dedup candidates (pass 1): for every READ-class path seen more
  /// than once among the visible tool groups, the older groups fold —
  /// the newest SUCCESSFUL group of the path stays live. A group whose
  /// newest result failed never relieves its older successful copies
  /// (hiding them would lose the only good content), and every shared
  /// safety veto (exempt, protected tail, pinned) applies per group.
  ({Set<String> ids, int paths}) _dedupReadCandidates(_LedgerView view) {
    final byPath = <String, List<_ToolGroup>>{};
    for (final group in _toolGroups(view)) {
      for (final key in group.dedupKeys) {
        byPath.putIfAbsent(key, () => []).add(group);
      }
    }
    final protectedTail = protectedTailIds(view.ledger, protectLastN);
    final pinned = view.state.pinnedRecordIds;
    final ids = <String>{};
    var paths = 0;
    for (final entry in byPath.entries) {
      final groups = entry.value;
      if (groups.length <= 1) continue;
      // The keeper: the NEWEST group with a successful result.
      var keeper = -1;
      for (var i = groups.length - 1; i >= 0; i--) {
        if (groups[i].hasSuccessfulResult) {
          keeper = i;
          break;
        }
      }
      if (keeper <= 0) continue; // nothing older to fold (or no success).
      var foldedAny = false;
      for (var i = 0; i < keeper; i++) {
        final group = groups[i];
        if (group.vetoed(protectedTail, pinned)) continue;
        ids.addAll(group.recordIds);
        foldedAny = true;
      }
      if (foldedAny) paths++;
    }
    return (ids: ids, paths: paths);
  }

  /// The keep-N-recent hide candidates (pass 2), STALEST FIRST: every
  /// tool group whose class has more live groups than its keep budget,
  /// older before newer. A group is kept when it sits within the newest
  /// [keepRecent] of ANY class it touches (a mixed-call group survives
  /// if one of its classes still has budget). The already-deduped ids
  /// never re-count.
  ///
  /// Buster rule (gh-209): a group whose HEAVIEST single result alone
  /// busts [busterFloor] is a candidate regardless of its class budget —
  /// and regardless of the protected tail (a result that alone overflows
  /// the window is the exact "biggest tool result" the tier exists for;
  /// the marker keeps it reopenable). Pinned expansions still veto it:
  /// an expand the model is reading must never fold under it.
  List<(String, int)> _stalestFirstHideCandidates(
    _LedgerView view,
    Set<String> dedupedIds, {
    required int busterFloor,
  }) {
    final groups = _toolGroups(view).reversed.toList(); // newest first
    final perClassNewest = <String, int>{};
    final candidates = <(String, int)>[];
    final protectedTail = protectedTailIds(view.ledger, protectLastN);
    final pinned = view.state.pinnedRecordIds;
    for (final group in groups) {
      if (group.recordIds.any(dedupedIds.contains)) continue;
      final buster =
          busterFloor > 0 && group.heaviestResult >= busterFloor;
      if (buster) {
        if (group.vetoed(const {}, pinned)) continue;
      } else if (group.vetoed(protectedTail, pinned)) {
        continue;
      }
      var kept = false;
      for (final class_ in group.classes) {
        final index = perClassNewest.putIfAbsent(class_, () => 0);
        perClassNewest[class_] = index + 1;
        if (index < (keepRecent[class_] ?? keepRecent['other'] ?? 8)) {
          kept = true;
        }
      }
      if (!kept || buster) {
        candidates.add((group.carrierId, group.tokens));
      }
    }
    return candidates.reversed.toList(); // stalest first
  }
}

/// One visible tool-call pair group (carrier + results) seen by the
/// emergency tier.
final class _ToolGroup {
  const _ToolGroup({
    required this.carrierId,
    required this.recordIds,
    required this.tokens,
    required this.classes,
    required this.dedupKeys,
    required this.hasSuccessfulResult,
    required this.heaviestResult,
  });

  final String carrierId;

  /// Every record id of the pair group — hides atomically (D6).
  final Set<String> recordIds;

  /// The group's estimated token weight.
  final int tokens;

  /// The tool classes the group's calls touch.
  final Set<String> classes;

  /// The dedup keys (normalized read paths) the group carries, if any.
  final Set<String> dedupKeys;

  /// Whether at least one result of the group succeeded (`isError:
  /// false`). A group with only failures is never a dedup keeper.
  final bool hasSuccessfulResult;

  /// The heaviest SINGLE result record of the group (tokens). A result
  /// that alone busts the relief target is a fold candidate regardless
  /// of the class budgets (gh-209 buster rule) — one ballooned tool
  /// output must not be unrecoverable just because it is the only one.
  final int heaviestResult;

  /// The shared safety veto: the protected tail, a pinned expansion, or
  /// an exempt (real user) record in the group — all-or-none.
  bool vetoed(Set<String> protectedTail, Set<String> pinnedRecordIds) {
    for (final id in recordIds) {
      if (protectedTail.contains(id) || pinnedRecordIds.contains(id)) {
        return true;
      }
    }
    return false;
  }
}

/// Collects the visible tool groups oldest-first: every visible
/// assistant carrier of a tool call as its whole pair group, with its
/// classes, dedup keys (read paths), token weight and success flag.
/// A carrier with no result yet is skipped (hiding it would orphan a
/// live call on the wire, #85).
List<_ToolGroup> _toolGroups(_LedgerView view) {
  final byId = {for (final record in view.path) record.id: record};
  final result = <_ToolGroup>[];
  final seenCarriers = <String>{};
  for (final record in view.path) {
    final message = record is MessageRecord ? record.message : null;
    if (message is! AssistantMessage) continue;
    if (view.state.hiddenRecordIds.contains(record.id)) continue;
    if (view.state.isCovered(record.id)) continue;
    final calls = message.content.whereType<ToolCall>().toList();
    if (calls.isEmpty) continue;
    final group = view.ledger.groupOf(record.id);
    if (seenCarriers.overlaps(group)) continue; // shared group, seen once.
    seenCarriers.addAll(group);
    final (tokens, hasResult, hasSuccess, heaviest) = _groupWeight(
      view,
      byId,
      group,
    );
    // An unanswered carrier is not relief food (#85 pair integrity).
    if (!hasResult) continue;
    final classes = <String>{
      for (final call in calls)
        emergencyToolClass(call.name),
    };
    final dedupKeys = <String>{
      for (final call in calls)
        if (emergencyToolClass(call.name) == 'read')
          ...?_readDedupKey(call.arguments),
    };
    result.add(
      _ToolGroup(
        carrierId: record.id,
        recordIds: group,
        tokens: tokens,
        classes: classes,
        dedupKeys: dedupKeys,
        hasSuccessfulResult: hasSuccess,
        heaviestResult: heaviest,
      ),
    );
  }
  return result;
}

/// The group's token weight, whether a result rode along, whether any
/// of those results succeeded, and the heaviest single result's weight.
(int, bool, bool, int) _groupWeight(
  _LedgerView view,
  Map<String, SessionRecord> byId,
  Set<String> group,
) {
  var tokens = 0;
  var hasResult = false;
  var hasSuccess = false;
  var heaviest = 0;
  for (final id in group) {
    final other = byId[id];
    if (other is! MessageRecord) continue;
    final message = other.message;
    if (message is ToolResultMessage) {
      hasResult = true;
      if (!message.isError) hasSuccess = true;
    }
    final seq = view.seqs.seqOf(id);
    if (seq != null) {
      final weight = view.ledger.entryAtSeq(seq)?.tokens ?? 0;
      tokens += weight;
      if (message is ToolResultMessage && weight > heaviest) {
        heaviest = weight;
      }
    }
  }
  return (tokens, hasResult, hasSuccess, heaviest);
}

/// The dedup key of a read-class call: its `path` argument (the ONE
/// argument every read-class builtin shares). Null when absent/empty —
/// such a group never dedups (it may not be a path-keyed read at all).
Set<String>? _readDedupKey(Map<Object?, Object?> arguments) {
  final path = arguments['path'];
  if (path is! String || path.isEmpty) return null;
  return {_normalizePath(path)};
}

/// Normalizes a read path for dedup matching: a leading `./` is stripped
/// (the same file read both ways must dedup). Pure.
String _normalizePath(String path) {
  var normalized = path;
  while (normalized.startsWith('./')) {
    normalized = normalized.substring(2);
  }
  return normalized;
}

extension _SetOverlap<X> on Set<X> {
  bool overlaps(Set<X> other) => any(other.contains);
}

/// The ledger view the emergency tier walks (mirrors the structured
/// engine's internal view — same projection basis, no judge).
final class _LedgerView {
  const _LedgerView._(
    this.ledger,
    this.state,
    this.seqs,
    this.path,
  );

  final ContextLedger ledger;
  final StructuredViewState state;
  final RecordSeqIndex seqs;

  /// The whole (post-classic-transform) branch path: visible AND hidden
  /// records — the tool-group walk reads hidden/covered knowledge.
  final List<SessionRecord> path;

  /// record id -> its pair-group carrier (itself when not grouped).
  Map<String, String> get carrierOf {
    final map = <String, String>{};
    for (final entry in ledger.entries) {
      map[entry.recordId] = ledger.groupOf(entry.recordId).first;
    }
    return map;
  }
}
