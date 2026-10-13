/// Bounded persistence helpers for the session-file custom ledgers
/// (gh-1073): append-only snapshot ledgers (`shell_job_registry`,
/// `subagent_registry`) grew a month-long session to 12.4 GiB because
/// every mutation appended a full fresh snapshot with UNBOUNDED strings.
/// Every payload that crosses into a session record goes through a cap
/// here, and repeated identical snapshots are suppressed at the write
/// site ([LedgerSnapshotDeduper]).
library;

import 'dart:async';

/// Char cap for one string field inside a persisted ledger record
/// (gh-1073). Generous for display — commands, detail lines, reply
/// previews — while bounding the record against pathological payloads
/// (a 50 KB heredoc command, a giant log tail).
const int ledgerTextCapChars = 300;

/// The write-time persist window for a latest-snapshot-wins ledger
/// (gh-1590). Only the newest snapshot of such a ledger is ever read
/// (`latestRecords`), so mutations inside the window coalesce into ONE
/// append plus a trailing flush instead of one append per change — the
/// ticket's session once carried 1,635 `shell_job_registry` snapshots
/// (136 MB) for a board that only ever reads the last one.
const Duration ledgerSnapshotPersistInterval = Duration(seconds: 30);

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

/// Write-site rate bound for a latest-snapshot-wins ledger (gh-1590): a
/// companion to [LedgerSnapshotDeduper] that bounds WHEN snapshots may
/// append, while the deduper bounds WHICH payloads are worth appending.
/// Inside a [minInterval] window every mutation after the first is
/// refused and coalesces behind one trailing flush — N state changes
/// leave at most two records (the first + the flush), and the flush
/// guarantees the FINAL state reaches the file even if the mutations
/// stop (resume rehydrates through the latest snapshot only).
///
/// The same tracker shape as the CLI liveness trackers: a clock seam for
/// tests plus a production `Timer` leg with a [poll] seam — tests
/// advance the clock and call [poll] directly instead of waiting on
/// real timers.
final class LedgerSnapshotThrottle {
  LedgerSnapshotThrottle({
    this.minInterval = ledgerSnapshotPersistInterval,
    DateTime Function()? clock,
    this._onFlushDue,
  }) : _clock = clock ?? DateTime.now;

  /// How long one persisted snapshot owns the window.
  final Duration minInterval;

  final DateTime Function() _clock;

  /// Called by the production trailing leg when [poll] turns due — the
  /// writer re-runs its persist (the deduper still suppresses a no-op).
  final void Function()? _onFlushDue;

  DateTime? _lastPersistAt;

  /// When the first refused mutation reserved the trailing flush.
  DateTime? _pendingSince;

  Timer? _timer;

  /// Whether a mutation was refused and is waiting for the trailing
  /// flush.
  bool get hasPending => _pendingSince != null;

  /// Whether a snapshot may append NOW: never persisted, or the window
  /// since the last persist has passed. A refusal reserves the trailing
  /// flush and arms its production leg — call again on the NEXT
  /// mutation, never in a retry loop.
  bool shouldPersistNow() {
    final last = _lastPersistAt;
    if (last == null || _clock().difference(last) >= minInterval) {
      return true;
    }
    _pendingSince ??= _clock();
    _arm();
    return false;
  }

  /// Whether the trailing flush of a refused mutation is due. Production
  /// arrives here through the Timer leg; tests advance the clock seam
  /// and call it directly. A due flush is CONSUMED — the caller persists
  /// and reports back with [confirmPersisted].
  bool poll() {
    final since = _pendingSince;
    if (since == null) return false;
    if (_clock().difference(since) < minInterval) return false;
    _pendingSince = null;
    return true;
  }

  /// The append landed: the window restarts from now.
  void confirmPersisted() {
    _lastPersistAt = _clock();
    _pendingSince = null;
    _cancelTimer();
  }

  /// A fresh session (rehydrate/reset next to the deduper): the next
  /// snapshot persists immediately.
  void reset() {
    _lastPersistAt = null;
    _pendingSince = null;
    _cancelTimer();
  }

  /// Disarms the trailing leg without touching the bookkeeping — the
  /// shutdown flush takes over (a pending Timer must never hold the
  /// isolate at process exit).
  void dispose() => _cancelTimer();

  void _arm() {
    if (_timer != null) return;
    _timer = Timer(minInterval, () {
      _timer = null;
      if (!poll()) return;
      final due = _onFlushDue;
      if (due != null) due();
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
