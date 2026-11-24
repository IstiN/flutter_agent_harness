/// The hand-over call's robustness ladder (GOAL #2394 D1 — AC4): ONE
/// logical call over the S0 prefix + the appended instruction, at most
/// three round-trips, and NO fallback — neither to the classic prefix
/// compactor nor to any judge ladder. Every rung keeps the prefix
/// byte-identical (`[...S0.messages, instruction]`), so the provider
/// serves it from the bucket the main request just warmed:
///
/// - (a) an answer carrying tool calls (an adapter without `tool_choice`
///   or a model that disobeyed) → ONE nudge message appended after the
///   instruction; the tool-call answer itself is never appended (it would
///   orphan its calls); tools stay in the request — a tool-less retry
///   would break the prefix and the bucket (N4);
/// - (b) a provider error / network drop rides the global transient
///   retry that already wraps every host's catalog stream — same body,
///   same prefix; what still fails is a failure;
/// - (c) `stopReason == length` → ONE retry of the same request with the
///   output budget doubled; a second `length` is exhausted;
/// - (d) the output budget is explicit (`compaction.handOver.maxTokens`,
///   default [handOverMaxTokensDefault]);
/// - (e) an exhausted ladder is a FAILED call: the engine appends nothing
///   and reports loudly; the engine never changes.
library;

import '../../agent/agent_loop.dart' show StreamCallShape, StreamFunction;
import '../../cancel_token.dart' show CancelToken;
import '../../context.dart';
import '../../exceptions.dart' show CompactionException;
import '../../model.dart' show Model;
import '../../types.dart';
import '../cache_policy.dart';

/// The default output budget of the hand-over call
/// (`compaction.handOver.maxTokens`, D1 (d)).
const int handOverMaxTokensDefault = 8192;

/// The ONE nudge appended after a tool-call answer (D1a) — text only,
/// never the tool-call message itself.
const String handOverNudgeText =
    'Answer with the hide list and the hand-over text only; no tool calls.';

/// The final outcome of the ladder.
final class HandOverCallResult {
  const HandOverCallResult._({
    this.response,
    this.failure,
    required this.calls,
    required this.nudges,
    required this.budgetRetries,
    this.cacheHitRatio,
  });

  /// The usable answer (text, stopped normally), `null` on failure.
  final AssistantMessage? response;

  /// The failure — a provider/stream error or the exhausted-ladder
  /// verdict; `null` on success.
  final Object? failure;

  /// Real round-trips this logical call consumed (nudge and budget retry
  /// included) — the report's `calls`.
  final int calls;

  /// Nudge round-trips (0 or 1).
  final int nudges;

  /// Output-budget retries (0 or 1).
  final int budgetRetries;

  /// The share of input tokens the provider served from cache across the
  /// call's round-trips — `null` when the provider reported no usage
  /// (never a fake zero, gh-2097).
  final double? cacheHitRatio;

  /// Whether the call produced a usable answer.
  bool get ok => failure == null && response != null;
}

/// The engine-facing hand-over call: the S0 context with the instruction
/// already appended as its last message.
typedef HandOverCall =
    Future<HandOverCallResult> Function(
      Context context, {
      CancelToken? cancelToken,
    });

/// Builds the [HandOverCall] adapter over a provider [stream] and the
/// session's [model]. Routing is the policy's ([CompactionCachePolicy
/// .sessionAffine] — the session's own bucket through NULL fallthrough);
/// the request shape (`tool_choice: none`, the output budget, the history
/// breakpoint at [prefixLength] = S0's last message, the pinned Copilot
/// initiator) travels in the same zone. [onDelta] mirrors text/thinking
/// deltas to the host's busy row; [onUsage] receives every round-trip's
/// provider usage.
HandOverCall handOverCallAdapter({
  required StreamFunction stream,
  required Model model,
  required CompactionCachePolicy cachePolicy,
  int maxTokens = handOverMaxTokensDefault,
  required int prefixLength,
  String? copilotInitiator,
  void Function(String delta)? onDelta,
  void Function(Usage usage)? onUsage,
}) {
  return (Context context, {CancelToken? cancelToken}) async {
    // The prefix is copied once; only the nudge ever appends to it.
    var messages = List<Message>.of(context.messages);
    var budget = maxTokens;
    var nudges = 0;
    var budgetRetries = 0;
    var calls = 0;
    final usage = CompactionUsageAccumulator();
    HandOverCallResult fail(Object failure) => HandOverCallResult._(
      failure: failure,
      calls: calls,
      nudges: nudges,
      budgetRetries: budgetRetries,
      cacheHitRatio: usage.snapshot().cacheHitRatio,
    );
    while (true) {
      final AssistantMessage response;
      try {
        final shape = StreamCallShape(
          toolChoice: 'none',
          maxTokens: budget,
          prefixLength: prefixLength,
          copilotInitiator: copilotInitiator,
        );
        final events = cachePolicy.runWith(
          () => stream(
            model,
            Context(
              systemPrompt: context.systemPrompt,
              messages: messages,
              tools: context.tools,
            ),
            cancelToken: cancelToken,
          ),
          CompactionCallClass.handOver,
          shape: shape,
        );
        if (onDelta != null) {
          events.listen((event) {
            final delta = switch (event) {
              TextDeltaEvent(:final delta) => delta,
              ThinkingDeltaEvent(:final delta) => delta,
              _ => null,
            };
            if (delta != null && delta.isNotEmpty) onDelta(delta);
          });
        }
        response = await events.result;
      } on Object catch (error) {
        // A throwing StreamFunction breaks the never-throw contract — the
        // pipeline is defensive anyway.
        return fail(error);
      }
      calls++;
      _foldUsage(response, onUsage, usage);
      switch (response.stopReason) {
        case StopReason.error:
          return fail(
            CompactionException(
              'hand-over call failed: ${response.errorMessage ?? 'unknown error'}',
            ),
          );
        case StopReason.aborted:
          return fail(
            CompactionException(
              'hand-over call aborted: ${response.errorMessage ?? 'aborted'}',
            ),
          );
        default:
          break;
      }
      if (_hasToolCalls(response)) {
        if (nudges >= 1) {
          return fail(
            const CompactionException(
              'hand-over call returned tool calls again after the nudge '
              '(ladder exhausted)',
            ),
          );
        }
        nudges++;
        messages = [...messages, UserMessage.text(handOverNudgeText)];
        continue;
      }
      if (response.stopReason == StopReason.length) {
        if (budgetRetries >= 1) {
          return fail(
            CompactionException(
              'hand-over call hit the output budget twice '
              '($budget tokens; ladder exhausted)',
            ),
          );
        }
        budgetRetries++;
        budget *= 2;
        continue;
      }
      return HandOverCallResult._(
        response: response,
        calls: calls,
        nudges: nudges,
        budgetRetries: budgetRetries,
        cacheHitRatio: usage.snapshot().cacheHitRatio,
      );
    }
  };
}

/// Whether the answer carries tool calls (whatever the stop reason says —
/// an adapter may stop `end_turn` with a tool_use block in some SDKs).
bool _hasToolCalls(AssistantMessage response) =>
    response.content.any((block) => block is ToolCall);

/// Forwards one round-trip's usage to the host sink (zero usage reports
/// nothing) and folds it into the call's cache ratio.
void _foldUsage(
  AssistantMessage response,
  void Function(Usage usage)? sink,
  CompactionUsageAccumulator into,
) {
  final usage = response.usage;
  if (usage.totalTokens == 0 &&
      usage.input == 0.0 &&
      usage.cacheRead == 0.0 &&
      usage.cacheWrite == 0.0) {
    return;
  }
  sink?.call(usage);
  into.add(usage);
}
