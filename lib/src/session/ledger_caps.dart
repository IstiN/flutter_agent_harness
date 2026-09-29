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
const int ledgetTextCapChars = 300;

/// Truncates [text] to [maxChars] characters with an ellipsis marker.
/// Null/short input passes through; [maxChars] below 1 yields null.
String? capLedgerText(String? text, {int maxChars = ledgetTextCapChars}) {
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
final class LedgerSnapshotDeduper {
  String? _lastJson;

  /// Whether a snapshot serialized to [json] must be appended (true when
  /// it differs from the last persisted one).
  bool shouldPersist(String json) {
    if (_lastJson == json) return false;
    _lastJson = json;
    return true;
  }

  /// Drops the memory (new session): the next snapshot persists.
  void reset() => _lastJson = null;
}
