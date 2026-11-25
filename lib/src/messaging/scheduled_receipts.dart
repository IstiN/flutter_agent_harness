import 'dart:async';
import 'dart:convert';

import '../env/execution_env.dart';
import '../env/fd_pressure.dart';

// The constructor params keep their public names (env/path/clock) while
// the fields stay private — same shape as scheduled_messages.dart.
// ignore_for_file: prefer_initializing_formals

/// First retry delay after a failed receipt write (gh-2415); doubles on
/// every further failure up to [defaultReceiptRetryMaxDelay].
const defaultReceiptRetryBaseDelay = Duration(seconds: 2);

/// The retry backoff's ceiling (gh-2415): a descriptor table that stays
/// full is re-probed every five minutes at most — never every tick.
const defaultReceiptRetryMaxDelay = Duration(minutes: 5);

/// Append-only JSONL receipt trail for scheduled messages (gh-1180 AC4).
///
/// One line per lifecycle event so a post-mortem can distinguish "timer
/// never fired" (a `scheduled` line with no matching `delivered`) from
/// "wake refused" (a `wake_refused` line with its reason) without reading
/// source:
///
/// - queue-side: `scheduled` (id, dueMs, to, text), `delivered`
///   (id, to, dueMs, lagMs), `delivery_failed` (id, error), `scan_failed`
///   (error);
/// - host-side (the CLI wake path): `wake_attempted` (lane, ids),
///   `turn_started`, `wake_refused` (lane, reason).
///
/// The trail lives at `<messagesRoot>/_scheduled/receipts.jsonl` — the
/// record scans read `*.json` entries only, so the log never joins a
/// sweep or a delivery. Best-effort by contract: a failing write is
/// reported through [onError] and NEVER breaks scheduling or waking
/// ([append] always completes normally). Appends ride the backend's
/// `appendFile`, so concurrent writers interleave whole lines, never tear
/// them; in-process appends are serialized to keep line order stable.
///
/// gh-2415 — a lost receipt must be impossible: a failed write keeps its
/// line(s) PENDING in memory ([pendingCount]), retries with exponential
/// backoff ([defaultReceiptRetryBaseDelay] → [defaultReceiptRetryMaxDelay])
/// through a timer that survives a quiet queue, flushes everything pending
/// in ONE append on the first success (fewer descriptors under pressure),
/// warns ONCE per pressure window (`receipt write deferred: fd pressure`)
/// and says so when it recovers. Before this, a long-lived session at the
/// fd limit re-failed every tick and the receipt was gone for good.
final class ScheduledReceiptLog {
  ScheduledReceiptLog({
    required ExecutionEnv env,
    required String Function() path,
    DateTime Function()? clock,
    this.onError,
    this.retryBaseDelay = defaultReceiptRetryBaseDelay,
    this.retryMaxDelay = defaultReceiptRetryMaxDelay,
  }) : _env = env,
       _path = path,
       _clock = clock;

  final ExecutionEnv _env;
  final String Function() _path;
  final DateTime Function()? _clock;

  /// Host-visible notice when a receipt cannot be persisted (same channel
  /// as the queue's [onError] — the CLI prints `[sched]` lines). Gh-2415:
  /// at most ONE deferral notice per pressure window, plus one recovery
  /// line when the pending receipts finally land.
  final void Function(String text)? onError;

  /// The first retry delay after a failed write; doubles per further
  /// failure up to [retryMaxDelay]. Injectable so tests run in ms.
  final Duration retryBaseDelay;

  /// The backoff ceiling.
  final Duration retryMaxDelay;

  Future<void> _tail = Future.value();

  /// Lines whose write has not landed yet, in order (gh-2415).
  final _pending = <String>[];

  /// The current backoff; zero while the trail is healthy.
  Duration _backoff = Duration.zero;

  /// Earliest moment a retry may run (the backoff gate); null = healthy.
  DateTime? _retryAt;

  /// The quiet-queue retry: flushes pending lines even when no new event
  /// arrives (the scheduler may be idle while the descriptor table frees).
  Timer? _retryTimer;

  /// Whether this pressure window already warned.
  bool _warned = false;

  /// Receipts kept in memory because their write has not landed yet.
  int get pendingCount => _pending.length;

  DateTime _now() => _clock?.call() ?? DateTime.now();

  /// Appends one event. Never throws — the trail is best-effort. The
  /// returned future completes when the write ATTEMPT finished (landed,
  /// or deferred into the pending queue under backoff).
  Future<void> append(String event, Map<String, Object?> fields) {
    final line = jsonEncode({
      'ts': (_clock?.call() ?? DateTime.now()).toUtc().toIso8601String(),
      'event': event,
      ...fields,
    });
    _pending.add('$line\n');
    return _queueDrain();
  }

  Future<void> _queueDrain() {
    final next = _tail.then((_) => _drain());
    _tail = next;
    return next;
  }

  /// Writes everything pending in one append. A failure keeps the lines
  /// and arms the backoff; a success clears the window and chains another
  /// drain when new lines arrived meanwhile.
  Future<void> _drain() async {
    if (_pending.isEmpty) return;
    final now = _now();
    final retryAt = _retryAt;
    if (retryAt != null && now.isBefore(retryAt)) {
      _armRetry(retryAt.difference(now));
      return;
    }
    final count = _pending.length;
    Object? failure;
    try {
      final result = await _env.appendFile(
        _path(),
        _pending.take(count).join(),
      );
      failure = result.errorOrNull;
    } on Object catch (e) {
      failure = e;
    }
    if (failure != null) {
      _deferred(failure);
      return;
    }
    _pending.removeRange(0, count);
    _recovered(count);
    // Lines appended while this write was in flight already have their
    // own drain chained behind this one (every append queues one).
  }

  void _deferred(Object error) {
    final next = _backoff == Duration.zero
        ? retryBaseDelay
        : Duration(
            microseconds:
                _backoff.inMicroseconds * 2 > retryMaxDelay.inMicroseconds
                ? retryMaxDelay.inMicroseconds
                : _backoff.inMicroseconds * 2,
          );
    _backoff = next;
    _retryAt = _now().add(next);
    if (!_warned) {
      _warned = true;
      final kept =
          '${_pending.length} receipt(s) kept in memory, '
          'retrying in ${next.inSeconds}s';
      onError?.call(
        isFdPressureError(error)
            ? 'receipt write deferred: fd pressure — $error; $kept'
            : 'receipt write failed: $error — $kept',
      );
    }
    _armRetry(next);
  }

  void _recovered(int flushed) {
    final wasDeferred = _backoff != Duration.zero;
    _backoff = Duration.zero;
    _retryAt = null;
    _warned = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (wasDeferred) {
      onError?.call('receipt write recovered: $flushed receipt(s) flushed');
    }
  }

  void _armRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_queueDrain());
    });
  }

  /// Stops the retry timer and drops whatever is still pending — a host
  /// tearing down its scheduler calls this; the trail is best-effort and
  /// a shutdown cannot wait on a full descriptor table.
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _pending.clear();
  }

  /// The scheduled-message ids whose delivery LANDED — the `delivered`
  /// events of the trail (issue #2384 AC1: the fired-timer evidence the
  /// obligations ledger pass consumes to auto-close a pending-wait).
  /// Tolerant: a missing/empty trail, an unreadable file, or a torn line
  /// contributes nothing — the pass then falls back to age-out (AC2).
  /// Gh-2415: receipts still pending in memory count as delivered too —
  /// the event happened, only its persistence is deferred.
  Future<Set<String>> deliveredIds() async {
    final ids = <String>{};
    for (final line in _pending) {
      _collectDelivered(line, ids);
    }
    final text = (await _env.readTextFile(_path())).valueOrNull;
    if (text == null || text.isEmpty) return ids;
    for (final line in text.split('\n')) {
      if (line.isEmpty) continue;
      _collectDelivered(line, ids);
    }
    return ids;
  }

  static void _collectDelivered(String line, Set<String> ids) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return; // torn tail line — the trail is append-only JSONL
    }
    if (decoded is Map &&
        decoded['event'] == 'delivered' &&
        decoded['id'] is String) {
      ids.add(decoded['id'] as String);
    }
  }
}
