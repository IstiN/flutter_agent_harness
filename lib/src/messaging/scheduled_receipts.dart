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
  /// as the queue's [onError] — the CLI prints `[sched]` lines).
  final void Function(String text)? onError;

  Future<void> _tail = Future.value();

  /// Appends one event. Never throws — the trail is best-effort.
  Future<void> append(String event, Map<String, Object?> fields) {
    final line = jsonEncode({
      'ts': (_clock?.call() ?? DateTime.now()).toUtc().toIso8601String(),
      'event': event,
      ...fields,
    });
    final next = _tail.then((_) async {
      try {
        final result = await _env.appendFile(_path(), '$line\n');
        final error = result.errorOrNull;
        if (error != null) {
          onError?.call('receipt write failed: $error');
        }
      } on Object catch (e) {
        onError?.call('receipt write failed: $e');
      }
    });
    _tail = next;
    return next;
  }
}
