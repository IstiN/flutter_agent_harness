/// The engine DISPOSES over the model's hide proposals (GOAL #2394 AC7):
/// every alias the reply names resolves against the S0 SNAPSHOT index
/// (never a fresh ledger — aliases drift under windowed storage and hard
/// caps, ✗C/D7), the record is then validated against the FRESH projection
/// with the judge-era `validateHidePicks` semantics (snap OUTWARD to whole
/// pair groups, protected tail, pinned expansions, `·exempt` user turns),
/// plus the merged call's new rejections:
///
/// - `U` unknown — the alias names nothing on the frozen epoch index
///   (hallucinated, the live edge, beyond the index);
/// - `X` exempt — a real user turn is never hidden, whatever the model
///   wrote (F8/F9/E9);
/// - `T` tail/pin — the protected live edge or a pinned expansion;
/// - `C` covered/in-range — already hidden, checkpoint-covered, or inside
///   the fold range fixed before the call (moot: the checkpoint supersedes);
/// - `F` fold record — an old checkpoint / classic summary / branch
///   summary: hiding it would unfold its range and GROW pressure (E28);
/// - `S` snapped — the pick (plus its whole pair group) is hidden.
///
/// Pure — no IO; the engine appends the verdict's ids.
library;

import '../../session/session_record.dart';
import '../../context.dart';
import 'hand_over.dart';
import 'ledger.dart';
import 'projection.dart';

/// Where one hide proposal landed.
enum HidePickBucket {
  /// Hidden (snapped outward to the whole pair group).
  snapped,

  /// Unknown alias on the snapshot index.
  unknown,

  /// A real user turn.
  exempt,

  /// Protected tail or a pinned expansion.
  tail,

  /// Already hidden/covered or inside the fold range (moot).
  covered,

  /// A fold record (checkpoint / classic summary / branch summary).
  foldRecord,
}

/// The dispose verdict over one hand-over reply's hide list.
final class HandOverDisposeVerdict {
  /// Creates a verdict.
  const HandOverDisposeVerdict({
    required this.recordIds,
    required this.labels,
    required this.counts,
  });

  /// The stable record ids to hide — every surviving pick's WHOLE pair
  /// group, deduplicated, sorted.
  final List<String> recordIds;

  /// Sanitized label per CARRIER record id (the group's first record in
  /// file order); a pick whose label failed sanitization carries none.
  final Map<String, String> labels;

  /// Picks per bucket (every pick lands in exactly one).
  final Map<HidePickBucket, int> counts;

  /// Picks that produced ids.
  int get snapped => counts[HidePickBucket.snapped] ?? 0;

  /// Picks that named nothing on the snapshot index.
  int get unknown => counts[HidePickBucket.unknown] ?? 0;

  /// Picks that named a real user turn.
  int get exempt => counts[HidePickBucket.exempt] ?? 0;

  /// Picks that named the protected tail or a pinned expansion.
  int get tail => counts[HidePickBucket.tail] ?? 0;

  /// Picks that were moot (hidden / covered / inside the fold range).
  int get covered => counts[HidePickBucket.covered] ?? 0;

  /// Picks that named a fold record.
  int get foldRecord => counts[HidePickBucket.foldRecord] ?? 0;

  /// The report's hide-list line: `P → S snapped · U unknown · …` with
  /// the zero buckets omitted.
  String render() {
    final parts = <String>[
      '$snapped snapped',
      if (unknown > 0) '$unknown unknown',
      if (exempt > 0) '$exempt exempt',
      if (tail > 0) '$tail tail/pin',
      if (covered > 0) '$covered covered/in-range',
      if (foldRecord > 0) '$foldRecord fold-record',
    ];
    return parts.join(' · ');
  }
}

/// Disposes the reply's [picks].
///
/// [snapshotIndex] is the S0 epoch's `RecordSeqIndex` (alias → record);
/// [ledger] the FRESH view's ledger (pair groups, `exempt`), [state] the
/// fresh structured view (hidden / covered / pinned), [protectedTail] the
/// live-edge ids, [foldFromSeq]..[foldToSeq] the fold range fixed before
/// the call — or, when the engine knows the exact members, [inRangeSeqs]
/// (a pinned record INSIDE the span is not a member: hiding it is legal,
/// so the span alone would mis-bucket it as moot). Never throws: a pick
/// that names nothing lands in `U`.
HandOverDisposeVerdict disposeHidePicks({
  required List<HandOverHidePick> picks,
  required RecordSeqIndex snapshotIndex,
  required ContextLedger ledger,
  required StructuredViewState state,
  required Set<String> protectedTail,
  required int foldFromSeq,
  required int foldToSeq,
  Set<int>? inRangeSeqs,
}) {
  final entryById = {for (final entry in ledger.entries) entry.recordId: entry};
  final counts = {for (final bucket in HidePickBucket.values) bucket: 0};
  final ids = <String>{};
  final labels = <String, String>{};
  for (final pick in picks) {
    final resolved = <SessionRecord>[
      // Aliases beyond the frozen index resolve to nothing (`null`).
      for (var seq = pick.from; seq <= pick.to; seq++)
        ?snapshotIndex.recordAt(seq),
    ];
    final bucket = _bucketOf(
      resolved,
      ledger: ledger,
      entryById: entryById,
      state: state,
      protectedTail: protectedTail,
      foldFromSeq: foldFromSeq,
      foldToSeq: foldToSeq,
      inRangeSeqs: inRangeSeqs,
      snapshotIndex: snapshotIndex,
    );
    counts[bucket] = counts[bucket]! + 1;
    if (bucket != HidePickBucket.snapped) continue;
    final group = <String>{
      for (final record in resolved) ...ledger.groupOf(record.id),
    };
    ids.addAll(group);
    final label = sanitizeHideLabel(pick.rawLabel);
    if (label != null) {
      labels.putIfAbsent(_carrierOf(group, snapshotIndex), () => label);
    }
  }
  return HandOverDisposeVerdict(
    recordIds: ids.toList()..sort(),
    labels: labels,
    counts: counts,
  );
}

HidePickBucket _bucketOf(
  List<SessionRecord> resolved, {
  required ContextLedger ledger,
  required Map<String, LedgerEntry> entryById,
  required StructuredViewState state,
  required Set<String> protectedTail,
  required int foldFromSeq,
  required int foldToSeq,
  required Set<int>? inRangeSeqs,
  required RecordSeqIndex snapshotIndex,
}) {
  if (resolved.isEmpty) return HidePickBucket.unknown;
  if (resolved.any(isFoldRecord)) return HidePickBucket.foldRecord;
  bool moot(SessionRecord record) {
    if (state.hiddenRecordIds.contains(record.id) ||
        state.isCovered(record.id)) {
      return true;
    }
    final seq = snapshotIndex.seqOf(record.id);
    if (seq == null) return false;
    return inRangeSeqs != null
        ? inRangeSeqs.contains(seq)
        : seq >= foldFromSeq && seq <= foldToSeq;
  }

  // The fresh ledger's `·exempt` (a real user turn); a record the ledger
  // does not list falls back to its own shape.
  bool isExempt(SessionRecord record) =>
      entryById[record.id]?.exempt ??
      (record is MessageRecord && record.message is UserMessage);

  final live = [
    for (final record in resolved)
      if (!moot(record)) record,
  ];
  if (live.isEmpty) return HidePickBucket.covered;
  if (live.any(isExempt)) {
    return HidePickBucket.exempt;
  }
  bool touchesTailOrPin(String id) =>
      protectedTail.contains(id) || state.pinnedRecordIds.contains(id);
  if (live.any((record) => touchesTailOrPin(record.id))) {
    return HidePickBucket.tail;
  }
  // Snap OUTWARD to the whole pair group (D6): a group that touches the
  // tail or a pin hides as a whole or never.
  for (final record in live) {
    for (final member in ledger.groupOf(record.id)) {
      if (touchesTailOrPin(member)) return HidePickBucket.tail;
    }
  }
  return HidePickBucket.snapped;
}

/// Whether [record] is a fold record (E28): its HIDE would render it
/// without a marker and unfold the range it replaces.
bool isFoldRecord(SessionRecord record) =>
    record is CompactCheckpointRecord ||
    record is CompactionRecord ||
    record is BranchSummaryRecord;

/// An alias no record can carry (file aliases are small counters) — the
/// sort key of a member missing from the snapshot index. A 30-bit
/// literal: dart2js shifts wrap at 32 (issue #1074 guard).
const int _beyondLastSeq = 1 << 30;

/// The group's carrier: the member with the smallest alias (file order).
String _carrierOf(Set<String> group, RecordSeqIndex snapshotIndex) {
  String? carrier;
  var carrierSeq = _beyondLastSeq;
  for (final id in group) {
    final seq = snapshotIndex.seqOf(id) ?? _beyondLastSeq;
    if (seq < carrierSeq) {
      carrierSeq = seq;
      carrier = id;
    }
  }
  return carrier ?? group.first;
}
