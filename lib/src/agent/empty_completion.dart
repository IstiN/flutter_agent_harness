/// The empty-completion classifier (gh-1577): pure Dart, no IO.
///
/// An assistant completion that carries no text and no tool calls is not
/// automatically "the model chose to answer blank" — when the turn already
/// produced partial content (assistant text, tool activity, or a truncation
/// signal on an earlier message), the empty is a provider hiccup in the
/// middle of a task, and settling it as a final answer kills the run with a
/// silent success (the gh-1577 incident: 3 of 5 trials exited 0 mid-task).
///
/// The classifier is the single source of truth shared by the agent loop's
/// bounded-retry machinery (`agent_loop.dart`) and the CLI's empty-reply
/// nudge (`agent_cli.dart`'s compaction part); the truncation signature
/// spans messages, so it is visible only where turn history and stop
/// reasons meet — never inside a provider client.
library;

import '../context.dart';
import '../types.dart';

/// Why an assistant completion ended up (not) empty.
enum EmptyCompletionVerdict {
  /// The completion carries real content — non-whitespace text or tool
  /// calls. No empty-recovery machinery applies.
  notEmpty,

  /// Retryable provider hiccup (gh-1577): the completion is empty AND the
  /// turn already carries partial content — non-whitespace assistant text,
  /// tool activity, or a truncation signal (`StopReason.length` or the
  /// tolerated silent-truncation `errorMessage` flag) on any message of the
  /// turn. The loop retries this boundedly with backoff; on exhaustion the
  /// run ends with an explicit error, never a quiet settle.
  emptyAfterPartial,

  /// A genuine empty final: clean stop, no partial content anywhere in the
  /// turn. Keeps the one-shot `continue` nudge semantics (issue #1085 M2b)
  /// unchanged.
  cleanEmpty,

  /// `StopReason.aborted`/`error` streams are never classified as empty —
  /// their own terminal paths own the run (the pre-existing guard, kept).
  abortedOrError,
}

/// The continuation nudge the loop injects as a user message when a hiccup
/// retry already came back empty once (gh-1603): a cap-truncated reasoning
/// model re-streamed with the identical context burns the same output budget
/// on the same reasoning — the nudge is the signal that breaks the symmetry.
/// Exact-text constant: the classifier recognizes the message by it to keep
/// the turn's partial-content window open across nudged retries (the same
/// marker-recognition pattern as the orphan drop note / stuck-call handback).
const String emptyContinuationNudge =
    'your last reply was empty/truncated — continue the task';

/// Whether [message] is the loop-injected continuation nudge
/// ([emptyContinuationNudge], gh-1603). Exact match — a real user message
/// that merely resembles it still ends the turn window.
bool isContinuationNudgeMessage(Message message) =>
    message is UserMessage && message.content == emptyContinuationNudge;

/// Whether [message]'s content is empty for run-outcome purposes:
/// no non-whitespace text and no tool calls. Thinking content and images do
/// not count as content (a reasoning-only turn with tool calls is NOT empty —
/// the `ToolCall` boundary is gh-1577 invariant 4 and must survive).
bool isEmptyAssistantCompletion(AssistantMessage message) {
  for (final block in message.content) {
    if (block is ToolCall) return false;
    if (block is TextContent && block.text.trim().isNotEmpty) return false;
  }
  return true;
}

/// Classifies [message] against its turn history: the verdict decides
/// between bounded-retry hiccup recovery, the one-shot nudge, and the
/// existing terminal paths.
///
/// The partial-content window is THE TURN — the messages after the last
/// user message in [turnHistory] — so a truncation from an earlier logical
/// turn can never resurrect retries for a fresh, genuinely blank answer
/// (gh-1577 E1). [message] itself is skipped in the scan when it is present
/// in [turnHistory] (both call sites pass the live transcript ending in it);
/// its own truncation flag still counts as evidence, since a stream cut
/// before anything arrived is the strongest hiccup signal there is.
EmptyCompletionVerdict classifyEmptyCompletion(
  List<Message> turnHistory,
  AssistantMessage message,
) {
  if (!isEmptyAssistantCompletion(message)) {
    return EmptyCompletionVerdict.notEmpty;
  }
  if (message.stopReason == StopReason.error ||
      message.stopReason == StopReason.aborted) {
    return EmptyCompletionVerdict.abortedOrError;
  }
  if (_turnCarriesPartialContent(turnHistory, message)) {
    return EmptyCompletionVerdict.emptyAfterPartial;
  }
  return EmptyCompletionVerdict.cleanEmpty;
}

/// Whether the turn window of [turnHistory] (messages after the last user
/// message, excluding [message] itself) carries partial-content evidence:
/// actionable assistant content, tool activity, or a truncation signal.
bool _turnCarriesPartialContent(
  List<Message> turnHistory,
  AssistantMessage message,
) {
  if (_carriesTruncationSignal(message)) return true;
  var sawMessage = false;
  for (final entry in turnHistory.reversed) {
    if (!sawMessage && identical(entry, message)) {
      sawMessage = true;
      continue;
    }
    if (entry is UserMessage) {
      // gh-1603: the loop's own continuation nudge rides mid-turn and must
      // not reset the partial-content window — a nudged retry stays a
      // hiccup. A real user message ends the window.
      if (isContinuationNudgeMessage(entry)) continue;
      break;
    }
    switch (entry) {
      case AssistantMessage():
        if (_assistantEntryCarriesPartial(entry)) return true;
      case ToolResultMessage():
        // Tool activity: the turn did real work before going blank.
        return true;
      default:
        break;
    }
  }
  return false;
}

/// Whether one retained assistant entry in the turn window carries
/// partial-content evidence: actionable content, or a truncation signal.
bool _assistantEntryCarriesPartial(AssistantMessage entry) =>
    !isEmptyAssistantCompletion(entry) || _carriesTruncationSignal(entry);

/// A truncation signal on an assistant message: the token-limit cut, or the
/// tolerated silent truncation (a provider closed the stream without a
/// finish reason — the message is flagged with an errorMessage while keeping
/// a natural `stop`, see the openai-completions adapter).
bool _carriesTruncationSignal(AssistantMessage message) {
  if (message.stopReason == StopReason.length) return true;
  return message.stopReason == StopReason.stop && message.errorMessage != null;
}

/// Backoff before empty-hiccup retry [attempt] (0-based): exponential from
/// [baseDelay], capped at [maxBackoff] — the same shape as the model-roles
/// retry policy (`retry.baseDelayMs`/`retry.maxBackoffMs`), deterministic so
/// tests can pin the sequence (gh-1577 UT-4).
Duration emptyHiccupBackoffFor({
  required int attempt,
  required Duration baseDelay,
  required Duration maxBackoff,
}) {
  var ms = baseDelay.inMilliseconds * (1 << attempt.clamp(0, 20));
  if (ms > maxBackoff.inMilliseconds) ms = maxBackoff.inMilliseconds;
  return Duration(milliseconds: ms);
}

/// The loud exhaustion verdict (gh-1577 AC4): names the hiccup, the retry
/// count, the total attempt count, and the last stop reason. Surfaced as a
/// run error (`StopReason.error`) so the headless exit-code switch maps it
/// to non-zero and the interactive mode prints it and returns to the prompt.
String emptyHiccupExhaustedError({
  required int retryCount,
  required int attempts,
  required StopReason lastStopReason,
}) {
  return 'empty completion after partial content: the model returned no '
      'text and no tool calls in $attempts attempts '
      '($retryCount retries, last stop reason: ${lastStopReason.name}). '
      'The run stopped instead of settling an empty answer — repeat or '
      'rephrase the request.';
}
