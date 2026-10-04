/// Bounded persistence helpers for the session-file custom ledgers
/// (gh-1073): append-only snapshot ledgers (`shell_job_registry`,
/// `subagent_registry`) grew a month-long session to 12.4 GiB because
/// every mutation appended a full fresh snapshot with UNBOUNDED strings.
/// Every payload that crosses into a session record goes through a cap
/// here, and repeated identical snapshots are suppressed at the write
/// site ([LedgerSnapshotDeduper]).
library;

/// Char cap for one string field inside a persisted ledger record
/// (gh-1073). Generous for display — commands, detail lines, reply
/// previews — while bounding the record against pathological payloads
/// (a 50 KB heredoc command, a giant log tail).
const int ledgerTextCapChars = 300;

/// Truncates [text] to [maxChars] characters with an ellipsis marker.
/// Null/short input passes through; [maxChars] below 1 yields null.
String? capLedgerText(String? text, {int maxChars = ledgerTextCapChars}) {
  if (text == null) return null;
  if (text.length <= maxChars) return text;
  if (maxChars < 1) return null;
  return '${text.substring(0, maxChars - 1)}…';
}

/// Write-site guard against redundant ledger appends (gh-1073): a
/// snapshot ledger that appends on every mutation wastes the session file
/// when the payload did not actually change (29k `shell_job_registry`
/// snapshots on the ticket's session). One instance per ledger writer;
/// [reset] on session switch so a new session persists its first
/// snapshot.
///
/// Two-phase bookkeeping: [shouldPersist] only RESERVES the snapshot —
/// the deduper must not treat it as persisted until the append succeeds
/// ([confirmPersisted]). Persist chains deliberately swallow append
/// errors so one failure cannot poison every later write; without the
/// revert, the retried identical snapshot would be skipped and the
/// ledger would silently miss a state until the next mutation.
final class LedgerSnapshotDeduper {
  String? _lastJson;
  String? _pendingJson;

  /// Whether a snapshot serialized to [json] must be appended (true when
  /// it differs from the last persisted one). When true, the snapshot is
  /// remembered as pending — follow up with [confirmPersisted] after the
  /// append succeeds or [revertFailedPersist] when it fails.
  bool shouldPersist(String json) {
    if (_lastJson == json) return false;
    _pendingJson = json;
    return true;
  }

  /// Marks the pending snapshot (from the last [shouldPersisted] that
  /// returned true) as persisted.
  void confirmPersisted() {
    _lastJson = _pendingJson;
    _pendingJson = null;
  }

  /// Drops the pending reservation after a failed append: the next
  /// [shouldPersisted] with the same payload returns true again, so the
  /// retry is not skipped.
  void revertFailedPersist() => _pendingJson = null;

  /// Drops the memory (new session): the next snapshot persists.
  void reset() {
    _lastJson = null;
    _pendingJson = null;
  }
}
