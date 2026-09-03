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
  );
}

/// Projects a compaction or branch-summary record into a compacted row.
TrajectoryCompactedRecord projectCompactedRecord({
  required SessionRecord record,
  required int index,
  required String recordId,
  required String summary,
  String? firstKeptEntryId,
}) {
  return TrajectoryCompactedRecord(
    index: index,
    recordId: recordId,
    text: trajectoryPreviewText(summary),
    summary: summary,
    firstKeptEntryId: firstKeptEntryId,
    startedAt: record.timestamp,
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
