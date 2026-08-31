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

import '../context.dart';
import '../types.dart';

/// Estimated character cost of an image block (pi's `ESTIMATED_IMAGE_CHARS`:
/// 4800 chars ≈ 1200 tokens at 4 chars/token).
const estimatedImageChars = 4800;

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

  if (usageInfo == null) {
    var estimated = 0;
    for (final message in messages) {
      estimated += estimateTokens(message);
    }
    return ContextUsageEstimate(
      tokens: estimated,
      usageTokens: 0,
      trailingTokens: estimated,
      lastUsageIndex: null,
    );
  }

  final usageTokens = calculateContextTokens(usageInfo.usage);
  var trailingTokens = 0;
  for (var i = usageInfo.index + 1; i < messages.length; i++) {
    trailingTokens += estimateTokens(messages[i]);
  }

  return ContextUsageEstimate(
    tokens: usageTokens + trailingTokens,
    usageTokens: usageTokens,
    trailingTokens: trailingTokens,
    lastUsageIndex: usageInfo.index,
  );
}

/// Memoized context estimate for the SETTLED part of a transcript.
///
/// The status line renders on every frame — including every keystroke while
/// the user types over a run. Keying the memo on the message list identity
/// and length ONLY (never on in-flight stream content) makes each streamed
/// delta cost one O(stream) `estimateTokens` instead of a full O(context)
/// re-scan: on a 200k-token transcript that is the difference between
/// ~50 whole-transcript scans per second and none.
final class SettledContextEstimate {
  /// Creates a memo; [estimator] is injectable for tests.
  SettledContextEstimate({int Function(List<Message>)? estimator})
    : _estimator =
          estimator ?? ((messages) => estimateContextTokens(messages).tokens);

  final int Function(List<Message>) _estimator;
  Object? _cachedKey;
  int _cachedValue = 0;

  /// How many times the underlying estimator actually ran (test seam).
  int get estimatorCalls => _estimatorCalls;
  int _estimatorCalls = 0;

  /// Estimate for the settled [messages], recomputed only when the list
  /// identity or length changed (appends, compaction, session switches).
  /// An in-place mutation that keeps both is deliberately NOT tracked —
  /// settled messages are immutable once appended.
  int settled(List<Message> messages) {
    final key = (identityHashCode(messages), messages.length);
    if (key != _cachedKey) {
      _estimatorCalls++;
      _cachedValue = _estimator(messages);
      _cachedKey = key;
    }
    return _cachedValue;
  }
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
