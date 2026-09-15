/// Trajectory-owned conversion from durable session records to ledger fields.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-event-projection.ts` plus the node-level projection rules of
/// `layout.ts` (`inputCellDetail`, `expandAssistant`, `summarize*`). Pure
/// functions: no builder state, no IO.
library;

import 'dart:convert';

import '../context.dart';
import '../session/session_record.dart';
import '../types.dart';
import 'trajectory_preview.dart';
import 'trajectory_record.dart';

/// Own-duration seconds from two stamps; null when either side is unknown.
///
/// Ported from the TS `durationSeconds`: negative gaps clamp to zero.
Duration? trajectoryDurationSeconds(DateTime? later, DateTime? earlier) {
  if (later == null || earlier == null) return null;
  final difference = later.difference(earlier);
  return difference.isNegative ? Duration.zero : difference;
}

/// Sums token/cost accounting across requests for the cumulative fold.
///
/// Null [Usage] on either side passes the other through; a missing reasoning
/// breakdown stays missing unless both sides report one.
Usage? accumulateUsage(Usage? cumulative, Usage? next) {
  if (next == null) return cumulative;
  if (cumulative == null) return next;
  final reasoning = (cumulative.reasoning ?? 0) + (next.reasoning ?? 0);
  return cumulative.copyWith(
    input: cumulative.input + next.input,
    output: cumulative.output + next.output,
    cacheRead: cumulative.cacheRead + next.cacheRead,
    cacheWrite: cumulative.cacheWrite + next.cacheWrite,
    cacheWrite1h: cumulative.cacheWrite1h == null && next.cacheWrite1h == null
        ? null
        : (cumulative.cacheWrite1h ?? 0) + (next.cacheWrite1h ?? 0),
    reasoning: reasoning == 0 ? null : reasoning,
    totalTokens: cumulative.totalTokens + next.totalTokens,
    cost: UsageCost(
      input: cumulative.cost.input + next.cost.input,
      output: cumulative.cost.output + next.cost.output,
      cacheRead: cumulative.cost.cacheRead + next.cost.cacheRead,
      cacheWrite: cumulative.cost.cacheWrite + next.cost.cacheWrite,
      total: cumulative.cost.total + next.cost.total,
    ),
  );
}

/// Projects one content block into a details-panel source block.
TrajectorySourceBlock trajectorySourceBlock(ContentBlock block) {
  return switch (block) {
    TextContent(:final text) => TrajectorySourceBlock(
      type: 'text',
      content: text,
    ),
    ThinkingContent(:final thinking) => TrajectorySourceBlock(
      type: 'thinking',
      content: thinking,
    ),
    ToolCall(
      :final id,
      :final name,
      :final arguments,
      :final partialArguments,
    ) =>
      TrajectorySourceBlock(
        type: 'tool-call',
        content: partialArguments ?? jsonEncode(arguments),
        callId: id,
        toolName: name,
      ),
    ImageContent(:final mimeType) => TrajectorySourceBlock(
      type: 'image',
      content: '',
      attachmentName: mimeType,
    ),
  };
}

/// Text of the text blocks, blank-line separated (TS `expandAssistant`).
String textOfBlocks(List<ContentBlock> content) => [
  for (final block in content)
    if (block is TextContent) block.text,
].join('\n\n');

/// Thinking text of the reasoning blocks, blank-line separated.
String thinkingOfBlocks(List<ContentBlock> content) => [
  for (final block in content)
    if (block is ThinkingContent) block.thinking,
].join('\n\n');

/// Plain-text payload of a String or content-block message body.
String textPayloadOf(Object content) {
  if (content is String) return content;
  if (content is! List<ContentBlock>) return '';
  return [
    for (final block in content)
      if (block is TextContent) block.text,
  ].join('\n\n');
}

/// Detail text of the text blocks, newline separated (TS `detailContent`).
String detailTextOf(Iterable<ContentBlock> content) => [
  for (final block in content)
    if (block is TextContent) block.text,
].join('\n');

/// Row label for a message with no visible text or reasoning.
///
/// Ported from TS `summarizeAssistantActivity`: tool-call-only rows label
/// themselves, then image-only rows; text/thinking content labels nothing
/// (the preview carries it).
String assistantDisplayText(List<ContentBlock> content) {
  if (textOfBlocks(content).isNotEmpty ||
      thinkingOfBlocks(content).isNotEmpty) {
    return '';
  }
  final tools = content.whereType<ToolCall>().toList();
  if (tools.isNotEmpty) return 'Tool call only';
  final images = content.whereType<ImageContent>().length;
  if (images > 0) return 'Images ×$images';
  return '';
}

/// Projects a user message record into a fully-populated user row.
TrajectoryUserRecord projectUserRecord({
  required MessageRecord record,
  required int index,
  required String recordId,
  required bool opensTurn,
}) {
  final message = record.message as UserMessage;
  final text = textPayloadOf(message.content);
  final blocks = message.content is List<ContentBlock>
      ? message.content as List<ContentBlock>
      : const <ContentBlock>[];
  return TrajectoryUserRecord(
    index: index,
    recordId: recordId,
    text: text,
    previewMarkdown: text,
    sourceBlocks: [for (final block in blocks) trajectorySourceBlock(block)],
    opensTurn: opensTurn,
    inputDetail: detailTextOf(blocks),
    startedAt: record.timestamp,
  );
}

/// Projects an assistant message record into a fully-populated message row.
///
/// Wall-clock timing degrades to what the record carries: the completion
/// time is exact, while the request start falls back to the previous ledger
/// record's stamp (TS `durationSeconds(node.time, recordedStart ??
/// prevAbsTime)`); TTFT needs the streaming event stream and stays null.
TrajectoryAssistantRecord projectAssistantRecord({
  required MessageRecord record,
  required AssistantMessage message,
  required int index,
  required String recordId,
  required int turn,
  required int step,
  DateTime? previousTime,
  TrajectoryRequestDetail? requestDetail,
}) {
  final failed =
      message.stopReason == StopReason.error ||
      message.stopReason == StopReason.aborted;
  final output = textOfBlocks(message.content);
  final thinking = thinkingOfBlocks(message.content);
  final sourceBlocks = [
    for (final block in message.content) trajectorySourceBlock(block),
  ];
  return TrajectoryAssistantRecord(
    index: index,
    recordId: recordId,
    messageId: record.id,
    turn: turn,
    step: step,
    provider: message.provider,
    model: message.model,
    usage: message.usage,
    inputTokens: message.usage.input,
    cacheReadTokens: message.usage.cacheRead,
    cacheWriteTokens: message.usage.cacheWrite,
    outputTokens: message.usage.output,
    reasoningTokens: message.usage.reasoning,
    completedTime: message.timestamp,
    sourceBlocks: sourceBlocks,
    outputBlocks: sourceBlocks,
    displayText: assistantDisplayText(message.content),
    outputDetail: output.isEmpty ? null : output,
    thinkingDetail: thinking.isEmpty ? null : thinking,
    timeSeconds: trajectoryDurationSeconds(message.timestamp, previousTime),
    isError: failed,
    errorMessage: message.errorMessage,
    requestDetail: requestDetail,
  );
}

/// Projects a compaction or branch-summary record into a compacted row.
TrajectoryCompactedRecord projectCompactedRecord({
  required SessionRecord record,
  required int index,
  required String recordId,
  required String summary,
  String? firstKeptEntryId,
  DateTime? previousTime,
  List<String>? hiddenRecordIds,
}) {
  return TrajectoryCompactedRecord(
    index: index,
    recordId: recordId,
    text: trajectoryPreviewText(summary),
    summary: summary,
    firstKeptEntryId: firstKeptEntryId,
    timeSeconds: trajectoryDurationSeconds(record.timestamp, previousTime),
    startedAt: record.timestamp,
    hiddenRecordIds: hiddenRecordIds,
  );
}

/// Projects a tool result into the settled fields of its tool row.
({String result, bool isError, Duration? timeSeconds}) projectToolResult({
  required ToolResultMessage result,
  DateTime? callTime,
}) {
  return (
    result: textPayloadOf(result.content),
    isError: result.isError,
    timeSeconds: trajectoryDurationSeconds(result.timestamp, callTime),
  );
}

/// One drill-in row of a hidden range (issue #385 F4): a bounded preview
/// of a record the compaction evicted from the context but the session
/// file still holds.
final class TrajectoryHiddenRecordPreview {
  /// Creates a preview row.
  const TrajectoryHiddenRecordPreview({
    required this.id,
    required this.type,
    required this.preview,
    this.timestamp,
  });

  /// The covered record's id.
  final String id;

  /// The record's durable type label (message, tool, system, …).
  final String type;

  /// Bounded text preview; `[hidden: unparseable record]` for records
  /// with no text payload — never fabricated content.
  final String preview;

  /// The record's wall-clock time, when known.
  final DateTime? timestamp;
}

/// Character bound of a hidden-record preview.
const int hiddenRecordPreviewChars = 200;

/// Maximum drill-in rows served for one hidden range (E4: an open tail
/// range and a giant range both resolve bounded).
const int hiddenRecordPreviewLimit = 500;

/// Builds the bounded drill-in previews for the records a hidden range
/// covers, in the order the caller supplies (chain order when the caller
/// read the file). Records that resolved to nothing render as explicit
/// `[hidden: not captured for this session]` placeholders (E6) — never
/// fake content.
List<TrajectoryHiddenRecordPreview> projectHiddenRecordPreviews({
  required List<String> recordIds,
  required Map<String, SessionRecord> resolved,
}) {
  return [
    for (final id in recordIds.take(hiddenRecordPreviewLimit))
      () {
        final record = resolved[id];
        if (record == null) {
          return TrajectoryHiddenRecordPreview(
            id: id,
            type: 'missing',
            preview: '[hidden: not captured for this session]',
          );
        }
        final text = switch (record) {
          MessageRecord(:final message) => switch (message) {
            UserMessage(:final content) => textPayloadOf(content),
            AssistantMessage(:final content) => textPayloadOf(content),
            ToolResultMessage(:final content) => textPayloadOf(content),
            _ => '',
          },
          _ => '',
        };
        return TrajectoryHiddenRecordPreview(
          id: id,
          type: record.runtimeType.toString(),
          preview: text.isEmpty
              ? '[hidden: unparseable record]'
              : (text.length <= hiddenRecordPreviewChars
                    ? text
                    : '${text.substring(0, hiddenRecordPreviewChars)}…'),
          timestamp: record.timestamp,
        );
      }(),
  ];
}
