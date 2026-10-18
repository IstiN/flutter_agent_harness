/// The gh-1680 message-cap self-heal: the host relief typedef, the repair
/// event, and the one-shot heal turn the loop's response stream runs when
/// a provider refuses the request because the message ARRAY exceeded its
/// per-request cap (`array length N exceeds limit M`). Split out of
/// `agent_loop.dart` to keep it under the repo's 2800-line size gate. Same
/// library (a `part of`), so the helpers keep their access to the loop's
/// private members.
part of 'agent_loop.dart';

/// gh-1680: emergency relief for the message-cap self-heal. Called at most
/// once per response when the provider refused the request because the
/// message ARRAY exceeded its per-request cap (`array length N exceeds
/// limit M`). The host runs ONE synchronous compaction pass over the live
/// transcript (the summary is the real message-count reducer; the loop's
/// own coalesce only merges whole tool pairs on the outbound payload) and
/// returns the relieved transcript to retry with — or `null` when nothing
/// hideable remains (the retry then rides the coalesced payload alone;
/// a second refusal surfaces the terminal error). The argument is the
/// loop's live transcript; the returned list REPLACES it for the rest of
/// the run. `null` = no relief configured: the retry still runs once with
/// the coalesced payload (then the refusal is terminal).
typedef MessageCapRelief =
    Future<List<Message>?> Function(List<Message> overCapMessages);

/// Emitted when the gh-1680 message-cap self-heal ran: the provider refused
/// the request because the message ARRAY exceeded its per-request cap
/// (`array length N exceeds limit M`). The cap was learned per model, the
/// outbound payload was coalesced (outbound-only — the session JSONL is
/// byte-identical), and — when the host configured [MessageCapRelief] — a
/// compaction pass ran before the single retry. Repairs are never silent.
final class MessageCapRepairEvent extends AgentEvent {
  const MessageCapRepairEvent({
    required this.messageCount,
    this.learnedCap,
    this.compacted = false,
    this.providerError,
  });

  /// The message count that rode the refused request — the number the
  /// provider's cap refused.
  final int messageCount;

  /// The cap learned from the refusal text; null when the refusal carried
  /// no parseable limit (cap-unknown, edge E1).
  final int? learnedCap;

  /// Whether a host compaction pass ran over the live transcript before
  /// the retry (the [MessageCapRelief] answered non-null).
  final bool compacted;

  /// The raw provider error that triggered the heal.
  final String? providerError;
}

/// Whether a finished turn needs the one-shot message-cap self-heal
/// (gh-1680): a classified cap refusal on an error stop, with a policy
/// configured, before it was used.
bool _needsCapHeal(
  bool capHealed,
  AssistantMessage finished,
  AgentLoopConfig config,
) =>
    !capHealed &&
    finished.stopReason == StopReason.error &&
    config.messageCapPolicy != null &&
    classifyMessageCapError(finished.errorMessage) != null;

/// One message-cap heal step's outcome (mirrors [_OverWindowGuardStep]'s
/// shape): the relieved context to adopt (null = keep the current one),
/// the coalesce target to arm for the retried request (null = cap unknown,
/// nothing to coalesce toward), and the terminal turn for the abort case.
typedef _MessageCapHealStep = ({
  Context? context,
  int? coalesceTarget,
  (AssistantMessage, Context)? terminal,
});

/// The gh-1680 heal turn: learn the cap from the classified refusal, run
/// the host's ONE compaction pass, emit the repair event, and hand the
/// caller the adoption/coalesce instructions for the single retry. A
/// user abort mid-relief ends the run as aborted, never as a retry.
Future<_MessageCapHealStep> _messageCapHealTurn(
  AssistantMessage finished,
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  CancelToken? cancelToken,
  int refusedCount,
) async {
  final refusal = classifyMessageCapError(finished.errorMessage)!;
  config.messageCapPolicy!.learnFromRefusal(config.model, refusal);
  final learned = config.messageCapPolicy!.learnedCapFor(config.model);
  List<Message>? relieved;
  try {
    relieved = await config.messageCapRelief?.call(context.messages);
  } on Object {
    // A failed relief = no relief; the coalesce-only retry still gets its
    // one shot below.
    relieved = null;
  }
  if (_isCancelRequested(cancelToken)) {
    return (
      context: null,
      coalesceTarget: null,
      terminal: await _abortedTurn(context, config, emit),
    );
  }
  await emit(
    MessageCapRepairEvent(
      messageCount: refusedCount,
      learnedCap: learned,
      compacted: relieved != null,
      providerError: finished.errorMessage,
    ),
  );
  return (
    context: relieved == null
        ? null
        : Context(
            systemPrompt: context.systemPrompt,
            messages: relieved,
            tools: context.tools,
          ),
    // The coalesce arms toward `cap − margin`; a cap-unknown refusal
    // (E1) has no target — the retry rides the relief alone.
    coalesceTarget: learned == null ? null : max(1, learned - kMessageCapDefaultMargin),
    terminal: null,
  );
}

/// gh-1680: applies the armed cap coalesce to the request payload. Merges
/// whole tool-call/result pairs and old turns older than the newest user
/// message into compact carriers so the retried request rides fewer
/// messages. Payload-only — the transcript is never touched, so the
/// session JSONL stays byte-identical (AC7).
Context applyMessageCapCoalesce(Context requestContext, int target) {
  final coalesced = coalesceMessagesForCap(
    requestContext.messages,
    targetMessageCount: target,
  );
  if (identical(coalesced, requestContext.messages)) return requestContext;
  return Context(
    systemPrompt: requestContext.systemPrompt,
    messages: coalesced,
    tools: requestContext.tools,
  );
}
