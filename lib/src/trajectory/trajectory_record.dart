/// The trajectory ledger record model: one row of the turn-aware event
/// ledger.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-record.ts` (`TrajectoryCellKind`, `TrajectoryCellProps`
/// data subset). A [TrajectoryRecord] is the pure-Dart projection of one
/// session-tree event; renderers do an exhaustive switch on [TrajectoryCellKind].
library;

import '../types.dart';

/// Closed set of trajectory record kinds.
enum TrajectoryCellKind {
  /// Model/tool-set/checkpoint context changes.
  system,

  /// A user message (turn root or steering).
  user,

  /// Agent instructions, session references, plugin or skill context.
  context,

  /// A compaction or branch summary.
  compacted,

  /// A finalized assistant message.
  message,

  /// A top-level tool call (with its result once it arrives).
  tool,

  /// A nested tool call ([TrajectoryToolRecord.parentCallId] is set).
  subtool,
}

/// Why a [TrajectorySystemRecord] was written.
enum TrajectorySystemChange {
  initial,
  modelChange,
  toolsChange,
  thinkingLevelChange,
  checkpoint,
  contextInject,
  sessionEnd,
  turnEnd,
}

/// One source content block preserved in model order for the details panel.
final class TrajectorySourceBlock {
  /// Creates a [TrajectorySourceBlock].
  const TrajectorySourceBlock({
    required this.type,
    required this.content,
    this.attachmentName,
    this.callId,
    this.toolName,
  });

  /// Block type discriminator (`text`, `thinking`, `toolCall`, `image`).
  final String type;

  /// Text payload (rendered placeholder for images).
  final String content;

  /// Attachment reference name for image blocks.
  final String? attachmentName;

  /// Tool call id for `toolCall` blocks.
  final String? callId;

  /// Tool name for `toolCall` blocks.
  final String? toolName;
}

/// An in-flight streaming content block of a partial assistant message.
final class TrajectoryPartialBlock {
  /// Creates a [TrajectoryPartialBlock].
  const TrajectoryPartialBlock({required this.type, required this.content});

  /// Block type discriminator.
  final String type;

  /// Accumulated text so far.
  final String content;
}

/// Recorded inputs needed to derive assistant TTFT and decode throughput.
final class AssistantMetricDetail {
  /// Creates an [AssistantMetricDetail].
  const AssistantMetricDetail({
    required this.timingRecorded,
    this.stepStartTime,
    this.firstTokenTime,
    this.completedTime,
    required this.usageProvided,
    this.outputTokens,
  });

  /// Whether any wall-clock timing was recorded for the step.
  final bool timingRecorded;

  /// When the request was issued.
  final DateTime? stepStartTime;

  /// Time to first token marker.
  final DateTime? firstTokenTime;

  /// When the response completed.
  final DateTime? completedTime;

  /// Whether the provider reported usage for the step.
  final bool usageProvided;

  /// Output token count, when known.
  final int? outputTokens;
}

/// Character bound of a [TrajectoryRequestMessageSummary.preview].
const int requestPreviewChars = 200;

/// One outbound request message, summarized for the details panel.
final class TrajectoryRequestMessageSummary {
  /// Creates a [TrajectoryRequestMessageSummary].
  const TrajectoryRequestMessageSummary({
    required this.role,
    required this.chars,
    required this.preview,
  });

  /// Role discriminator (`user`, `assistant`, `toolResult`).
  final String role;

  /// JSON-serialized length of the message payload.
  final int chars;

  /// Bounded text preview of the message content.
  final String preview;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'role': role,
    'chars': chars,
    'preview': preview,
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryRequestMessageSummary.fromJson(Map<String, dynamic> json) {
    return TrajectoryRequestMessageSummary(
      role: json['role'] as String? ?? '',
      chars: json['chars'] as int? ?? 0,
      preview: json['preview'] as String? ?? '',
    );
  }
}

/// Cheap outbound-request summary recorded before each provider call.
///
/// Sizes and previews only: the full payload is already in the transcript,
/// so the summary carries just enough for the Request tab to describe what
/// the model was about to receive.
final class TrajectoryRequestDetail {
  /// Creates a [TrajectoryRequestDetail].
  const TrajectoryRequestDetail({
    required this.messageCount,
    required this.systemPromptChars,
    required this.toolCount,
    required this.toolNames,
    required this.messages,
  });

  /// Number of messages in the outbound request.
  final int messageCount;

  /// Length of the system prompt, when one was sent.
  final int systemPromptChars;

  /// Number of tools advertised with the request.
  final int toolCount;

  /// Advertised tool names, in request order.
  final List<String> toolNames;

  /// Per-message summaries, in request order.
  final List<TrajectoryRequestMessageSummary> messages;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'messageCount': messageCount,
    'systemPromptChars': systemPromptChars,
    'toolCount': toolCount,
    'toolNames': toolNames,
    'messages': [for (final message in messages) message.toJson()],
  };

  /// Deserializes from a JSON map produced by [toJson].
  factory TrajectoryRequestDetail.fromJson(Map<String, dynamic> json) {
    return TrajectoryRequestDetail(
      messageCount: json['messageCount'] as int? ?? 0,
      systemPromptChars: json['systemPromptChars'] as int? ?? 0,
      toolCount: json['toolCount'] as int? ?? 0,
      toolNames: [
        for (final name in (json['toolNames'] as List?) ?? const [])
          name as String,
      ],
      messages: [
        for (final message in (json['messages'] as List?) ?? const [])
          TrajectoryRequestMessageSummary.fromJson(
            (message as Map).cast<String, dynamic>(),
          ),
      ],
    );
  }
}

/// Base of the trajectory ledger hierarchy.
///
/// Sealed counterpart of the TS `TrajectoryCellProps` union over record
/// kinds. Every record has a 1-based [index], a stable [recordId], and a
/// [kind] consumed by exhaustive renderer switches.
sealed class TrajectoryRecord {
  /// Creates a [TrajectoryRecord].
  const TrajectoryRecord({required this.index, required this.recordId});

  /// 1-based record index shown as `#N`.
  final int index;

  /// Stable identity surviving prepends of older projected records.
  final String recordId;

  /// Closed-set kind for exhaustive renderer dispatch.
  TrajectoryCellKind get kind;
}

/// A finalized assistant response row (`message` kind).
final class TrajectoryAssistantRecord extends TrajectoryRecord {
  /// Creates a [TrajectoryAssistantRecord].
  const TrajectoryAssistantRecord({
    required super.index,
    required super.recordId,
    required this.messageId,
    required this.turn,
    required this.step,
    this.provider,
    this.model,
    this.usage,
    this.inputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.stepStartTime,
    this.firstTokenTime,
    this.completedTime,
    this.sourceBlocks = const [],
    this.outputBlocks = const [],
    this.partialBlocks = const [],
    this.schemaDetail,
    this.thinkingDetail,
    this.inputDetail,
    this.outputDetail,
    this.promptDetail,
    this.previousPromptDetail,
    this.timeSeconds,
    this.isError,
    this.errorCode,
    this.errorMessage,
    this.requestOnly = false,
    this.displayText = '',
    this.requestDetail,
  });

  /// Outbound-request summary captured before this step's provider call.
  final TrajectoryRequestDetail? requestDetail;

  /// Session record id of the owning message.
  final String messageId;

  /// 1-based model turn this step belongs to.
  final int turn;

  /// 1-based assistant step within [turn].
  final int step;

  /// Provider id, when known.
  final String? provider;

  /// Model id, when known.
  final String? model;

  /// Full token/cost accounting for this response.
  final Usage? usage;

  /// Prompt token count.
  final int? inputTokens;

  /// Input tokens served from a provider cache.
  final int? cacheReadTokens;

  /// Input tokens written into a provider cache.
  final int? cacheWriteTokens;

  /// Completion token count.
  final int? outputTokens;

  /// Reasoning token count, when reported.
  final int? reasoningTokens;

  /// Wall-clock time the request was issued.
  final DateTime? stepStartTime;

  /// Time-to-first-token marker.
  final DateTime? firstTokenTime;

  /// Wall-clock time the response completed.
  final DateTime? completedTime;

  /// Original message blocks in source order.
  final List<TrajectorySourceBlock> sourceBlocks;

  /// Finalized output blocks in source order.
  final List<TrajectorySourceBlock> outputBlocks;

  /// In-flight streaming blocks (finalized rows keep this empty).
  final List<TrajectoryPartialBlock> partialBlocks;

  /// Call-time model-visible tool schema (markdown).
  final String? schemaDetail;

  /// Full reasoning text.
  final String? thinkingDetail;

  /// Full request content (markdown).
  final String? inputDetail;

  /// Full response content (markdown).
  final String? outputDetail;

  /// Conversation prompt snapshot introduced with this step (markdown).
  final String? promptDetail;

  /// Conversation prompt snapshot replaced by this step (markdown).
  final String? previousPromptDetail;

  /// Wall-clock duration; null while the step is running.
  final Duration? timeSeconds;

  /// Whether the response failed or was aborted.
  final bool? isError;

  /// Provider/machine error code, when known.
  final String? errorCode;

  /// Human-readable error description.
  final String? errorMessage;

  /// Whether the row is a request-only separator without a message record.
  final bool requestOnly;

  /// Fallback row label when the message has no visible content.
  final String displayText;

  @override
  TrajectoryCellKind get kind => TrajectoryCellKind.message;
}

/// A tool (or nested subtool) call row with its result once it arrives.
final class TrajectoryToolRecord extends TrajectoryRecord {
  /// Creates a [TrajectoryToolRecord].
  const TrajectoryToolRecord({
    required super.index,
    required super.recordId,
    required this.callId,
    required this.parentCallId,
    required this.name,
    required this.argsRaw,
    this.result = '',
    this.resultPreviewMarkdown,
    this.isError = false,
    this.timeSeconds,
    this.startedAt,
  });

  /// Provider-assigned tool call id.
  final String callId;

  /// Call id of the enclosing tool call, or null for a top-level call.
  final String? parentCallId;

  /// Invoked tool name.
  final String name;

  /// Raw JSON arguments of the call.
  final String argsRaw;

  /// Result text; empty while the call is running.
  final String result;

  /// Raw Markdown source of the result summary.
  final String? resultPreviewMarkdown;

  /// Whether the tool execution failed.
  final bool isError;

  /// Own duration; null while running.
  final Duration? timeSeconds;

  /// Wall-clock start of the execution, when known.
  final DateTime? startedAt;

  @override
  TrajectoryCellKind get kind => parentCallId == null
      ? TrajectoryCellKind.tool
      : TrajectoryCellKind.subtool;

  /// A copy with the result of the call applied.
  TrajectoryToolRecord withResult({
    required String result,
    required bool isError,
    Duration? timeSeconds,
  }) {
    return TrajectoryToolRecord(
      index: index,
      recordId: recordId,
      callId: callId,
      parentCallId: parentCallId,
      name: name,
      argsRaw: argsRaw,
      result: result,
      resultPreviewMarkdown: resultPreviewMarkdown ?? result,
      isError: isError,
      timeSeconds: timeSeconds ?? this.timeSeconds,
      startedAt: startedAt,
    );
  }

  /// A copy with the execution start stamped.
  TrajectoryToolRecord withStartedAt(DateTime startedAt) {
    return TrajectoryToolRecord(
      index: index,
      recordId: recordId,
      callId: callId,
      parentCallId: parentCallId,
      name: name,
      argsRaw: argsRaw,
      result: result,
      resultPreviewMarkdown: resultPreviewMarkdown,
      isError: isError,
      timeSeconds: timeSeconds,
      startedAt: startedAt,
    );
  }
}

/// A user message row (`user` kind).
final class TrajectoryUserRecord extends TrajectoryRecord {
  /// Creates a [TrajectoryUserRecord].
  const TrajectoryUserRecord({
    required super.index,
    required super.recordId,
    required this.text,
    this.previewMarkdown,
    this.sourceBlocks = const [],
    required this.opensTurn,
    this.inputDetail,
    this.startedAt,
    this.sourceSeq,
  });

  /// Plain-text content of the message.
  final String text;

  /// Raw Markdown source of the single-line summary.
  final String? previewMarkdown;

  /// Original content blocks in source order.
  final List<TrajectorySourceBlock> sourceBlocks;

  /// Whether this message opens a new model turn (no parent user message).
  final bool opensTurn;

  /// Full request content for the details panel (markdown).
  final String? inputDetail;

  /// Wall-clock time the message was appended.
  final DateTime? startedAt;

  /// Source event seq for cross-record navigation, when the host has one.
  final int? sourceSeq;

  @override
  TrajectoryCellKind get kind => TrajectoryCellKind.user;
}

/// An application context-injection row (`context` kind).
final class TrajectoryContextRecord extends TrajectoryRecord {
  /// Creates a [TrajectoryContextRecord].
  const TrajectoryContextRecord({
    required super.index,
    required super.recordId,
    required this.text,
    this.previewMarkdown,
    this.sourceSeq,
    this.startedAt,
  });

  /// Plain-text content of the injection.
  final String text;

  /// Raw Markdown source of the single-line summary.
  final String? previewMarkdown;

  /// Source event seq for cross-record navigation, when the host has one.
  final int? sourceSeq;

  /// Wall-clock time the injection was appended, when known.
  final DateTime? startedAt;

  @override
  TrajectoryCellKind get kind => TrajectoryCellKind.context;
}

/// A compaction or branch-summary row (`compacted` kind).
final class TrajectoryCompactedRecord extends TrajectoryRecord {
  /// Creates a [TrajectoryCompactedRecord].
  const TrajectoryCompactedRecord({
    required super.index,
    required super.recordId,
    required this.text,
    required this.summary,
    this.firstKeptEntryId,
    this.timeSeconds,
    this.startedAt,
    this.interrupted = false,
  });

  /// Bounded preview of the summary.
  final String text;

  /// Full summary text.
  final String summary;

  /// Id of the first record kept verbatim after the summary.
  final String? firstKeptEntryId;

  /// How long the compaction took; null when unknown.
  final Duration? timeSeconds;

  /// Wall-clock time the compaction completed.
  final DateTime? startedAt;

  /// Whether the compaction was interrupted before it finished.
  final bool interrupted;

  @override
  TrajectoryCellKind get kind => TrajectoryCellKind.compacted;
}

/// A session-state change row (`system` kind).
final class TrajectorySystemRecord extends TrajectoryRecord {
  /// Creates a [TrajectorySystemRecord].
  const TrajectorySystemRecord({
    required super.index,
    required super.recordId,
    required this.text,
    required this.change,
    this.detail,
    this.time,
    this.errorCode,
    this.errorMessage,
  });

  /// Short human-readable description of the change.
  final String text;

  /// Which session-level state changed.
  final TrajectorySystemChange change;

  /// Full change detail (markdown), when the host records one.
  final String? detail;

  /// Wall-clock time of the change.
  final DateTime? time;

  /// Error code for a failed turn end, when known.
  final String? errorCode;

  /// Error description for a failed turn end.
  final String? errorMessage;

  @override
  TrajectoryCellKind get kind => TrajectoryCellKind.system;
}

/// Resolves the identity that survives prepending older projected records.
///
/// Ported from the TS `trajectoryRecordId`: an explicit [recordId] wins,
/// then the owning tool [callId], then the host [sourceSeq], and finally the
/// [index] fixture fallback.
String trajectoryRecordId({
  required String kind,
  String? recordId,
  String? callId,
  int? sourceSeq,
  required int index,
}) {
  if (recordId != null) return recordId;
  if (callId != null) return '$kind\u0000call\u0000$callId';
  if (sourceSeq != null) return '$kind\u0000seq\u0000$sourceSeq';
  return '$kind\u0000index\u0000$index';
}
