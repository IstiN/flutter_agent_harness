// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// The merged hand-over pass of the structured engine (GOAL #2394 — the
/// `merged` mode of `selectCompactionMode`). ONE model call over the S0
/// prefix (the last main request as sent) plus the appended instruction
/// answers BOTH questions of a run — which records outside the fold range
/// are safe to hide, and the transfer text for the range — and the engine
/// DISPOSES over the answer:
///
/// - hide aliases resolve against the SNAPSHOT index (never a fresh
///   ledger — aliases drift under windowed storage and hard caps) and are
///   validated against the fresh projection (`disposeHidePicks`: snap to
///   pair groups, user turns never hidden, tail/pins, covered/in-range,
///   fold records);
/// - the transfer text must carry the mandatory `## Open User Requests`
///   section with every mechanical ask line verbatim (D2/#81), and is
///   persisted through the gh-2103 sanitizer with the S0 origin evidence
///   and the pinned lines protected;
/// - the hidden range rides ONE record (`labels`, `consolidated: true`)
///   and the checkpoint rides its own record (`layout: tail`).
///
/// No fallback: a failed call, an unusable reply or a failed check appends
/// NOTHING (I5) and reports loudly — the engine never changes (I9). No
/// second call on the new projection (E21): residual pressure is the next
/// prompt's pre-flight business (the host's hysteresis keeps the band
/// quiet for N turns).
part of 'engine.dart';

/// The merged hand-over pass's report metrics (GOAL #2394 AC14): the mode,
/// the bucket, the REAL round-trip count and the hide list's buckets. A
/// provider that reports no usage leaves [cacheHitRatio] `null` — never a
/// fake zero (gh-2097).
final class HandOverPassMetrics {
  /// Creates the metrics.
  const HandOverPassMetrics({
    required this.bucket,
    required this.calls,
    required this.nudges,
    required this.budgetRetries,
    required this.hideList,
    required this.transfer,
    this.cacheHitRatio,
  });

  /// The mode the run chose — always `merged` for this pass.
  static const String mode = 'merged';

  /// `warm` while the S0 bucket's TTL held at call time, else `cold` (a
  /// signal, never a condition — E11).
  final String bucket;

  /// Real round-trips the logical call consumed (nudge and budget retry
  /// included).
  final int calls;

  /// Nudge round-trips (0 or 1).
  final int nudges;

  /// Output-budget retries (0 or 1).
  final int budgetRetries;

  /// The hide list's buckets as the report renders them
  /// (`HandOverDisposeVerdict.render`); `none` when the reply proposed
  /// nothing.
  final String hideList;

  /// `text` when a transfer text was persisted, `none` for a hide-only
  /// reply (E5).
  final String transfer;

  /// Share of input tokens served from cache across the call, `null`
  /// when the provider reported no usage.
  final double? cacheHitRatio;

  /// The one-line report form: `merged · bucket warm · calls 1 · cache
  /// 92% · hide list 2 snapped · nudges 0 · budget retries 0 · transfer
  /// text` (the cache term is omitted without usage).
  String render() => [
    mode,
    'bucket $bucket',
    'calls $calls',
    if (cacheHitRatio != null) 'cache ${(cacheHitRatio! * 100).round()}%',
    'hide list ${hideList == '' ? 'none' : hideList}',
    'nudges $nudges',
    'budget retries $budgetRetries',
    'transfer $transfer',
  ].join(' · ');
}

/// The pass's gate + fold range: `null` when the run ends here with the
/// verdict `true` — an honest decline ([StructuredCompactor.exitReason]
/// names it) — or `false` after a ladder kill. The gate is waived by
/// `force` or by the host's soft arm ([softTriggered], AC11).
Future<({_LedgerView view, _CkptRange range})?> _handOverRange(
  StructuredCompactor c, {
  required int trigger,
  required bool force,
  required bool softTriggered,
}) async {
  final before = c._requestTokens();
  if (!force && !softTriggered && before <= trigger) {
    c.exitReason = 'basis $before below trigger $trigger (hand-over gate)';
    return null;
  }
  if (c._ladderTerminated) return null;
  final view = await c._buildView();
  if (view == null) {
    c.exitReason = 'projection view unavailable (hand-over gate)';
    return null;
  }
  final range = await c._pickCheckpointRange(
    view: view,
    wholeWorldDeclines: false,
  );
  if (range == null) {
    c.exitReason =
        'no foldable range below the keep-recent boundary (hand-over gate)';
  }
  return range == null ? null : (view: view, range: range);
}

/// ONE logical call = at most three round-trips (nudge, budget retry)
/// under the tripled attempt budget; the budget kill is the factory's
/// outcome (issue #515) and must not dissolve into the failure-safety
/// false — it rethrows.
Future<HandOverCallResult> _callHandOver(
  StructuredCompactor c, {
  required HandOverCall handOver,
  required RequestSnapshot snapshot,
  required String instruction,
}) {
  final budget = c.attemptBudget * 3;
  return handOver(
    snapshot.toContext(extraMessages: [UserMessage.text(instruction)]),
    cancelToken: c._effectiveToken,
  ).timeout(
    budget,
    onTimeout: () {
      final timeout = c._budgetTimeout('hand-over call', budget);
      c.budgetSource?.cancel(timeout);
      throw timeout;
    },
  );
}

/// The reply's transfer text — sanitized (think blocks and echo tags
/// out, the gh-2103 belt with the S0 origin evidence, the pinned lines
/// protected) and verified against the mechanical asks. `null` for a
/// hide-only reply (E5); [failed] when the check failed (nothing may be
/// appended, the pass reported its failure through [fail]).
({String? transfer, bool failed}) _handOverTransfer(
  StructuredCompactor c, {
  required HandOverReply reply,
  required RequestSnapshot snapshot,
  required List<String> openAsks,
  required void Function(Object error) fail,
}) {
  final raw = reply.transfer;
  if (raw == null || raw.trim().isEmpty) return (transfer: null, failed: false);
  var transfer = sanitizeSummary(
    stripRecordTags(stripThinkBlocks(raw)),
    protectedLines: c.pinnedLines,
    origins: SummaryOriginEvidence(snapshot.messages),
  ).text.trim();
  if (transfer.isEmpty) return (transfer: null, failed: false);
  final asks = verifyOpenUserRequests(transfer, openAsks);
  if (!asks.heading || asks.missing.isNotEmpty) {
    fail(CompactionException(_handOverAskFailure(asks)));
    return (transfer: null, failed: true);
  }
  return (transfer: transfer, failed: false);
}

String _handOverAskFailure(({bool heading, List<String> missing}) asks) =>
    !asks.heading
    ? 'hand-over transfer carries no `## Open User Requests` '
          'section — the sanitizer belt cannot grade it; nothing '
          'was appended'
    : 'hand-over transfer dropped ${asks.missing.length} '
          'open user request(s) from <open-user-requests>; '
          'nothing was appended';

/// Disposes the reply's hide list against the FRESH projection (snap to
/// pair groups, user turns never hidden, tail/pins, covered/in-range,
/// fold records — the SNAPSHOT index resolves the aliases).
HandOverDisposeVerdict _handOverVerdict(
  StructuredCompactor c, {
  required HandOverReply reply,
  required RequestSnapshot snapshot,
  required _LedgerView view,
  required _CkptRange range,
}) {
  final foldFrom = view.seqs.seqOf(range.firstRecordId) ?? 0;
  final foldTo = view.seqs.seqOf(range.lastRecordId) ?? foldFrom;
  return disposeHidePicks(
    picks: reply.picks,
    snapshotIndex: snapshot.seqMap.index,
    ledger: view.ledger,
    state: view.state,
    protectedTail: protectedTailIds(view.ledger, c.protectLastN),
    foldFromSeq: foldFrom,
    foldToSeq: foldTo,
    inRangeSeqs: {
      for (final id in range.coveredRecordIds) ?view.seqs.seqOf(id),
    },
  );
}

/// Appends the run's records — the consolidated hidden range first, then
/// the tail-layout checkpoint. `false` after a ladder kill (written-but-
/// unprojected stops here; resume replays it).
Future<bool> _appendHandOverRecords(
  StructuredCompactor c, {
  required HandOverDisposeVerdict verdict,
  required _CkptRange range,
  required String? transfer,
}) async {
  if (verdict.recordIds.isNotEmpty) {
    await c.session.appendHiddenRange(
      recordIds: verdict.recordIds,
      labels: verdict.labels,
      consolidated: true,
    );
    if (c._ladderTerminated) return false;
  }
  if (transfer == null) return true;
  await c.session.appendCompactCheckpoint(
    firstRecordId: range.firstRecordId,
    lastRecordId: range.lastRecordId,
    text: transfer,
    coversRecordIds: range.coveredRecordIds,
    flattenedRecordIds: [
      for (final ckpt in c._flattenForDepthCap(range)) ckpt.id,
    ],
    layout: compactCheckpointLayoutTail,
  );
  return !c._ladderTerminated;
}

int _summarizedCount(_CkptRange range) {
  var count = 0;
  for (final id in range.coveredRecordIds) {
    final seq = range.seqs.seqOf(id);
    if (seq != null && range.seqs.recordAt(seq) is MessageRecord) count++;
  }
  return count;
}

HandOverReply _handOverReply(AssistantMessage response) => parseHandOverReply(
  [
    for (final block in response.content)
      if (block is TextContent) block.text,
  ].join('\n'),
);

StructuredCompactionPass _handOverPassReport(
  StructuredCompactor c, {
  required HandOverCallResult result,
  required HandOverDisposeVerdict verdict,
  required RequestSnapshot snapshot,
  required int before,
  required int after,
  required String? transfer,
  required int summarizedCount,
  required int durationMs,
  required CompactionUsageTotals? usage,
}) => StructuredCompactionPass(
  kind: 'hand-over',
  pass: ++c._pass,
  tokensBefore: before,
  tokensAfter: after,
  ok: true,
  judgeCalls: result.calls,
  hiddenCount: verdict.recordIds.length,
  summarizedCount: summarizedCount,
  summary: transfer,
  basisReadTokens: c._basisFlip(before, after),
  durationMs: durationMs,
  usage: usage,
  handOver: HandOverPassMetrics(
    bucket: snapshot.bucket(),
    calls: result.calls,
    nudges: result.nudges,
    budgetRetries: result.budgetRetries,
    hideList: verdict.render(),
    transfer: transfer == null ? 'none' : 'text',
    cacheHitRatio: result.cacheHitRatio,
  ),
);

/// Runs the merged hand-over pass for [c]. Returns whether the run's
/// verdict stands: `true` when the pass appended (or honestly declined
/// through [StructuredCompactor.exitReason]), `false` only on a failure
/// — a failed call, an unusable reply, a failed ask check, a ladder kill.
/// [softTriggered] waives the hard trigger gate: the host measured the
/// post-run soft line (AC11) and armed this run itself.
Future<bool> _runHandOverPass(
  StructuredCompactor c, {
  required int trigger,
  required bool force,
  required bool softTriggered,
}) async {
  final handOver = c.handOver!;
  final snapshot = c.requestSnapshot!;
  final before = c._requestTokens();
  final armed = await _handOverRange(
    c,
    trigger: trigger,
    force: force,
    softTriggered: softTriggered,
  );
  if (armed == null) return !c._ladderTerminated;
  if (c._ladderTerminated) return false;
  final watch = Stopwatch()..start();
  final usageBefore = c.usage?.snapshot();
  final openAsks = _handOverOpenAsks(armed.range);
  final instruction = _handOverInstruction(
    c,
    view: armed.view,
    range: armed.range,
    openAsks: openAsks,
    contextTokens: before,
  );
  if (c._ladderTerminated) return false;
  final HandOverCallResult result;
  try {
    result = await _callHandOver(
      c,
      handOver: handOver,
      snapshot: snapshot,
      instruction: instruction,
    );
  } on TimeoutException {
    rethrow;
  }
  // #2258: the verdict may have landed while the call ran — nothing is
  // appended, refreshed or reported after it.
  if (c._ladderTerminated) return false;
  void fail(Object error) => c.hooks?.onPass(
    StructuredCompactionPass(
      kind: 'hand-over',
      pass: ++c._pass,
      tokensBefore: before,
      tokensAfter: before,
      ok: false,
      error: error,
      durationMs: watch.elapsedMilliseconds,
      usage: c._usageDelta(usageBefore),
    ),
  );
  if (!result.ok) {
    fail(
      result.failure ??
          const CompactionException('hand-over call returned no answer'),
    );
    return false;
  }
  final reply = _handOverReply(result.response!);
  final transfer = _handOverTransfer(
    c,
    reply: reply,
    snapshot: snapshot,
    openAsks: openAsks,
    fail: fail,
  );
  if (transfer.failed) return false;
  final verdict = _handOverVerdict(
    c,
    reply: reply,
    snapshot: snapshot,
    view: armed.view,
    range: armed.range,
  );
  if (!await _appendHandOverRecords(
    c,
    verdict: verdict,
    range: armed.range,
    transfer: transfer.transfer,
  )) {
    return false;
  }
  final after = await c._refreshState();
  c.hooks?.onPass(
    _handOverPassReport(
      c,
      result: result,
      verdict: verdict,
      snapshot: snapshot,
      before: before,
      after: after,
      transfer: transfer.transfer,
      summarizedCount: transfer.transfer == null
          ? 0
          : _summarizedCount(armed.range),
      durationMs: watch.elapsedMilliseconds,
      usage: c._usageDelta(usageBefore),
    ),
  );
  return true;
}

/// The mechanical `<open-user-requests>` ground truth of the fold range:
/// the same #81 extraction the standalone checkpoint prompt rides.
List<String> _handOverOpenAsks(_CkptRange range) => userRequestCandidateLines(
  [
    for (final record in range.visible)
      if (range.coveredRecordIds.contains(record.id) &&
          record is MessageRecord &&
          record.message.role == 'user')
        record.message,
  ],
  recordIds: [
    for (final record in range.visible)
      if (range.coveredRecordIds.contains(record.id) &&
          record is MessageRecord &&
          record.message.role == 'user')
        record.id,
  ],
);

/// The appended instruction (AC3/AC6): the prompt template with the
/// pressure, the fold range aliases, the tag rule, the mechanical asks,
/// the pinned-operative block and the depth-cap `<folded-checkpoint>`
/// blocks (sanitized — older persisted checkpoints re-enter a prompt
/// healed, issue #1131; pins inside them protected, gh-1409).
String _handOverInstruction(
  StructuredCompactor c, {
  required _LedgerView view,
  required _CkptRange range,
  required List<String> openAsks,
  required int contextTokens,
}) {
  final folded = [
    for (final ckpt in c._flattenForDepthCap(range))
      '<folded-checkpoint>\n'
          '${sanitizeSummary(ckpt.text, protectedLines: c.pinnedLines).text}'
          '\n</folded-checkpoint>',
  ];
  return renderHandOverInstruction(
    template: c.handOverPrompt,
    contextTokens: contextTokens,
    windowTokens: c.window,
    foldFrom: view.seqs.seqOf(range.firstRecordId) ?? 0,
    foldTo: view.seqs.seqOf(range.lastRecordId) ?? 0,
    openUserRequests: openAsks,
    pinnedOperative: c.pinnedOperativeBlock,
    foldedCheckpoints: folded.isEmpty ? null : folded.join('\n'),
  );
}
