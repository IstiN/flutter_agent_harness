/// The gh-1934 413 image-payload recovery ladder: a provider rejecting a
/// request for SIZE (`413`-class, `isPayloadTooLargeError`) never ends in
/// an unusable session. Bounded at TWO recovery passes per streamed
/// response, each refusal halving the session's adaptive image budget:
///
/// - **Pass 1** — drop the oldest images until the payload rides under
///   the halved adaptive budget (the registry's byte-budget fill; config
///   still honored when lower), and retry.
/// - **Pass 2** — halve again AND strip ALL images to `[image dropped:
///   …]` placeholders (the session-wide strip-all latch), and retry.
/// - **Exhausted** — ONE actionable failure notice (`switch provider or
///   lower images.maxBytesPerRequest`) and the provider error surfaces
///   exactly as before. No loops: the strip-all latch keeps every later
///   request of the session image-free, so neither the ladder nor a
///   compaction⇄413 cycle can re-engage on the same bytes.
///
/// Same family as the #1750 image-cap heal (a count refusal) and the
/// gh-1680 message-cap heal — this one is the SIZE refusal twin. The
/// kill switch (`images.registry: false`) and a missing
/// [AgentLoopConfig.imageRecovery] state disable the whole ladder: the
/// error surfaces as today (AC6, legacy shape).
part of 'agent_loop.dart';

/// Emitted when the gh-1934 recovery ladder ran: the request was refused
/// for SIZE, the adaptive budget was halved (and — pass 2 — every image
/// stripped to a placeholder), and the payload was rebuilt through the
/// registry. Repairs are never silent: [dropped]/[stripped] carry the
/// counts the rebuilt request rode, and [failed] marks the single
/// actionable exhaustion event.
final class ImagePayloadRecoveryEvent extends AgentEvent {
  const ImagePayloadRecoveryEvent({
    required this.pass,
    required this.dropped,
    required this.stripped,
    this.failed = false,
    this.providerError,
  });

  /// The ladder pass that ran (1 = budget drop, 2 = strip-all).
  final int pass;

  /// Images dropped by the halved adaptive budget.
  final int dropped;

  /// Image blocks stripped to `[image dropped: …]` placeholders.
  final int stripped;

  /// Whether the ladder exhausted (the provider still refuses): fired
  /// once, then the error surfaces as before.
  final bool failed;

  /// The raw provider error behind a [failed] event.
  final String? providerError;
}

/// Whether the request window carries image bytes the ladder could shed —
/// ImageContent blocks, plus the text-embedded data-URL shapes the
/// #1916 fold lifts into blocks at rewrite time (a legacy 413 session
/// must reach the ladder too). A text-only window never engages the
/// ladder (AC6).
bool _windowHasImages(List<Message> messages) {
  bool blocksHaveImages(List<ContentBlock> blocks) => blocks.any(
    (block) =>
        block is ImageContent ||
        (block is TextContent && block.text.contains('data:image/')),
  );
  for (final message in messages) {
    switch (message) {
      case UserMessage(:final content):
        if (content is String) {
          if (content.contains('data:image/')) return true;
        } else if (blocksHaveImages(content as List<ContentBlock>)) {
          return true;
        }
      case ToolResultMessage(:final content):
        if (blocksHaveImages(content)) return true;
      default:
    }
  }
  return false;
}

/// Whether a finished turn needs the gh-1934 413 recovery ladder: a
/// classified payload-size refusal on an error stop, with the recovery
/// state attached and the registry alive, before the ladder exhausted —
/// and only when the window actually carries image bytes (a text-only
/// 413 belongs to the provider, not to images).
bool _needsImage413Recovery(
  bool exhausted,
  AssistantMessage finished,
  Context context,
  AgentLoopConfig config,
) =>
    !exhausted &&
    finished.stopReason == StopReason.error &&
    imageRegistryConfig.enabled &&
    config.imageRecovery != null &&
    isPayloadTooLargeError(finished.errorMessage) &&
    _windowHasImages(context.messages);

/// The mutable gh-1934 ladder state of one streamed response: whether the
/// ladder exhausted (no more passes) and how many passes ran. Mirrors how
/// the other self-heal states stay response-local while the session-level
/// consequences (budget, strip-all latch) ride
/// [AgentLoopConfig.imageRecovery].
final class _Image413RecoveryState {
  bool exhausted = false;
  int passes = 0;

  /// Runs the ladder step when [finished] is a classified 413. Returns
  /// the retry instruction, or null when the error must surface (no
  /// recovery configured, text-only window, ladder exhausted — after
  /// emitting the ONE actionable failure event, AC4).
  Future<_AttemptResult?> healIfNeeded(
    AssistantMessage finished,
    Context context,
    AgentLoopConfig config,
    AgentEventSink emit,
  ) async {
    if (!_needsImage413Recovery(exhausted, finished, context, config)) {
      return null;
    }
    final recovery = config.imageRecovery!;
    if (passes >= 2) {
      exhausted = true;
      final event = ImageRecoveryEvent(
        pass: 2,
        dropped: 0,
        stripped: 0,
        failed: true,
        providerError: finished.errorMessage,
      );
      imageRecoveryNotice?.call(event);
      await emit(
        ImagePayloadRecoveryEvent(
          pass: 2,
          dropped: 0,
          stripped: 0,
          failed: true,
          providerError: finished.errorMessage,
        ),
      );
      return null;
    }
    passes++;
    final pass = passes;
    // Each 413 halves the adaptive budget (AC4) — pass 1 learns, pass 2
    // halves again before the strip.
    recovery.halveBudget(imageRegistryConfig.maxBytesPerRequest);
    if (pass == 2) recovery.stripAll = true;
    recovery.armNote(pass: pass);
    return _AttemptRetry(context);
  }
}

/// gh-1934: an armed 413 recovery note rides the NEXT request payload as a
/// trailing user message — the model sees why its images vanished and the
/// assistant answer can note the recovery (AC1). Payload-only; the note is
/// one-shot (consumed by this build, re-armed by the next pass).
Context _appendRecoveryNote(Context context, ImagePayloadRecoveryState? rec) {
  final note = rec?.consumeNote();
  if (note == null) return context;
  return Context(
    systemPrompt: context.systemPrompt,
    messages: [...context.messages, UserMessage.text(note)],
    tools: context.tools,
  );
}
