/// The one-shot self-heal repairs of the response stream: the gh-1680
/// message-cap heal (learn the cap from the provider's refusal, compact +
/// coalesce, retry once) and the issue #85 pairing heal's detection
/// helper plus the [ToolPairingRepairEvent] it emits. Also hosts the
/// loop's per-attempt body ([_streamAttempt]) and the retry/terminal
/// verdict types both heals resolve to ([_AttemptResult]) — splitting
/// the attempt body out of `_streamAssistantResponse` keeps every unit
/// under the CRAP ceiling, and this file keeps `agent_loop.dart` under
/// the repo's 2800-line size gate. Same library (a `part of`), so the
/// helpers keep their access to the loop's private members.
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

/// Whether a finished turn needs the one-shot image-cap self-heal
/// (issue #1750): a classified image-count refusal on an error stop,
/// before it was used. The kill switch (`images.registry: false`)
/// disables the whole recovery — the refusal surfaces exactly as today
/// (AC6, byte-identical legacy shape).
bool _needsImageCapHeal(
  bool healed,
  AssistantMessage finished,
  AgentLoopConfig config,
) =>
    !healed &&
    finished.stopReason == StopReason.error &&
    imageRegistryConfig.enabled &&
    classifyImageCapError(finished.errorMessage) != null;

/// The mutable image-cap heal state of one streamed response (issue
/// #1750): whether the one-shot heal already ran, and the learned cap
/// the retried request build rides. A second refusal (AC4) surfaces the
/// error exactly as today — no loop.
final class _ImageCapHealState {
  bool healed = false;

  /// The cap learned from the first refusal; null until healed.
  int? learnedCap;

  /// The image-cap override the CURRENT request build rides: the
  /// response-local learned cap, else the run latch for this (provider,
  /// model) pair, else null (the layered seam decides).
  int? overrideFor(AgentLoopConfig config) =>
      learnedCap ??
      config.imageCapLatches?[imageCapLatchKey(
        config.model.provider,
        config.model.id,
      )];

  /// Runs the one-shot heal when [finished] is a classified image-count
  /// refusal: latch the learned cap for the (provider, model) pair
  /// (runtime-only, never persisted), fire the never-silent learned-cap
  /// notice, and tell the caller to retry ONCE — the retry rebuilds
  /// through the registry at the smaller cap (never a stale payload,
  /// E5). A degenerate learned cap (< 1, garbage `is 0`) is
  /// refusal-family only: no re-send, the error surfaces as today (E3).
  bool healIfNeeded(AssistantMessage finished, AgentLoopConfig config) {
    if (!_needsImageCapHeal(healed, finished, config)) return false;
    healed = true;
    final refusal = classifyImageCapError(finished.errorMessage)!;
    if (refusal.learnedCap < 1) return false;
    learnedCap = refusal.learnedCap;
    config.imageCapLatches?[imageCapLatchKey(
          config.model.provider,
          config.model.id,
        )] =
        refusal.learnedCap;
    imageCapLearnedNotice?.call(refusal.modelId, refusal.learnedCap);
    return true;
  }
}

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

/// One iteration of the response-stream retry loop's outcome: either the
/// turn to RETURN to the caller, or an instruction to RETRY the loop
/// with the (possibly adopted) context. The self-heal repairs (gh-1680
/// cap heal, issue #85 pairing heal) and the over-window guard both
/// resolve to this shape, so the loop body stays flat (the CRAP ratchet
/// reads complexity per method — the branching lives in the helpers).
sealed class _AttemptResult {
  const _AttemptResult();
}

/// The terminal turn of the attempt: return it from the loop.
final class _AttemptReturn extends _AttemptResult {
  const _AttemptReturn(this.turn);

  final (AssistantMessage, Context) turn;
}

/// Retry the loop once: adopt [nextContext], updating the cross-attempt
/// one-shot flags that a heal consumed.
final class _AttemptRetry extends _AttemptResult {
  const _AttemptRetry(this.nextContext, {this.reliefUsed, this.pairingHealed});

  final Context nextContext;

  /// The over-window guard's relief flag when the retry came from the
  /// guard; null = unchanged.
  final bool? reliefUsed;

  /// The issue #85 pairing heal's one-shot flag when the retry came from
  /// the pairing self-heal; null = unchanged.
  final bool? pairingHealed;
}

/// The finished-turn self-heals of one streamed attempt: the gh-1680
/// message-cap heal runs FIRST (it may replace the context via the
/// host's relief pass), then the issue #85 pairing heal. Returns null
/// when no heal applied (the caller surfaces the finished turn), else
/// the retry/terminal instruction to act on. Extracted from
/// [_streamAttempt] so the branch handling does not ride in the loop.
Future<_AttemptResult?> _finishedTurnResult(
  AssistantMessage finished,
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  CancelToken? cancelToken,
  _CapHealState capState,
  _ImageCapHealState imageCapState,
  bool pairingHealed,
  int refusedCount,
) async {
  // Issue #1750 self-healing retry: an image-count 400 means the request
  // carried more unique images than the model accepts — latch the
  // learned cap and retry ONCE; the retry rebuilds through the registry
  // at the smaller cap (the drops ride the existing cap-drop notices,
  // never silent). A second refusal surfaces the terminal error (AC4).
  if (imageCapState.healIfNeeded(finished, config)) {
    return _AttemptRetry(context);
  }
  // gh-1680 self-healing retry: a message-cap 400 means the message
  // ARRAY passed the model's per-request cap — learn, compact +
  // coalesce, retry ONCE (a second refusal is terminal; see the part).
  final capHeal = await capState.healIfNeeded(
    finished,
    context,
    config,
    emit,
    cancelToken,
    refusedCount,
  );
  if (capHeal.terminal != null) return _AttemptReturn(capHeal.terminal!);
  if (capHeal.ran) {
    return _AttemptRetry(capHeal.context ?? context);
  }
  // Self-healing retry (issue #85): a provider pairing 400 means the
  // context was corrupted in a shape this repairer missed. Log the
  // detection, re-run the repair over the rebuilt request, retry ONCE —
  // a wedged session recovers here instead of never. A second failure
  // surfaces normally (no infinite loop).
  if (_needsPairingHeal(pairingHealed, finished)) {
    await emit(
      ToolPairingRepairEvent(
        report: const ToolPairingRepairReport(),
        providerError: finished.errorMessage,
      ),
    );
    return _AttemptRetry(context, pairingHealed: true);
  }
  return null;
}

/// One attempt of [_streamAssistantResponse]'s retry loop: builds the
/// request context (pairing repair + armed notes + cap coalesce), runs
/// the mid-turn over-window guard, streams the response, and applies the
/// finished-turn self-heals. Returns the turn to surface to the caller,
/// or a retry instruction for the loop to adopt.
Future<_AttemptResult> _streamAttempt(
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  StreamFunction streamFunction,
  CancelToken? cancelToken, {
  required String? misuseNote,
  required _CapHealState capState,
  required _ImageCapHealState imageCapState,
  required bool reliefUsed,
  required bool pairingHealed,
}) async {
  final (requestContext, repairReport) = await _buildRequestContext(
    context,
    config,
    cancelToken,
    misuseNote: misuseNote,
    capCoalesceTarget: capState.coalesceTarget,
    imageCapOverride: imageCapState.overrideFor(config),
  );
  // Pairing repairs are always surfaced (issue #85): hosts see exactly
  // what was dropped/synthesized/renamed before the request went out.
  if (repairReport.isNotEmpty) {
    await emit(ToolPairingRepairEvent(report: repairReport));
  }

  // Mid-turn over-window guard (issue #387): tool outputs can balloon one
  // turn far past the model window. The cheap window check runs
  // SYNCHRONOUSLY and only an actual overflow awaits
  // [_overWindowGuardTurn] — an unconditional await here yields a
  // microtask on EVERY turn, which reshuffles host event-listener
  // interleaving downstream (issue #1085 CI: the flutter service's
  // persist passes lost the final assistant append). Same shape, no
  // yield on the normal path.
  final window = effectiveContextWindow(
    config.model.contextWindow,
    config.contextWindowCap,
  );
  final tokens = estimateRequestTokens(
    requestContext.messages,
    systemPrompt: requestContext.systemPrompt,
    tools: requestContext.tools ?? const [],
  );
  if (window > 0 && tokens > window) {
    final guard = await _overWindowGuardTurn(
      context,
      requestContext,
      config,
      emit,
      reliefUsed,
      cancelToken,
      window,
      tokens,
    );
    if (guard.terminal != null) return _AttemptReturn(guard.terminal!);
    if (guard.retried) {
      return _AttemptRetry(guard.context, reliefUsed: guard.reliefUsed);
    }
  }

  // gh-1680: refused payload count, captured BEFORE the stream.
  final requestMessageCount = requestContext.messages.length;

  await emit(_captureRequest(config, requestContext));
  final AssistantMessageEventStream response;
  try {
    response = streamFunction(
      config.model,
      requestContext,
      cancelToken: cancelToken,
    );
  } catch (error) {
    return _AttemptReturn(
      await _providerErrorTurn(context, config, emit, error),
    );
  }

  final streamed = await _consumeResponseStream(response, context, emit);
  final finished = streamed.finished;
  if (finished != null) {
    final healed = await _finishedTurnResult(
      finished,
      context,
      config,
      emit,
      cancelToken,
      capState,
      imageCapState,
      pairingHealed,
      requestMessageCount,
    );
    if (healed != null) return healed;
    return _AttemptReturn((finished, context));
  }

  // The provider stream closed without a terminal event (provider bug).
  return _AttemptReturn((
    await _finishWithoutStream(
      context,
      emit,
      _streamEndedWithoutTerminal(config, streamed.partial),
      replaceLast: streamed.addedPartial,
    ),
    context,
  ));
}

/// gh-1680: applies the armed cap coalesce to the request payload, when a
/// target is armed; [target] null = nothing armed, the context rides
/// verbatim. The null check lives here (not at the call site in
/// `_buildRequestContext`) so the request-builder's branch count stays
/// under the CRAP ceiling.
Context _applyMessageCapCoalesce(Context requestContext, int? target) =>
    target == null
    ? requestContext
    : applyMessageCapCoalesce(requestContext, target);

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
