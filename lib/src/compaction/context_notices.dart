// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Honest context notices (issue #2423, C3): what the harness tells the
/// model about its own context — in the harness's numbers, never the
/// model's guess.
///
/// The audit behind the card: a hide-only compaction freed 131k tokens
/// and said nothing; 76 s later the worker wrote "I am near my context
/// limit again" and asked for a fresh worker — on a 54k context. The
/// model cannot estimate its own context and does not need to: the
/// harness knows the estimate (X) and the one window (W) — it just never
/// said so.
///
/// - [postHideContextNotice] — exactly one per hide pass, delivered
///   BEFORE the next request: N records hidden, the context now (X) and
///   before (Y), and that the working set is pinned — or, with no
///   snapshot yet, the fix (`working_set(text)`).
/// - [nearLimitContextNotice] — once per compaction cycle, when the
///   pre-request estimate reaches [nearLimitThresholdTokens] (85 % of the
///   window, always below the trigger with a runway): update the working
///   set, then KEEP WORKING.
/// - [ContextNoticeLatch] — the once-per-cycle arm/re-arm state (re-armed
///   by every hide; one latch per session).
///
/// Pure and host-independent: the CLI, the task executor and every host
/// emit the same text. A notice is a SYNTHETIC user record — it rides the
/// `<system-notice>` envelope, so every classifier reads it as machine
/// content (never a pinned real user turn, never an obligation). The
/// numbers are the harness's: the estimate is printed with `≈` (F3) and
/// the texts never contain a "limit" phrase (I6, pinned by
/// [contextNoticeForbiddenPhrases]).
library;

import '../session/session_record.dart'
    show
        CompactCheckpointRecord,
        CompactionRecord,
        HiddenRangeRecord,
        MessageRecord,
        SessionRecord;
import 'compaction.dart' show CompactionSettings;

/// Phrases no context notice may contain (I6). The audit's failure mode
/// was the model's own "near my context limit again": the harness must
/// never hand it that sentence.
const List<String> contextNoticeForbiddenPhrases = [
  'at the limit',
  'context limit',
  'out of context',
  'cannot continue',
];

/// The near-limit ratio of the window (owner default): 0.85.
const int nearLimitPercent = 85;

/// The minimum runway (tokens) kept between the near-limit point and the
/// hide trigger, so the model always gets the notice BEFORE the fold:
/// `max(2,000, 5 % of the window)`.
const int nearLimitMinRunwayTokens = 2000;

/// The envelope of every notice: a `<system-notice>` anywhere in the text
/// ⇒ synthetic (`isSyntheticUserText`).
String contextNoticeEnvelope(String line) =>
    '<system-notice>\n$line\n</system-notice>';

const _noticeEnvelopeOpen = '<system-notice>';
const _noticeEnvelopeClose = '</system-notice>';

/// The opening words of the post-hide notice ([postHideNoticeLine]).
const postHideNoticePrefix = 'compacted: ';

/// The opening words of the near-limit notice ([nearLimitNoticeLine]) —
/// the `≈` marks the percent as a heuristic figure (an exact,
/// provider-reported figure drops it; see [nearLimitNoticeLine]).
const nearLimitNoticePrefix = 'context ≈';

/// The opening words of the near-limit notice built from an EXACT,
/// provider-reported figure.
const nearLimitReportedPrefix = 'context ';

/// The shape of a near-limit body under either provenance: `context [≈]P%
/// ([≈]X/W): ` — the precise classifier's second half.
final _nearLimitBody = RegExp(r'^context (≈)?\d+% \((≈)?\d+/\d+\): ');

/// The provenance marker of a heuristic context figure. Owner rule
/// (2026-11-25): tokens are never counted differently in different
/// places — a heuristic number is marked as one everywhere it is shown,
/// and an exact number is shown only when a provider reported it. Every
/// notice figure today is the harness's pre-request ESTIMATE
/// (`estimateRequestTokens` on the compaction trigger's basis): no
/// provider reports the size of a request that was not sent yet. The
/// builders take that as ONE flag per line ([estimated]); the shared
/// context-usage source of truth (gh-2394 follow-up) re-points the
/// callers and flips it.
const estimateMark = '≈';

/// Whether [text] is a gh-2423 context notice record — the
/// [contextNoticeEnvelope] around a post-hide or near-limit line. The
/// precise classifier: every notice is synthetic user text
/// (`isSyntheticUserText`), but the other `<system-notice>` records
/// (compaction carriers, steering receipts, job notices) are NOT context
/// notices and keep their own handling.
bool isContextNoticeText(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith(_noticeEnvelopeOpen)) return false;
  final body = trimmed
      .substring(_noticeEnvelopeOpen.length)
      .replaceAll(_noticeEnvelopeClose, '')
      .trim();
  return body.startsWith(postHideNoticePrefix) || _nearLimitBody.hasMatch(body);
}

/// Whether [text] contains any [contextNoticeForbiddenPhrases] entry
/// (case-insensitive).
bool containsForbiddenContextPhrase(String text) {
  final lower = text.toLowerCase();
  return contextNoticeForbiddenPhrases.any(lower.contains);
}

/// The runway kept between the near-limit point and the hide trigger:
/// `max([nearLimitMinRunwayTokens], 5 % of the window)`.
int nearLimitRunwayTokens(int window) {
  final proportional = window > 0 ? window ~/ 20 : 0;
  return proportional > nearLimitMinRunwayTokens
      ? proportional
      : nearLimitMinRunwayTokens;
}

/// The near-limit point of a [window] under [settings]:
/// `min(0.85·W, trigger − max(2,000, 0.05·W))` — the lower of 85 % of the
/// window and the trigger minus the runway — always BELOW the hide
/// trigger (`window − reserveTokens`) with a runway, so the notice
/// reaches the model while a fold is still avoidable. 200k window →
/// 170k; 32k window with an 8k reserve → 22k. 0 for an unknown window.
int nearLimitThresholdTokens({
  required int window,
  required CompactionSettings settings,
}) {
  if (window <= 0) return 0;
  final trigger = window - settings.reserveTokens;
  final belowTrigger = trigger - nearLimitRunwayTokens(window);
  var threshold = (window * nearLimitPercent) ~/ 100;
  if (belowTrigger < threshold) threshold = belowTrigger;
  return threshold < 0 ? 0 : threshold;
}

/// Whether a pre-request estimate of [tokens] reached the near-limit
/// point of [window] under [settings]. Disabled compaction settings and
/// an unknown window never reach it (nothing honest to say). Neither
/// does an estimate AT OR OVER the hide trigger (`window −
/// reserveTokens`): there the hide runs next and its own post-hide
/// notice is the honest message — a "will fold older records" heads-up
/// about a context that already crossed the line would be late news.
bool nearLimitReached({
  required int tokens,
  required int window,
  required CompactionSettings settings,
}) {
  if (!settings.enabled) return false;
  final threshold = nearLimitThresholdTokens(
    window: window,
    settings: settings,
  );
  if (threshold <= 0 || tokens < threshold) return false;
  return tokens < window - settings.reserveTokens;
}

/// Whether [entry] is a hide record under ANY of the three mechanisms:
/// the classic `hidden_range` record, the structured engine's
/// `compact_checkpoint` (issue #148: a checkpoint replaces the records it
/// covers with its text — a hide by another name), or the legacy
/// `compaction` summary boundary (the classic engine: the summary
/// replaces everything before its first kept record).
bool isHideRecord(SessionRecord entry) =>
    entry is HiddenRangeRecord ||
    entry is CompactCheckpointRecord ||
    entry is CompactionRecord;

/// The hide-record ids of [entries] — the snapshot a caller takes
/// BEFORE a compaction pass ([newlyHiddenRecordCount] then counts what
/// the pass appended).
Set<String> hiddenRangeIdsIn(List<SessionRecord> entries) => {
  for (final entry in entries)
    if (isHideRecord(entry)) entry.id,
};

/// The record ids a legacy `compaction` boundary hides: the message
/// records of the active branch between the PREVIOUS boundary's first
/// kept record (or the start) and this boundary's own. Positional, on
/// the linear entry list the session hands out.
Iterable<String> _classicCoveredIds(
  List<SessionRecord> entries,
  CompactionRecord record,
) {
  final end = entries.indexWhere((e) => e.id == record.firstKeptEntryId);
  if (end < 0) return const <String>[];
  final mine = entries.indexOf(record);
  var start = 0;
  for (var i = mine - 1; i >= 0; i--) {
    final previous = entries[i];
    if (previous is CompactionRecord) {
      final kept = entries.indexWhere((e) => e.id == previous.firstKeptEntryId);
      start = kept < 0 ? 0 : kept;
      break;
    }
  }
  if (start > end) start = end;
  return [
    for (final entry in entries.sublist(start, end))
      if (entry is MessageRecord) entry.id,
  ];
}

/// The record ids a hide record covers: a `hidden_range` names them
/// directly; a checkpoint names the records its text replaces; a legacy
/// `compaction` boundary is positional (see [_classicCoveredIds]).
Iterable<String> _coveredRecordIds(
  List<SessionRecord> entries,
  SessionRecord entry,
) => switch (entry) {
  HiddenRangeRecord() => entry.recordIds,
  CompactCheckpointRecord() => entry.coversRecordIds,
  CompactionRecord() => _classicCoveredIds(entries, entry),
  _ => const <String>[],
};

/// N of the post-hide notice (AC6): the DISTINCT record ids hidden by the
/// hide records of [entries] whose own id is not in [knownRangeIds] —
/// the hides appended after the caller's snapshot. A pass that hid
/// nothing counts 0 (⇒ no notice); several ranges in one pass
/// (multi-pass, E4) add up to the one total; a record hidden by two
/// mechanisms counts once; a checkpoint that is itself swallowed by a
/// later checkpoint is a carrier, not a hidden transcript record.
int newlyHiddenRecordCount(
  List<SessionRecord> entries,
  Set<String> knownRangeIds,
) {
  final carriers = {
    for (final entry in entries)
      if (entry is CompactCheckpointRecord) entry.id,
  };
  final covered = <String>{};
  final alreadyCovered = <String>{};
  for (final entry in entries) {
    if (!isHideRecord(entry)) continue;
    (knownRangeIds.contains(entry.id) ? alreadyCovered : covered).addAll(
      _coveredRecordIds(entries, entry),
    );
  }
  covered.removeAll(alreadyCovered);
  covered.removeAll(carriers);
  return covered.length;
}

/// The post-hide notice line (I6): [hiddenRecords] = the pass's hidden
/// record ids (multi-pass: the total; an exact count — no `≈`),
/// [tokensNow] = the post-hide request estimate (X), [tokensBefore] =
/// the pre-hide estimate (Y), [window] = the one window (W, exact).
/// [hasWorkingSet] selects the last clause: the pinned working set, or
/// the fix when the model wrote none. [estimated]: X and Y are heuristic
/// figures (the default — see [estimateMark]); an exact, provider-reported
/// pair drops the marker. Empty for an unknown window — no honest
/// number, no notice.
String postHideNoticeLine({
  required int hiddenRecords,
  required int tokensNow,
  required int tokensBefore,
  required int window,
  required bool hasWorkingSet,
  bool estimated = true,
}) {
  if (window <= 0) return '';
  final mark = estimated ? estimateMark : '';
  final tail = hasWorkingSet
      ? 'your working set is pinned — continue'
      : 'no working set yet — write one now with working_set(text), '
            'then continue';
  return '$postHideNoticePrefix$hiddenRecords records hidden; '
      'context now $mark$tokensNow/$window (was $mark$tokensBefore); $tail';
}

/// [postHideNoticeLine] inside the synthetic-user envelope — the record
/// appended before the next request.
String postHideContextNotice({
  required int hiddenRecords,
  required int tokensNow,
  required int tokensBefore,
  required int window,
  required bool hasWorkingSet,
  bool estimated = true,
}) {
  final line = postHideNoticeLine(
    hiddenRecords: hiddenRecords,
    tokensNow: tokensNow,
    tokensBefore: tokensBefore,
    window: window,
    hasWorkingSet: hasWorkingSet,
    estimated: estimated,
  );
  return line.isEmpty ? '' : contextNoticeEnvelope(line);
}

/// The near-limit notice line: [tokens] = the pre-request estimate (X),
/// [window] = the one window (W, exact); the percent is the REAL ratio of
/// the two (≈85 % on a 200k window, lower where the trigger's runway
/// dominates). [estimated]: X is a heuristic figure — the default, so
/// BOTH the percent and X/W carry the `≈` (see [estimateMark]); an
/// exact, provider-reported X drops both markers. Empty for an unknown
/// window.
String nearLimitNoticeLine({
  required int tokens,
  required int window,
  bool estimated = true,
}) {
  if (window <= 0) return '';
  final percent = (tokens * 100 / window).round();
  final prefix = estimated ? nearLimitNoticePrefix : nearLimitReportedPrefix;
  final mark = estimated ? estimateMark : '';
  return '$prefix$percent% ($mark$tokens/$window): update your working set '
      'with decisions, red tests and next steps, then KEEP WORKING; '
      'compaction will fold older records';
}

/// [nearLimitNoticeLine] inside the synthetic-user envelope.
String nearLimitContextNotice({
  required int tokens,
  required int window,
  bool estimated = true,
}) {
  final line = nearLimitNoticeLine(
    tokens: tokens,
    window: window,
    estimated: estimated,
  );
  return line.isEmpty ? '' : contextNoticeEnvelope(line);
}

/// The once-per-cycle arm state of a notice kind. Armed at session
/// start; [take] hands the notice out exactly once and disarms the
/// latch; every hide [rearm]s it (the context dropped, the next crossing
/// is a new cycle). One latch per session — hosts keep it next to the
/// session, never in a static.
final class ContextNoticeLatch {
  /// Creates an ARMED [ContextNoticeLatch] (the session-start state).
  ContextNoticeLatch();

  bool _armed = true;

  /// Whether the next crossing still emits.
  bool get armed => _armed;

  /// Consumes the armed state: `true` once, `false` until [rearm].
  bool take() {
    if (!_armed) return false;
    _armed = false;
    return true;
  }

  /// Re-arms the latch (after a hide).
  void rearm() => _armed = true;
}
