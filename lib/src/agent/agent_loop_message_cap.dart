/// The one-shot self-heal repairs of the response stream: the gh-1680
/// message-cap heal (learn the cap from the provider's refusal, compact +
/// coalesce, retry once) and the issue #85 pairing heal's detection
/// helper plus the [ToolPairingRepairEvent] it emits. Split out of
/// `agent_loop.dart` to keep it under the repo's 2800-line size gate.
/// Same library (a `part of`), so the helpers keep their access to the
/// loop's private members.
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

/// Emitted when the outbound request context needed tool-pairing surgery
/// (issue #85): orphaned tool results dropped, missing results synthesized,
/// or duplicate ids renamed. Repairs are never silent — [report] carries
/// the counts and affected ids, and [providerError] is set when the pass
/// ran in response to a provider pairing error (the self-healing retry).
final class ToolPairingRepairEvent extends AgentEvent {
  const ToolPairingRepairEvent({required this.report, this.providerError});

  /// What the repair changed (empty report = detection only).
  final ToolPairingRepairReport report;

  /// Raw provider error that triggered this pass, when it ran on the
  /// retry path; null for the pre-request repair.
  final String? providerError;
}

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

/// Whether a finished turn needs the one-shot pairing self-heal (issue
/// #85): a provider pairing 400 on an error stop, before it was used.
bool _needsPairingHeal(bool pairingHealed, AssistantMessage finished) =>
    !pairingHealed &&
    finished.stopReason == StopReason.error &&
    isToolPairingProviderError(finished.errorMessage);

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

/// The mutable gh-1680 heal state of one streamed response: whether the
/// one-shot heal already ran, and the coalesce target the next rebuilt
/// payload rides toward (armed by the heal, null when the cap is
/// unknown). Mirrors how `reliefUsed`/`pairingHealed` stay loop-local.
final class _CapHealState {
  bool healed = false;

  /// The coalesce target for `_buildRequestContext` (learned cap −
  /// margin); null = nothing armed / cap unknown.
  int? coalesceTarget;

  /// Runs the one-shot heal when [finished] is a classified cap refusal.
  /// [refusedCount] is the refused payload's message count, captured by
  /// the caller BEFORE the stream (the streamed partial mutates the live
  /// list). [ran] tells the caller to `continue` (retry once); [terminal]
  /// is the abort turn; [context] (non-null on relief) replaces the loop
  /// context for the retry.
  Future<({bool ran, Context? context, (AssistantMessage, Context)? terminal})>
  healIfNeeded(
    AssistantMessage finished,
    Context context,
    AgentLoopConfig config,
    AgentEventSink emit,
    CancelToken? cancelToken,
    int refusedCount,
  ) async {
    if (!_needsCapHeal(healed, finished, config)) {
      return (ran: false, context: null, terminal: null);
    }
    healed = true;
    final step = await _messageCapHealTurn(
      finished,
      context,
      config,
      emit,
      cancelToken,
      refusedCount,
    );
    coalesceTarget = step.coalesceTarget;
    return (
      ran: step.terminal == null,
      context: step.context,
      terminal: step.terminal,
    );
  }
}

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
    coalesceTarget: learned == null
        ? null
        : max(1, learned - kMessageCapDefaultMargin),
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
