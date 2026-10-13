/// The empty-completion retry machinery (gh-1577): an empty assistant
/// completion that follows PARTIAL content — assistant text, tool activity,
/// or a truncation signal earlier in the turn — is a retryable provider
/// hiccup, never a settleable final answer. The turn's partial content is
/// visible only here, where the loop history and stop reasons meet; provider
/// clients stay untouched (the truncation signature spans messages).
///
/// Two bounded budgets drive the loop, checked in order:
/// - `config.maxEmptyRetries` — the legacy degenerate-empty budget (any
///   empty completion; the app host default is 1, the CLI wires 0 and owns
///   clean empties with its one-shot `continue` nudge instead, so the
///   transcript reflects the retry explicitly — issue #1085 M2b).
/// - `config.emptyHiccupRetries` — the gh-1577 hiccup budget, spent only on
///   `emptyAfterPartial` verdicts ([classifyEmptyCompletion]), with
///   exponential backoff. On exhaustion the run ends with an explicit
///   `StopReason.error` naming the hiccup — the headless exit-code switch
///   maps it to non-zero and the interactive mode prints it and returns to
///   the prompt — instead of the silent exit-0 settle that killed the
///   gh-1577 trials mid-task.
part of 'agent_loop.dart';

/// See the library doc above.
Future<(AssistantMessage, Context)> retryEmptyCompletion(
  AssistantMessage message,
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  StreamFunction streamFunction,
  CancelToken? cancelToken,
) async {
  var generic = 0;
  var hiccup = 0;
  var current = message;
  var out = context;
  var cancelled = _isCancelRequested(cancelToken);
  while (!cancelled) {
    final verdict = classifyEmptyCompletion(out.messages, current);
    // Healthy completions and aborted/errored streams keep their own paths.
    if (verdict == EmptyCompletionVerdict.notEmpty ||
        verdict == EmptyCompletionVerdict.abortedOrError) {
      break;
    }
    if (generic < config.maxEmptyRetries) {
      generic++;
    } else if (verdict == EmptyCompletionVerdict.cleanEmpty) {
      // A genuine empty final: the host's nudge/settle semantics own it
      // (issue #1085 M2b, pinned unchanged by gh-1577 AC2).
      break;
    } else if (hiccup >= config.emptyHiccupRetries) {
      // gh-1577 exhaustion verdict: retries are spent and the completion is
      // still empty — end the run LOUDLY instead of settling a silent
      // success. An abort that raced the classification wins instead (E5):
      // the exhaustion error is never printed over an aborted run.
      current = await _finishWithoutStream(
        out,
        emit,
        _terminalMessage(
          config.model,
          StopReason.error,
          emptyHiccupExhaustedError(
            retryCount: generic + hiccup,
            attempts: 1 + generic + hiccup,
            lastStopReason: current.stopReason,
          ),
        ),
      );
      break;
    } else {
      final delay = emptyHiccupBackoffFor(
        attempt: hiccup,
        baseDelay: config.emptyHiccupBaseDelay,
        maxBackoff: config.emptyHiccupMaxBackoff,
      );
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      hiccup++;
    }
    (current, out) = await _streamAssistantResponse(
      out,
      config,
      emit,
      streamFunction,
      cancelToken,
    );
    cancelled = _isCancelRequested(cancelToken);
  }
  // E5: the abort landed with (or after) the last empty completion, before
  // the classification — the abort wins. Settle aborted, never as the
  // hiccup error and never as a silent empty success.
  if (cancelled && _isDegenerateEmpty(current)) {
    current = await _finishWithoutStream(
      out,
      emit,
      _terminalMessage(config.model, StopReason.aborted, 'Operation aborted'),
    );
  }
  return (current, out);
}
