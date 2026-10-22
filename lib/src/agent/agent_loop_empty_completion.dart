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
///
/// gh-1603: the first re-stream replays the plain request; from the second
/// on, the request carries the [emptyContinuationNudge] user message — a
/// cap-truncated reasoning model re-streamed verbatim repeats the empty
/// outcome, the nudge is the new signal that breaks the symmetry. The
/// classifier treats the exact nudge message as transparent, so the turn's
/// partial-content window survives a nudged retry.
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
      if (delay > Duration.zero) {
        // E7: race the sleep against the token — a cancel landing during
        // the backoff wakes immediately instead of stalling for up to
        // [AgentLoopConfig.emptyHiccupMaxBackoff]. The next
        // `_streamAssistantResponse` short-circuits into `_abortedTurn`.
        await Future.any<void>([
          Future<void>.delayed(delay),
          if (cancelToken != null) cancelToken.onCancel,
        ]);
      }
      hiccup++;
    }
    // gh-1603: the FIRST re-stream replays the plain request; from the
    // second on, the previous retry already came back empty — inject the
    // continuation nudge so the request carries new signal (a cap-truncated
    // reasoning model re-streamed verbatim repeats the empty outcome). The
    // MessageStart/End pair lands the nudge in the host transcript and
    // session record (same as steering injections — a truthful record, the
    // gh-1577 invariant); the classifier treats the exact nudge message as
    // transparent, so the turn's partial-content window survives it.
    if (generic + hiccup >= 2) {
      final nudge = UserMessage.text(emptyContinuationNudge);
      await emit(MessageStartEvent(nudge));
      await emit(MessageEndEvent(nudge));
      out.messages.add(nudge);
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
  // the classification — the abort wins over ANY empty shape (a clean
  // `stop`, a `length` cut, or the tolerated silent-truncation flag): a
  // truncation-flagged empty that settles as the run final leaves headless
  // at exit 0 on an aborted run. Settle the explicit aborted terminal
  // instead — never the hiccup error, never a silent empty success. An
  // already-aborted terminal (the `_streamAssistantResponse` short-circuit)
  // is left as-is: converting it again would duplicate the emission.
  if (_needsAbortedTerminal(cancelled, current)) {
    current = await _finishWithoutStream(
      out,
      emit,
      _terminalMessage(config.model, StopReason.aborted, 'Operation aborted'),
    );
  }
  return (current, out);
}

/// The E5 settle condition: the run was cancelled after (or with) the last
/// empty completion, and the current terminal is not already the explicit
/// aborted one — it is a silent empty shape the abort must win over.
bool _needsAbortedTerminal(bool cancelled, AssistantMessage current) =>
    cancelled &&
    current.stopReason != StopReason.aborted &&
    isEmptyAssistantCompletion(current);
