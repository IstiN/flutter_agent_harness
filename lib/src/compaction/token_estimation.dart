/// Token estimation for context compaction.
///
/// Ported from pi-mono `packages/agent/src/harness/compaction/compaction.ts`
/// (`estimateTokens`, `calculateContextTokens`, `estimateContextTokens`).
/// The heuristic is deliberately crude and provider-agnostic: **4 characters
/// per token**, with images estimated at 4800 chars (≈ 1200 tokens). When a
/// provider has reported real usage on an assistant message, that number is
/// trusted for everything up to and including that message, and only the
/// trailing messages are estimated.
library;

import 'dart:convert';

import '../agent/image_registry.dart' show imageContentKey;
import '../context.dart';
import '../types.dart';

/// Estimated character cost of an image block (pi's `ESTIMATED_IMAGE_CHARS`:
/// 4800 chars ≈ 1200 tokens at 4 chars/token).
const estimatedImageChars = 4800;

/// Wire-replacement charge for an image the registry already rides
/// earlier in the request (an `[Image N]` label plus overhead).
const estimatedRepeatImageChars = 32;

/// The content key estimation dedups against — a public seam pinned to
/// [imageContentKey] so the estimator and the registry never drift.
String estimationImageKey(ImageContent image) => imageContentKey(image);

/// Characters per token in pi's conservative heuristic.
const _charsPerToken = 4;

/// Calculate total context tokens from provider usage.
///
/// Ported from pi's `calculateContextTokens`: prefers [Usage.totalTokens]
/// when the provider reported it, otherwise sums the components.
int calculateContextTokens(Usage usage) {
  return usage.totalTokens != 0
      ? usage.totalTokens
      : usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
}

int _textAndImageChars(Object content) {
  if (content is String) return content.length;
  var chars = 0;
  for (final block in content as List<ContentBlock>) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ImageContent():
        chars += estimatedImageChars;
      default:
    }
  }
  return chars;
}

/// Estimate token count for one message using pi's character heuristic.
///
/// - `user` / `toolResult`: text chars + [estimatedImageChars] per image.
/// - `assistant`: text + thinking chars, plus tool call name and JSON-encoded
///   arguments.
int estimateTokens(Message message) {
  final chars = switch (message) {
    UserMessage(:final content) => _textAndImageChars(content),
    AssistantMessage(:final content) => _assistantChars(content),
    ToolResultMessage(:final content) => _textAndImageChars(content),
    _ => 0,
  };
  return (chars / _charsPerToken).ceil();
}

int _assistantChars(List<ContentBlock> content) {
  var chars = 0;
  for (final block in content) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ThinkingContent(:final thinking):
        chars += thinking.length;
      case ToolCall(:final name, :final arguments):
        chars += name.length + _safeJsonEncode(arguments).length;
      default:
    }
  }
  return chars;
}

String _safeJsonEncode(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '[unserializable]';
  }
}

/// Estimated context-token usage for a message list.
///
/// Ported from pi's `ContextUsageEstimate`.
final class ContextUsageEstimate {
  /// Creates a [ContextUsageEstimate].
  const ContextUsageEstimate({
    required this.tokens,
    required this.usageTokens,
    required this.trailingTokens,
    required this.lastUsageIndex,
  });

  /// An empty estimate (no messages, no anchor).
  static const empty = ContextUsageEstimate(
    tokens: 0,
    usageTokens: 0,
    trailingTokens: 0,
    lastUsageIndex: null,
  );

  /// Estimated total context tokens.
  final int tokens;

  /// Tokens reported by the most recent assistant usage block.
  final int usageTokens;

  /// Estimated tokens after the most recent assistant usage block.
  final int trailingTokens;

  /// Index of the message that provided usage, or `null` when none exists.
  final int? lastUsageIndex;
}

Usage? _assistantUsage(Message message) {
  if (message case AssistantMessage(:final stopReason, :final usage)) {
    if (stopReason != StopReason.aborted &&
        stopReason != StopReason.error &&
        calculateContextTokens(usage) > 0) {
      return usage;
    }
  }
  return null;
}

/// Estimate context tokens for [messages] using provider usage when
/// available.
///
/// Ported from pi's `estimateContextTokens`: the last assistant message with
/// valid usage (not errored/aborted, non-zero tokens) anchors the estimate;
/// everything after it is estimated heuristically. Without any usage, the
/// whole list is estimated.
ContextUsageEstimate estimateContextTokens(List<Message> messages) {
  ({Usage usage, int index})? usageInfo;
  for (var i = messages.length - 1; i >= 0; i--) {
    final usage = _assistantUsage(messages[i]);
    if (usage != null) {
      usageInfo = (usage: usage, index: i);
      break;
    }
  }

  // F5: the registry dedups repeated images on the wire to short
  // `[Image N]` labels — mirror that here, or the transcript-side
  // estimate diverges from the request the provider actually prices.
  final seenImages = <String>{};
  int charged(Message message) => _estimateTokensDedup(message, seenImages);
  if (usageInfo == null) {
    var estimated = 0;
    for (final message in messages) {
      estimated += charged(message);
    }
    return ContextUsageEstimate(
      tokens: estimated,
      usageTokens: 0,
      trailingTokens: estimated,
      lastUsageIndex: null,
    );
  }

  // The anchor era still seeds the seen-set so trailing repeats stay
  // cheap even when their first occurrence predates the anchor.
  for (var i = 0; i <= usageInfo.index; i++) {
    charged(messages[i]);
  }
  var trailingTokens = 0;
  for (var i = usageInfo.index + 1; i < messages.length; i++) {
    trailingTokens += charged(messages[i]);
  }

  final usageTokens = calculateContextTokens(usageInfo.usage);
  return ContextUsageEstimate(
    tokens: usageTokens + trailingTokens,
    usageTokens: usageTokens,
    trailingTokens: trailingTokens,
    lastUsageIndex: usageInfo.index,
  );
}

/// Estimated token cost of the request parts that are NOT transcript
/// messages: the system prompt and the tool schemas (name + description +
/// JSON-encoded parameters), at pi's 4-chars-per-token heuristic.
///
/// Every wire request carries these, but [estimateContextTokens] never
/// counts them — they only enter an ANCHORED estimate implicitly, through
/// the provider-reported usage. An unanchored estimate (fresh or resumed
/// session, provider without usage reporting) silently drops them: a
/// 30 KB system prompt plus ~30 tool schemas is tens of thousands of
/// tokens the ctx meter and the over-window guard then ignore.
int estimateRequestOverheadTokens(String? systemPrompt, List<Tool> tools) {
  var chars = systemPrompt?.length ?? 0;
  for (final tool in tools) {
    chars +=
        tool.name.length +
        tool.description.length +
        _safeJsonEncode(tool.parameters).length;
  }
  return (chars / _charsPerToken).ceil();
}

/// Full next-request estimate — the ONE basis the ctx meter, the loop's
/// over-window guard, and the compaction threshold all enforce.
///
/// [estimateContextTokens] over [messages], plus
/// [estimateRequestOverheadTokens] when no provider-usage anchor prices
/// the system prompt and tool schemas in. An anchored estimate already
/// includes them (the reported usage is the whole previous request), so
/// adding the overhead there would double-count.
int estimateRequestTokens(
  List<Message> messages, {
  String? systemPrompt,
  List<Tool> tools = const [],
}) {
  final estimate = estimateContextTokens(messages);
  if (estimate.lastUsageIndex != null) return estimate.tokens;
  return estimate.tokens + estimateRequestOverheadTokens(systemPrompt, tools);
}

/// [estimateTokens] against a first-seen set: repeated images charge the
/// wire replacement, not a second payload. Per-message [estimateTokens]
/// keeps charging every occurrence (no cross-message context there).
int _estimateTokensDedup(Message message, Set<String> seenImages) {
  List<ContentBlock>? blocks;
  if (message is UserMessage && message.content is List<ContentBlock>) {
    blocks = message.content as List<ContentBlock>;
  } else if (message is ToolResultMessage) {
    blocks = message.content;
  }
  if (blocks == null) return estimateTokens(message);
  var chars = 0;
  for (final block in blocks) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ImageContent():
        chars += seenImages.add(estimationImageKey(block))
            ? estimatedImageChars
            : estimatedRepeatImageChars;
      default:
    }
  }
  return (chars / _charsPerToken).ceil();
}

/// Memoized context estimate for the SETTLED part of a transcript.
///
/// The status line renders on every frame — including every keystroke while
/// the user types over a run. Keying the memo on the message list LENGTH
/// and the LAST message's identity (never on in-flight stream content)
/// makes each streamed delta cost one O(stream) `estimateTokens` instead
/// of a full O(context) re-scan: on a 200k-token transcript that is the
/// difference between ~50 whole-transcript scans per second and none.
///
/// The key deliberately survives list COPIES: `AgentState.messages`
/// hands out a fresh `List.unmodifiable` wrapper on every read, so a
/// whole-list identity key would miss on every single frame. Settled
/// messages are immutable once appended, so (length, last-instance)
/// changes exactly when the settled estimate can change: appends grow
/// the length, compaction/session switches replace the last instance.
final class SettledContextEstimate {
  /// Creates a memo; [estimator] is injectable for tests.
  SettledContextEstimate({
    ContextUsageEstimate Function(List<Message>)? estimator,
  }) : _estimator = estimator ?? estimateContextTokens;

  final ContextUsageEstimate Function(List<Message>) _estimator;
  Object? _cachedKey;
  ContextUsageEstimate _cachedValue = ContextUsageEstimate.empty;

  /// How many times the underlying estimator actually ran (test seam).
  int get estimatorCalls => _estimatorCalls;
  int _estimatorCalls = 0;

  /// Estimate for the settled [messages], recomputed only when the list
  /// length or the last message instance changed (appends, compaction,
  /// session switches). An in-place mutation that keeps both is
  /// deliberately NOT tracked — settled messages are immutable once
  /// appended.
  ContextUsageEstimate settledEstimate(List<Message> messages) {
    final key = (
      messages.length,
      messages.isEmpty ? null : identityHashCode(messages.last),
    );
    if (key != _cachedKey) {
      _estimatorCalls++;
      _cachedValue = _estimator(messages);
      _cachedKey = key;
    }
    return _cachedValue;
  }

  /// The token total of [settledEstimate].
  int settled(List<Message> messages) => settledEstimate(messages).tokens;
}

/// Drops generation-time [AssistantMessage.usage] anchors from messages
/// loaded off disk.
///
/// A usage anchor reflects the context the message was GENERATED in — after
/// a compaction, the projected branch is far smaller than those anchors
/// (a 27k projection whose last assistant message still reports 183k). Left
/// in place, the estimate anchors at the phantom size: every resume fired a
/// no-op compaction pass and the context gauge lied. Zeroing re-anchors the
/// estimate at the chars/4 heuristic over the REAL projected context; the
/// first live turn stamps fresh usage again.
///
/// Non-assistant messages and zero-anchored assistants pass through as the
/// same instances (no copy churn on the hot load path).
List<Message> resetLoadedUsageAnchors(List<Message> messages) => [
  for (final message in messages)
    if (message is AssistantMessage && message.usage.totalTokens != 0)
      message.copyWith(usage: Usage.zero)
    else
      message,
];
