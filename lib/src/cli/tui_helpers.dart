/// Pure, testable helpers extracted from the AgentCli TUI glue: the
/// queued-message drain loop, the post-run leftover-steering decision, and
/// a bounds-safe list index.
library;

import '../context.dart';
import '../types.dart';

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

/// The outcome of [resolveLeftoverSteering]: the drained steering texts
/// plus whether they should start a fresh turn ([run]) or be dropped
/// loudly (an interrupt invalidated them mid-flight).
typedef LeftoverSteering = ({bool run, List<String> texts});

/// Pure decision for steering messages still queued after a run settled.
///
/// Steering normally lands at a turn boundary inside the run; messages
/// that missed every drain point (raced past the last poll, or the run
/// was interrupted) used to sit in the queue until an UNRELATED later
/// run — or forever. [run] reloads them as the next turn's prompt;
/// an abort drops them, but the caller shows the texts so nothing
/// silently disappears. Returns null when nothing is left to settle.
LeftoverSteering? resolveLeftoverSteering({
  required List<Message> Function() drain,
  required bool abortRequested,
}) {
  final leftovers = drain();
  final texts = [
    for (final message in leftovers)
      if (message is UserMessage) _userMessageText(message),
  ].where((text) => text.trim().isNotEmpty).toList();
  if (texts.isEmpty) return null;
  return (run: !abortRequested, texts: texts);
}

/// The text of a user message (string or content-block content).
String _userMessageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
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
