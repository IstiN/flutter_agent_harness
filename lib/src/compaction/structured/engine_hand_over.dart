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
/// The reply's transfer text after the belt (think blocks and echo tags
/// out, gh-2103 origin evidence, the pinned lines protected); `null` for a
/// hide-only reply (E5) or an emptied transfer.
String? _sanitizedHandOverTransfer(
  StructuredCompactor c, {
  required HandOverReply reply,
  required RequestSnapshot snapshot,
}) {
  final raw = reply.transfer;
  if (raw == null || raw.trim().isEmpty) return null;
  final transfer = sanitizeSummary(
    stripRecordTags(stripThinkBlocks(raw)),
    protectedLines: c.pinnedLines,
    origins: SummaryOriginEvidence(snapshot.messages),
  ).text.trim();
  return transfer.isEmpty ? null : transfer;
}

/// gh-2411 follow-up #5 (owner live test, round 2): a transfer WITHOUT the
/// `## Open User Requests` heading gets ONE corrective retry. The heading
/// is the belt's grading basis, and a small model drops it — the whole
/// pass then failed with nothing appended ("the agent cannot make
/// progress until you switch models"). The retry re-sends the instruction
/// with a correction that names the section (and allows `- none` under it
/// when no request is open) and quotes the defective reply. One retry
/// only: a second miss — or a retry that cannot be made — keeps the
/// existing failure. A dropped ASK (heading present) is never retried.
Future<
  ({
    String? transfer,
    bool failed,
    HandOverReply reply,
    HandOverCallResult result,
  })
>
_handOverTransferWithRetry(
  StructuredCompactor c, {
  required HandOverCallResult result,
  required HandOverCall handOver,
  required RequestSnapshot snapshot,
  required String instruction,
  required List<String> openAsks,
  required void Function(Object error) fail,
}) async {
  final first = _handOverReply(result.response!);
  ({
    String? transfer,
    bool failed,
    HandOverReply reply,
    HandOverCallResult result,
  })
  settle(HandOverReply reply, HandOverCallResult result) {
    final settled = _handOverTransfer(
      c,
      reply: reply,
      snapshot: snapshot,
      openAsks: openAsks,
      fail: fail,
    );
    return (
      transfer: settled.transfer,
      failed: settled.failed,
      reply: reply,
      result: result,
    );
  }

  final sanitized = _sanitizedHandOverTransfer(
    c,
    reply: first,
    snapshot: snapshot,
  );
  final asks = sanitized == null
      ? null
      : verifyOpenUserRequests(sanitized, openAsks);
  if (asks == null || asks.heading) return settle(first, result);
  final quoted = (first.transfer ?? '').trim();
  final corrective =
      '$instruction\n\n'
      'CORRECTION — your previous reply carried no '
      '`## Open User Requests` section, so nothing could be graded or '
      'appended. Answer again with the complete hand-over. The transfer '
      'text MUST contain the heading `## Open User Requests`; under it '
      'list every open user request verbatim, or `- none` when none is '
      'open.\n\nYour previous reply was:\n'
      '${quoted.length > handOverRetryQuoteMaxChars ? quoted.substring(0, handOverRetryQuoteMaxChars) : quoted}';
  final HandOverCallResult retry;
  try {
    retry = await _callHandOver(
      c,
      handOver: handOver,
      snapshot: snapshot,
      instruction: corrective,
    );
  } on TimeoutException {
    rethrow;
  } on Object {
    // The retry could not be made: the first reply's defect stands.
    fail(CompactionException(_handOverAskFailure(asks)));
    return (transfer: null, failed: true, reply: first, result: result);
  }
  if (c._ladderTerminated) {
    return (transfer: null, failed: true, reply: first, result: result);
  }
  if (!retry.ok) {
    fail(CompactionException(_handOverAskFailure(asks)));
    return (transfer: null, failed: true, reply: first, result: result);
  }
  // The pass receipt carries the retry's result (the call that produced
  // the appended transfer); the first call's usage is not re-billed here.
  return settle(_handOverReply(retry.response!), retry);
}

/// The defective reply quoted into the corrective instruction is capped
/// (a runaway transfer must not double the retry's price).
const int handOverRetryQuoteMaxChars = 12000;

({String? transfer, bool failed}) _handOverTransfer(
  StructuredCompactor c, {
  required HandOverReply reply,
  required RequestSnapshot snapshot,
  required List<String> openAsks,
  required void Function(Object error) fail,
}) {
  final transfer = _sanitizedHandOverTransfer(
    c,
    reply: reply,
    snapshot: snapshot,
  );
  if (transfer == null) return (transfer: null, failed: false);
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
  required String runStatus,
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
    runStatus: runStatus,
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
  final transfer = await _handOverTransferWithRetry(
    c,
    result: result,
    handOver: handOver,
    snapshot: snapshot,
    instruction: instruction,
    openAsks: openAsks,
    fail: fail,
  );
  if (transfer.failed) return false;
  final verdict = _handOverVerdict(
    c,
    reply: transfer.reply,
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
      result: transfer.result,
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
  required String runStatus,
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
    runStatus: runStatus,
  );
}
