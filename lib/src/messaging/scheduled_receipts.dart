import 'dart:async';
import 'dart:convert';

import '../env/execution_env.dart';

// The constructor params keep their public names (env/path/clock) while
// the fields stay private — same shape as scheduled_messages.dart.
// ignore_for_file: prefer_initializing_formals

/// First retry delay after a failed receipt write (issue #2415); doubles
/// on every further failure up to [defaultReceiptRetryMaxDelay].
const defaultReceiptRetryBaseDelay = Duration(seconds: 2);

/// The retry backoff's ceiling (issue #2415): a descriptor table that
/// stays full is re-probed every five minutes at most — never every tick.
const defaultReceiptRetryMaxDelay = Duration(minutes: 5);

/// The delivered-event ids of one trail text (a whole file or a single
/// pending line). Torn/malformed lines contribute nothing.
Set<String> _deliveredIdsOf(String text) {
  final ids = <String>{};
  for (final line in text.split('\n')) {
    if (line.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue; // torn tail line — the trail is append-only JSONL
    }
    if (decoded is Map &&
        decoded['event'] == 'delivered' &&
        decoded['id'] is String) {
      ids.add(decoded['id'] as String);
    }
  }
  return ids;
}

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
/// fd pressure (issue #2415): the failed line is KEPT in memory — a lost
/// receipt must be impossible (a lost receipt = a fired timer that cannot
/// be proven fired). One visible warning per pressure window (the healthy
/// → deferred transition) and one recovery notice when the backlog lands;
/// the whole backlog flushes in ONE backend append on the first success,
/// in original order (one descriptor op, not one per line). While
/// deferred, a bounded retry timer (exponential [retryBaseDelay] →
/// [retryMaxDelay]) keeps probing even when the queue goes quiet — the
/// scheduler may be idle while the descriptor table frees — and
/// [deliveredIds] counts the pending delivered events, so a deferred
/// persistence never hides a fired timer from the obligations-ledger
/// reconcile (#2384 AC1). [dispose] cancels the idle probe (CLI
/// teardown); the in-memory backlog itself is still process-lifetime
/// state — an exit with unflushed pending lines loses them (documented
/// best-effort loss window).
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
  /// as the queue's [onError] — the CLI prints `[sched]` lines). Fires
  /// ONCE per pressure window (the deferral) plus one recovery line when
  /// the deferred backlog finally lands.
  final void Function(String text)? onError;

  /// The first retry delay after a failed write; doubles on every further
  /// failure up to [retryMaxDelay]. Injectable so tests run in ms.
  final Duration retryBaseDelay;

  /// The backoff ceiling.
  final Duration retryMaxDelay;

  Future<void> _tail = Future.value();

  /// Lines not yet on disk, in append order, each WITH its trailing
  /// newline (so a backlog flush is one append of the joined block).
  final _pending = <String>[];

  /// Whether the current pressure window already warned (one deferral
  /// notice per window, one recovery notice at its close).
  bool _warned = false;

  /// The current backoff; zero while the trail is healthy. Doubles per
  /// failed drain up to [retryMaxDelay].
  Duration _backoff = Duration.zero;

  /// The quiet-queue retry: flushes pending lines even when no new event
  /// arrives (the scheduler may be idle while the table frees).
  Timer? _retryTimer;

  /// Receipts kept in memory because their write has not landed yet.
  int get pendingCount => _pending.length;

  /// Cancels the idle retry timer (CLI teardown): the trail stops
  /// holding the event loop past exit. Idempotent. The in-memory backlog
  /// is untouched — an exit with pending lines loses them (documented
  /// best-effort).
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Appends one event. Never throws — the trail is best-effort.
  Future<void> append(String event, Map<String, Object?> fields) {
    final line = jsonEncode({
      'ts': (_clock?.call() ?? DateTime.now()).toUtc().toIso8601String(),
      'event': event,
      ...fields,
    });
    final next = _tail.then((_) => _write('$line\n'));
    _tail = next;
    return next;
  }

  Future<void> _write(String line) async {
    _pending.add(line);
    // The append itself is a probe — while deferred this can recover
    // ahead of the timer (the scheduler ticks are a natural cadence);
    // the timer covers the quiet-queue case (no further appends).
    await _drain();
  }

  Future<void> _queueDrain() {
    final next = _tail.then((_) => _drain());
    _tail = next;
    return next;
  }

  /// Flushes the whole pending backlog as ONE backend append (one
  /// descriptor op under pressure, lines in order, never interleaved —
  /// appends ride the serialized [appendFile] contract). On failure:
  /// one warning per pressure window, everything stays pending, and the
  /// bounded retry timer arms (exponential backoff). On the success that
  /// closes a pressure window: one recovery notice. Never throws.
  Future<void> _drain() async {
    if (_pending.isEmpty) return;
    Object? failure;
    try {
      final result = await _env.appendFile(_path(), _pending.join());
      failure = result.errorOrNull;
    } on Object catch (e) {
      failure = e;
    }
    if (failure != null) {
      if (!_warned) {
        _warned = true;
        onError?.call(
          'receipt write deferred (${_pending.length} pending, flushed '
          'on recover): $failure',
        );
      }
      _armRetry();
      return;
    }
    final landed = _pending.length;
    _pending.clear();
    if (_warned) {
      _warned = false;
      onError?.call('receipt write recovered: $landed flushed');
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _backoff = Duration.zero;
  }

  /// Arms the quiet-queue probe for the current backoff (exponential,
  /// capped). Chained onto [_tail] so the timer's drain never interleaves
  /// an append.
  void _armRetry() {
    _backoff = _backoff == Duration.zero
        ? retryBaseDelay
        : _backoff * 2 > retryMaxDelay
        ? retryMaxDelay
        : _backoff * 2;
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff, () {
      unawaited(_queueDrain());
    });
  }

  /// The scheduled-message ids whose delivery LANDED — the `delivered`
  /// events of the trail (issue #2384 AC1: the fired-timer evidence the
  /// obligations ledger pass consumes to auto-close a pending-wait).
  /// PENDING delivered events count too: the delivery happened, only its
  /// persistence is deferred — a fd-pressure window must not push a
  /// pending-wait into the age-out fallback (AC2). Tolerant: a
  /// missing/empty trail, an unreadable file, or a torn line contributes
  /// nothing — the pass then falls back to age-out (AC2).
  Future<Set<String>> deliveredIds() async {
    final text = (await _env.readTextFile(_path())).valueOrNull ?? '';
    final ids = _deliveredIdsOf(text);
    for (final line in _pending) {
      ids.addAll(_deliveredIdsOf(line));
    }
    return ids;
  }
}
