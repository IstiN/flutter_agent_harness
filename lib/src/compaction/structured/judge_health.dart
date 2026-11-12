/// The cross-run judge-health latch for the structured engine's hide
/// judge (gh-2096).
///
/// The hide judge is one LM call under a fixed attempt budget. When the
/// configured class cannot answer within that budget (a
/// mandatory-reasoning flash class behind a queueing gateway), EVERY
/// auto-compact run used to re-pay the full budget: the in-run
/// consecutive-failure counter reset per run (judge-health amnesia).
/// This library gives the counter session persistence — as ADDITIVE
/// `custom` records (`structured_judge_health`) on the branch, newest
/// wins:
///
/// - the counter seeds from the newest record at run start, so the
///   deterministic fallback's threshold can trip on the first run after
///   a latching one;
/// - while latched (failures ≥ [judgeLatchAfter]) runs skip the judge
///   entirely — the deterministic hide decides — until the probe window
///   elapses (or the configured class changed, which probes at once);
///   the one probe call unlatches on success and re-arms the window on
///   failure;
/// - a judge success writes the unlatch record (failures 0).
///
/// Records ride [CustomRecord] — the established additive,
/// context-invisible vehicle — so an old session (no health records)
/// loads byte-identical and derives a fresh state, and an old binary
/// reading a new session ignores the record (owner directive: no
/// migration rewrites, ever).
library;

import '../../session/session_record.dart' show CustomRecord, SessionRecord;

/// The `customType` of the additive judge-health record.
const String judgeHealthRecordType = 'structured_judge_health';

/// Consecutive judge failures at which the cross-run latch engages — the
/// same threshold as the in-run deterministic fallback (issue #541): the
/// latch persists exactly the state the fallback reached, so a latched
/// class never re-pays the budget ladder in a later run.
const int judgeLatchAfter = 2;

/// The persisted judge-health state derived from the newest
/// [judgeHealthRecordType] record on a branch path.
final class JudgeHealthState {
  /// Creates the state; [updatedAt] is the record's timestamp (the last
  /// judge event this session paid for).
  const JudgeHealthState({
    required this.consecutiveFailures,
    this.target,
    this.updatedAt,
  });

  /// The state an old (record-less) session derives: the judge
  /// participates normally.
  static const JudgeHealthState fresh = JudgeHealthState(
    consecutiveFailures: 0,
  );

  /// Persisted consecutive judge failures (0 = healthy / unlatched).
  final int consecutiveFailures;

  /// The judge target (`role=…, model=… @ host`) recorded at latch time.
  /// A load whose engine target differs probes immediately — the latch is
  /// about the CLASS, not the session.
  final String? target;

  /// When the record was appended (the probe-cadence anchor).
  final DateTime? updatedAt;

  /// Whether the cross-run latch currently holds.
  bool get latched => consecutiveFailures >= judgeLatchAfter;
}

/// The additive record payload: the failure count plus the judge target
/// that produced it. Timestamps ride the record envelope, not the data.
Map<String, Object?> judgeHealthPayload({
  required int consecutiveFailures,
  String? target,
}) => {'consecutiveFailures': consecutiveFailures, 'target': ?target};

/// Derives the state from the NEWEST [judgeHealthRecordType] record on
/// [path], or `null` when the session carries none (an old session). A
/// malformed payload degrades to a fresh state — a corrupt record must
/// never fail a compaction run.
JudgeHealthState? judgeHealthFromPath(List<SessionRecord> path) {
  for (final record in path.reversed) {
    if (record is! CustomRecord) continue;
    if (record.customType != judgeHealthRecordType) continue;
    final data = record.data;
    if (data is! Map) return JudgeHealthState.fresh;
    final failures = data['consecutiveFailures'];
    final target = data['target'];
    return JudgeHealthState(
      consecutiveFailures: failures is int && failures > 0 ? failures : 0,
      target: target is String ? target : null,
      updatedAt: record.timestamp,
    );
  }
  return null;
}
