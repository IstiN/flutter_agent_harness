import 'dart:async';
import 'dart:convert';

import '../env/execution_env.dart';

// The constructor params keep their public names (env/path/clock) while
// the fields stay private — same shape as scheduled_messages.dart.
// ignore_for_file: prefer_initializing_formals

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
/// fd pressure (issue #2415): the failed line is KEPT in memory and
/// retried on the next append — a lost receipt must be impossible (a lost
/// receipt = a fired timer that cannot be proven fired). One visible
/// warning per pressure window (the healthy → deferred transition), so
/// a failing table spams neither the TUI nor the user; the backlog
/// flushes whole on the first successful write, in original order.
final class ScheduledReceiptLog {
  ScheduledReceiptLog({
    required ExecutionEnv env,
    required String Function() path,
    DateTime Function()? clock,
    this.onError,
  }) : _env = env,
       _path = path,
       _clock = clock;

  final ExecutionEnv _env;
  final String Function() _path;
  final DateTime Function()? _clock;

  /// Host-visible notice when a receipt cannot be persisted (same channel
  /// as the queue's [onError] — the CLI prints `[sched]` lines). Fires
  /// ONCE per pressure window: on the first failed write after a healthy
  /// stretch, not again until the backlog has flushed.
  final void Function(String text)? onError;

  Future<void> _tail = Future.value();

  /// Lines not yet on disk, in append order. Healthy state: drained every
  /// append. Deferred state: grows until the first successful write.
  final _pending = <String>[];

  /// True while the backend is refusing writes (the pressure window).
  bool _deferred = false;

  /// Appends one event. Never throws — the trail is best-effort.
  Future<void> append(String event, Map<String, Object?> fields) {
    final line = jsonEncode({
      'ts': (_clock?.call() ?? DateTime.now()).toUtc().toIso8601String(),
      'event': event,
      ...fields,
    });
    final next = _tail.then((_) => _write(line));
    _tail = next;
    return next;
  }

  Future<void> _write(String line) async {
    _pending.add(line);
    // One probe attempt per append — while deferred this IS the backoff
    // (a single failing write per tick, no repeated warnings); the whole
    // backlog rides the first success.
    await _drain();
  }

  /// Writes the pending lines in order. On the first failure: one
  /// warning per pressure window, the failed line stays at the head of
  /// [_pending] and the drain stops. Never throws.
  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      Object? failure;
      try {
        final result = await _env.appendFile(_path(), '${_pending.first}\n');
        failure = result.errorOrNull;
      } on Object catch (e) {
        failure = e;
      }
      if (failure != null) {
        if (!_deferred) {
          _deferred = true;
          onError?.call(
            'receipt write deferred (${_pending.length} pending, flushed '
            'on recover): $failure',
          );
        }
        return;
      }
      _pending.removeAt(0);
    }
    // Fully drained — the pressure window is closed; the next failure
    // warns again.
    _deferred = false;
  }

  /// The scheduled-message ids whose delivery LANDED — the `delivered`
  /// events of the trail (issue #2384 AC1: the fired-timer evidence the
  /// obligations ledger pass consumes to auto-close a pending-wait).
  /// Tolerant: a missing/empty trail, an unreadable file, or a torn line
  /// contributes nothing — the pass then falls back to age-out (AC2).
  Future<Set<String>> deliveredIds() async {
    final text = (await _env.readTextFile(_path())).valueOrNull;
    if (text == null || text.isEmpty) return const {};
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
}
