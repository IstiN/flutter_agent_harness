/// Pure, testable helpers extracted from the AgentCli TUI glue: the
/// queued-message drain loop and a bounds-safe list index. The post-run
/// leftover-steering decision lives in the steering extension itself
/// (its reconcile consumes FIFO entries by object identity — issue
/// #2249), so it is no longer extractable as a text-only pure function.
library;

/// Drains queued messages one-by-one as separate turns (kimi-cli
/// semantics), capped at [maxRounds] to bound a self-sustaining queue; an
/// abort discards the queue instead of starting new work ([onDropped] is
/// called in both stop-early cases with the texts that were discarded —
/// a silent drop looks exactly like a lost message to the user).
Future<void> drainQueueRounds({
  required Future<List<String>> Function() drain,
  required Future<void> Function(List<String> queued) runRound,
  required bool Function() abortRequested,
  required void Function(List<String> dropped) onDropped,
  int maxRounds = 20,
}) async {
  var rounds = 0;
  for (;;) {
    final queued = await drain();
    if (queued.isEmpty) return;
    if (abortRequested() || rounds >= maxRounds) {
      onDropped(queued);
      return;
    }
    rounds++;
    await runRound(queued);
  }
}

/// Runs every queued message as its own turn, waiting for each to settle
/// and stopping early when an abort discards the rest of the queue.
Future<void> runQueuedTurns({
  required List<String> queued,
  required Future<void> Function(String message) handle,
  required Future<void> Function() settled,
  required bool Function() abortRequested,
}) async {
  for (final msg in queued) {
    await handle(msg);
    await settled();
    if (abortRequested()) break;
  }
}

/// The element at [index] in [list], or null when the list is null or the
/// index is out of bounds.
T? listItemAt<T>(List<T>? list, int index) {
  if (list == null || index < 0 || index >= list.length) return null;
  return list[index];
}
