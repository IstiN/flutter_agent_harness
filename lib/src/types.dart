/// Core message, usage, and streaming-event types.
///
/// Ported from pi-mono `packages/ai/src/types.ts`. Kept mechanically close to
/// the TypeScript originals so future pi fixes port trivially. Differences
/// from the original:
///
/// - Union types (`AssistantMessageEvent`, content blocks) are `sealed` class
///   hierarchies instead of discriminated-object unions.
/// - `timestamp` is a [DateTime] instead of Unix milliseconds.
/// - [ToolCall.partialArguments] carries the not-yet-parseable JSON argument
///   fragment while a tool call streams; pi tracks this in adapter-local state.
library;

/// Why the assistant message stream terminated.
///
/// Ported from pi's `StopReason` union.
enum StopReason {
  /// The model finished naturally.
  stop,

  /// The model hit the token limit.
  length,

  /// The model stopped to invoke one or more tools.
  toolUse,

  /// The stream failed (network error, malformed SSE, provider error, ...).
  error,

  /// The stream was cancelled via a `CancelToken`.
  aborted,
}

/// Monetary cost of a request, in USD.
///
/// Ported from pi's `Usage.cost`.
final class UsageCost {
  const UsageCost({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.total = 0,
  });

  /// Cost of input tokens.
  final double input;

  /// Cost of output tokens.
  final double output;

  /// Cost of tokens read from the prompt cache.
  final double cacheRead;

  /// Cost of tokens written to the prompt cache.
  final double cacheWrite;

  /// Total cost.
  final double total;

  UsageCost copyWith({
    double? input,
    double? output,
    double? cacheRead,
    double? cacheWrite,
    double? total,
  }) {
    return UsageCost(
      input: input ?? this.input,
      output: output ?? this.output,
      cacheRead: cacheRead ?? this.cacheRead,
      cacheWrite: cacheWrite ?? this.cacheWrite,
      total: total ?? this.total,
    );
  }
}

/// Token accounting for one assistant response, reported inline by providers.
///
/// Ported from pi's `Usage`.
final class Usage {
  const Usage({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    this.cacheWrite1h,
    this.reasoning,
    required this.totalTokens,
    required this.cost,
  });

  /// Zero-valued usage, used to seed partial messages before the provider
  /// reports real numbers.
  static const zero = Usage(
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: UsageCost(),
  );

  /// Input (prompt) tokens.
  final int input;

  /// Output (completion) tokens.
  final int output;

  /// Tokens read from the prompt cache.
  final int cacheRead;

  /// Tokens written to the prompt cache.
  final int cacheWrite;

  /// Subset of [cacheWrite] written with 1h retention. Only Anthropic reports
  /// this split.
  final int? cacheWrite1h;

  /// Reasoning/thinking tokens, when the provider reports them. This is a
  /// subset of [output]: [output] already includes these tokens. Set by
  /// providers that expose a reasoning breakdown; `null` otherwise.
  final int? reasoning;

  /// Total tokens as reported by the provider.
  final int totalTokens;

  /// Cost breakdown in USD.
  final UsageCost cost;

  Usage copyWith({
    int? input,
    int? output,
    int? cacheRead,
    int? cacheWrite,
    int? cacheWrite1h,
    int? reasoning,
    int? totalTokens,
    UsageCost? cost,
  }) {
    return Usage(
      input: input ?? this.input,
      output: output ?? this.output,
      cacheRead: cacheRead ?? this.cacheRead,
      cacheWrite: cacheWrite ?? this.cacheWrite,
      cacheWrite1h: cacheWrite1h ?? this.cacheWrite1h,
      reasoning: reasoning ?? this.reasoning,
      totalTokens: totalTokens ?? this.totalTokens,
      cost: cost ?? this.cost,
    );
  }
}

/// A content block of an [AssistantMessage].
///
/// Sealed counterpart of pi's `TextContent | ThinkingContent | ToolCall`
/// union (image content arrives with the user/tool-result message types in a
/// later card).
sealed class ContentBlock {
  const ContentBlock();
}

/// Plain text produced by the model.
///
/// Ported from pi's `TextContent`.
final class TextContent extends ContentBlock {
  const TextContent({required this.text, this.textSignature});

  /// The text itself.
  final String text;

  /// Provider-specific opaque signature (e.g. an OpenAI responses message id)
  /// needed to replay this block in multi-turn conversations.
  final String? textSignature;

  TextContent copyWith({String? text, String? textSignature}) {
    return TextContent(
      text: text ?? this.text,
      textSignature: textSignature ?? this.textSignature,
    );
  }
}

/// Model reasoning ("thinking") produced before or alongside the answer.
///
/// Ported from pi's `ThinkingContent`.
final class ThinkingContent extends ContentBlock {
  const ThinkingContent({
    required this.thinking,
    this.thinkingSignature,
    this.redacted = false,
  });

  /// The reasoning text.
  final String thinking;

  /// Provider-specific opaque signature (e.g. an OpenAI responses reasoning
  /// item id, or the encrypted payload when [redacted] is true) needed to
  /// replay this block for multi-turn continuity.
  final String? thinkingSignature;

  /// Whether the thinking content was redacted by safety filters. The opaque
  /// encrypted payload is stored in [thinkingSignature].
  final bool redacted;

  ThinkingContent copyWith({
    String? thinking,
    String? thinkingSignature,
    bool? redacted,
  }) {
    return ThinkingContent(
      thinking: thinking ?? this.thinking,
      thinkingSignature: thinkingSignature ?? this.thinkingSignature,
      redacted: redacted ?? this.redacted,
    );
  }
}

/// A request by the model to invoke a tool.
///
/// Ported from pi's `ToolCall`, plus [partialArguments] for streaming.
final class ToolCall extends ContentBlock {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.thoughtSignature,
    this.partialArguments,
  });

  /// Provider-assigned tool call id (matched by the tool result message).
  final String id;

  /// Name of the tool to invoke.
  final String name;

  /// Parsed tool arguments. Empty while the call is still streaming; see
  /// [partialArguments].
  final Map<String, dynamic> arguments;

  /// Google-specific opaque signature for reusing thought context.
  final String? thoughtSignature;

  /// Raw, not-yet-complete JSON argument text accumulated from
  /// [ToolCallDeltaEvent]s. Providers keep the live partial message's tool
  /// call block up to date with this; on [ToolCallEndEvent] the completed
  /// JSON is parsed into [arguments]. `null` once parsing succeeded.
  final String? partialArguments;

  ToolCall copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? arguments,
    String? thoughtSignature,
    String? partialArguments,
  }) {
    return ToolCall(
      id: id ?? this.id,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
      thoughtSignature: thoughtSignature ?? this.thoughtSignature,
      partialArguments: partialArguments ?? this.partialArguments,
    );
  }
}

/// A message produced by the assistant (the model), final or partial.
///
/// Ported from pi's `AssistantMessage`. The `role` is implicit in the type.
/// Partial instances are the live snapshots carried by every
/// [AssistantMessageEvent] (partial-first design): consumers can render them
/// directly without accumulating deltas themselves.
final class AssistantMessage {
  const AssistantMessage({
    required this.content,
    required this.api,
    required this.provider,
    required this.model,
    this.responseModel,
    this.responseId,
    required this.usage,
    required this.stopReason,
    this.errorMessage,
    required this.timestamp,
  });

  /// Ordered content blocks (text, thinking, tool calls).
  final List<ContentBlock> content;

  /// The API dialect that produced this message (e.g. `openai-completions`,
  /// `anthropic-messages`, `google-generative-ai`).
  final String api;

  /// The provider id (e.g. `openai`, `anthropic`, `openrouter`).
  final String provider;

  /// The requested model id.
  final String model;

  /// Concrete model id reported by the provider, when different from [model]
  /// (e.g. OpenRouter `auto` routing to `anthropic/...`).
  final String? responseModel;

  /// Provider-specific response/message identifier, when exposed upstream.
  final String? responseId;

  /// Token and cost accounting for this response.
  final Usage usage;

  /// Why the stream terminated. On partial snapshots this is the provider's
  /// current best guess (usually [StopReason.stop] until the terminal event).
  final StopReason stopReason;

  /// Human-readable error description when [stopReason] is
  /// [StopReason.error] or [StopReason.aborted].
  final String? errorMessage;

  /// When this message was created (pi stores Unix milliseconds; Dart uses
  /// [DateTime]).
  final DateTime timestamp;

  AssistantMessage copyWith({
    List<ContentBlock>? content,
    String? api,
    String? provider,
    String? model,
    String? responseModel,
    String? responseId,
    Usage? usage,
    StopReason? stopReason,
    String? errorMessage,
    DateTime? timestamp,
  }) {
    return AssistantMessage(
      content: content ?? this.content,
      api: api ?? this.api,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      responseModel: responseModel ?? this.responseModel,
      responseId: responseId ?? this.responseId,
      usage: usage ?? this.usage,
      stopReason: stopReason ?? this.stopReason,
      errorMessage: errorMessage ?? this.errorMessage,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}

/// Event protocol for `AssistantMessageEventStream`.
///
/// Ported from pi's `AssistantMessageEvent` union. Providers emit
/// [StartEvent], then any sequence of text/thinking/tool-call start, delta,
/// and end events, and terminate with exactly one [DoneEvent] or
/// [ErrorEvent].
///
/// Partial-first invariant: every event carries [partial], the live snapshot
/// of the [AssistantMessage] as of this event.
sealed class AssistantMessageEvent {
  const AssistantMessageEvent();

  /// The live partial message as of this event.
  AssistantMessage get partial;
}

/// Emitted once before any content events.
final class StartEvent extends AssistantMessageEvent {
  const StartEvent({required this.partial});

  @override
  final AssistantMessage partial;
}

/// A text content block started at [contentIndex].
final class TextStartEvent extends AssistantMessageEvent {
  const TextStartEvent({required this.contentIndex, required this.partial});

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  @override
  final AssistantMessage partial;
}

/// Incremental text for the block at [contentIndex].
final class TextDeltaEvent extends AssistantMessageEvent {
  const TextDeltaEvent({
    required this.contentIndex,
    required this.delta,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  /// The newly arrived text fragment.
  final String delta;

  @override
  final AssistantMessage partial;
}

/// The text block at [contentIndex] is complete.
final class TextEndEvent extends AssistantMessageEvent {
  const TextEndEvent({
    required this.contentIndex,
    required this.content,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  /// The full text of the completed block.
  final String content;

  @override
  final AssistantMessage partial;
}

/// A thinking content block started at [contentIndex].
final class ThinkingStartEvent extends AssistantMessageEvent {
  const ThinkingStartEvent({required this.contentIndex, required this.partial});

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  @override
  final AssistantMessage partial;
}

/// Incremental thinking text for the block at [contentIndex].
final class ThinkingDeltaEvent extends AssistantMessageEvent {
  const ThinkingDeltaEvent({
    required this.contentIndex,
    required this.delta,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  /// The newly arrived reasoning fragment.
  final String delta;

  @override
  final AssistantMessage partial;
}

/// The thinking block at [contentIndex] is complete.
final class ThinkingEndEvent extends AssistantMessageEvent {
  const ThinkingEndEvent({
    required this.contentIndex,
    required this.content,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  /// The full reasoning text of the completed block.
  final String content;

  @override
  final AssistantMessage partial;
}

/// A tool call started at [contentIndex].
final class ToolCallStartEvent extends AssistantMessageEvent {
  const ToolCallStartEvent({
    required this.contentIndex,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  @override
  final AssistantMessage partial;
}

/// Incremental JSON argument text for the tool call at [contentIndex].
///
/// [delta] is a raw JSON fragment, not parsed arguments; the accumulated
/// fragment is available on [ToolCall.partialArguments] of [partial].
final class ToolCallDeltaEvent extends AssistantMessageEvent {
  const ToolCallDeltaEvent({
    required this.contentIndex,
    required this.delta,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  /// The newly arrived JSON fragment.
  final String delta;

  @override
  final AssistantMessage partial;
}

/// The tool call at [contentIndex] is complete; [toolCall] has fully parsed
/// [ToolCall.arguments].
final class ToolCallEndEvent extends AssistantMessageEvent {
  const ToolCallEndEvent({
    required this.contentIndex,
    required this.toolCall,
    required this.partial,
  });

  /// Index into [AssistantMessage.content] of the block this event concerns.
  final int contentIndex;

  /// The completed tool call with parsed arguments.
  final ToolCall toolCall;

  @override
  final AssistantMessage partial;
}

/// Terminal event: the message completed successfully.
final class DoneEvent extends AssistantMessageEvent {
  const DoneEvent({required this.reason, required this.message});

  /// Why the model stopped. One of [StopReason.stop], [StopReason.length],
  /// or [StopReason.toolUse].
  final StopReason reason;

  /// The final message.
  final AssistantMessage message;

  @override
  AssistantMessage get partial => message;
}

/// Terminal event: the stream failed or was aborted.
///
/// Per the providers-never-throw contract, all provider failures arrive here
/// instead of as exceptions.
final class ErrorEvent extends AssistantMessageEvent {
  const ErrorEvent({required this.reason, required this.error});

  /// Why the stream failed: [StopReason.error] or [StopReason.aborted].
  final StopReason reason;

  /// The final message, with [AssistantMessage.stopReason] set to [reason]
  /// and [AssistantMessage.errorMessage] describing the failure.
  final AssistantMessage error;

  @override
  AssistantMessage get partial => error;
}
