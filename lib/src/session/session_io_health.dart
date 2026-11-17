/// Process-wide session-IO health (issue #2248).
///
/// The 2026-11-17 yoclip wedge: wholesale fs failures wedged a session's
/// turn for 21+ minutes while the stall watchdog reported a generic
/// "agent stalled" with provider-stall levers (/compact, image budgets)
/// — the truth was "session IO is failing", with different levers
/// (restart the host, check fds/container access). The storages note
/// every surfaced fs failure here, keyed by session id, so:
///
/// - the stall banner reclassifies into the fs variant when THIS
///   session's IO failed inside the stall window (AC5) — per-session
///   isolation: a wedged session never poisons a healthy sibling
///   (01a1ceda worked all through the 01a061ca wedge);
/// - `/stats` and the boot fa.log line render the per-minute fs-op
///   failure gauge (AC6).
///
/// Pure Dart, no I/O, no timers: the rolling per-minute window is
/// computed from recorded timestamps on read.
library;

/// One surfaced session-IO failure.
typedef SessionIoFailure = ({DateTime at, String error});

final class _SessionIoHealth {
  final lastBySession = <String, SessionIoFailure>{};
  final failureTimes = <DateTime>[];
}

final _health = _SessionIoHealth();

/// Observable health surface for the harness hosts. Static by design:
/// the storages that note failures are constructed deep inside repos,
/// and the health question ("is THIS session's IO failing right now?")
/// is process-global by nature — one fa.log, one fd table per process.
abstract final class SessionIoHealth {
  /// Records one surfaced fs failure for [sessionId]. [error] is the
  /// RAW reason text (the FileError/SessionException message with its
  /// errno) — the banner prints it verbatim: `session IO failing:` plus
  /// this text (AC5).
  static void noteFailure(String sessionId, String error) {
    if (sessionId.isEmpty) return;
    final now = DateTime.now();
    _health.lastBySession[sessionId] = (at: now, error: error);
    _health.failureTimes.add(now);
    // The gauge reads the last minute only; drop older entries on write
    // so the ring cannot grow unbounded under a failure flood (the
    // 15:36 minute saw 1300+ failures). lastBySession is NOT pruned on
    // time — one bounded entry per session id, and the stall window can
    // outlive a minute (the watchdog compares ages itself).
    if (_health.failureTimes.length > 4096) _prune(now);
  }

  /// The session's most recent surfaced fs failure, or null when none
  /// was noted (healthy, or never attempted IO in this process).
  static SessionIoFailure? lastFailure(String sessionId) =>
      sessionId.isEmpty ? null : _health.lastBySession[sessionId];

  /// Surfaced fs failures over the rolling last minute (AC6 gauge).
  static int failuresInLastMinute([DateTime? now]) {
    final at = now ?? DateTime.now();
    _prune(at);
    return _health.failureTimes.length;
  }

  /// Test isolation: clears every recorded failure.
  static void resetForTests() {
    _health.lastBySession.clear();
    _health.failureTimes.clear();
  }

  static void _prune(DateTime now) {
    final cutoff = now.subtract(const Duration(minutes: 1));
    _health.failureTimes.removeWhere((at) => at.isBefore(cutoff));
  }
}

/// Whether a stall currently reads as a session-IO failure (issue #2248
/// AC5): the session's most recent fs failure ([last]) landed INSIDE the
/// stall window ([window] ending at [now]). A failure older than the
/// window stays a provider stall — the levers must not lie about a
/// recovered fs. Public for the watchdog's unit tests (the card's "UT
/// on the `_runLooksWedged` classification inputs").
bool stallIsSessionIo({
  required SessionIoFailure? last,
  required DateTime now,
  required Duration window,
}) {
  if (last == null) return false;
  final age = now.difference(last.at);
  return !age.isNegative && age <= window;
}
