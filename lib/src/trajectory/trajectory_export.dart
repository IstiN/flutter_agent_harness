/// Lossless and human-readable exports of a trajectory snapshot.
///
/// `exportTrajectoryJson` round-trips every ledger field (the JSON shape is
/// the export contract for downstream tooling); `exportTrajectoryMarkdown`
/// renders the same snapshot as readable Markdown with turns as sections and
/// full content in fenced blocks. Pure functions: no IO.
library;

import 'dart:convert';

import 'trajectory_record.dart';
import 'trajectory_snapshot.dart';

/// Serializes [snapshot] to a pretty-printed JSON string with full fidelity:
/// every record keeps its kind, turn/step, timestamps, full texts, raw tool
/// arguments, results, error fields, request summaries, and usage.
String exportTrajectoryJson(TrajectorySnapshot snapshot) {
  return const JsonEncoder.withIndent('  ').convert({
    'revision': snapshot.revision,
    'records': [for (final record in snapshot.records) _recordJson(record)],
    'requests': [
      for (final request in snapshot.requests) _requestJson(request),
    ],
  });
}

/// Renders [snapshot] as readable Markdown: one `##` section per model turn,
/// one `###` row per record, full texts and tool payloads in fenced blocks.
String exportTrajectoryMarkdown(TrajectorySnapshot snapshot) {
  final buffer = StringBuffer('# Trajectory export\n');
  var turn = 0;
  var shownTurn = 0;
  for (final record in snapshot.records) {
    final recordTurn = switch (record) {
      TrajectoryAssistantRecord(:final turn) => turn,
      TrajectoryUserRecord(:final opensTurn) => opensTurn ? turn + 1 : null,
      _ => null,
    };
    if (recordTurn != null) turn = recordTurn;
    if (turn != shownTurn && turn > 0) {
      buffer
        ..write('\n## Turn $turn\n')
        ..write('\n');
      shownTurn = turn;
    }
    buffer
      ..write(_markdownRow(record))
      ..write('\n');
  }
  return buffer.toString();
}

String _markdownRow(TrajectoryRecord record) => switch (record) {
  TrajectoryAssistantRecord(:final step, :final provider, :final model) =>
    '### #${record.index} assistant'
        ' · step $step${provider == null ? '' : ' · $provider/$model'}'
        '${_mdAssistant(record)}',
  TrajectoryToolRecord() => _mdTool(record),
  TrajectoryUserRecord() =>
    '### #${record.index} user\n${_mdFence(record.text)}',
  TrajectoryContextRecord() =>
    '### #${record.index} context\n${_mdFence(record.text)}',
  TrajectoryCompactedRecord() =>
    '### #${record.index} compacted\n${_mdFence(record.summary)}',
  TrajectorySystemRecord(:final change) =>
    '### #${record.index} system · ${change.name}\n${_mdFence(record.text)}',
};

String _mdAssistant(TrajectoryAssistantRecord record) {
  final buffer = StringBuffer();
  if (record.isError ?? false) {
    buffer.write(
      ' · ERROR'
      '${record.errorMessage == null ? '' : ': ${record.errorMessage}'}',
    );
  }
  final thinking = record.thinkingDetail;
  if (thinking != null && thinking.isNotEmpty) {
    buffer
      ..write('\n\n_thinking_\n')
      ..write(_mdFence(thinking));
  }
  final output = record.outputDetail;
  if (output != null && output.isNotEmpty) {
    buffer
      ..write('\n\n')
      ..write(_mdFence(output));
  }
  final detail = record.requestDetail;
  if (detail != null) {
    buffer
      ..write(
        '\n\n_request_ ${detail.messageCount} messages,'
        ' system ${detail.systemPromptChars} chars,'
        ' ${detail.toolCount} tools (${detail.toolNames.join(', ')})\n',
      )
      ..write(
        [
          for (final message in detail.messages)
            '- `${message.role}` ${message.chars} chars:'
                ' ${message.preview.replaceAll('\n', ' ')}',
        ].join('\n'),
      );
  }
  if (record.usage != null) {
    buffer.write('\n\n_tokens_ ${record.usage!.toJson()}');
  }
  return buffer.toString();
}

String _mdTool(TrajectoryToolRecord record) {
  final buffer = StringBuffer()
    ..write('#### #${record.index} tool `${record.name}` `${record.callId}`')
    ..write(record.isError ? ' · ERROR\n' : '\n')
    ..write('arguments:\n')
    ..write(_mdFence(record.argsRaw, language: 'json'));
  if (record.result.isNotEmpty || record.isError) {
    buffer
      ..write('\nresult:\n')
      ..write(_mdFence(record.result));
  }
  return buffer.toString();
}

/// Wraps [content] in a four-backtick fence so embedded triple-backtick
/// code blocks inside model output cannot break the export.
String _mdFence(String content, {String? language}) {
  return '````${language ?? ''}\n$content\n````\n';
}

Map<String, dynamic> _recordJson(TrajectoryRecord record) {
  final json = <String, dynamic>{
    'index': record.index,
    'recordId': record.recordId,
    'kind': record.kind.name,
  };
  switch (record) {
    case TrajectoryAssistantRecord(
      :final messageId,
      :final turn,
      :final step,
      :final provider,
      :final model,
      :final usage,
      :final inputTokens,
      :final cacheReadTokens,
      :final cacheWriteTokens,
      :final outputTokens,
      :final reasoningTokens,
      :final stepStartTime,
      :final firstTokenTime,
      :final completedTime,
      :final sourceBlocks,
      :final outputBlocks,
      :final partialBlocks,
      :final schemaDetail,
      :final thinkingDetail,
      :final inputDetail,
      :final outputDetail,
      :final promptDetail,
      :final previousPromptDetail,
      :final timeSeconds,
      :final isError,
      :final errorCode,
      :final errorMessage,
      :final requestOnly,
      :final displayText,
      :final requestDetail,
    ):
      json.addAll({
        'messageId': messageId,
        'turn': turn,
        'step': step,
        'provider': provider,
        'model': model,
        'usage': usage?.toJson(),
        'inputTokens': inputTokens,
        'cacheReadTokens': cacheReadTokens,
        'cacheWriteTokens': cacheWriteTokens,
        'outputTokens': outputTokens,
        'reasoningTokens': reasoningTokens,
        'stepStartTime': _timestamp(stepStartTime),
        'firstTokenTime': _timestamp(firstTokenTime),
        'completedTime': _timestamp(completedTime),
        'sourceBlocks': _sourceBlocksJson(sourceBlocks),
        'outputBlocks': _sourceBlocksJson(outputBlocks),
        'partialBlocks': [
          for (final block in partialBlocks)
            {'type': block.type, 'content': block.content},
        ],
        'schemaDetail': schemaDetail,
        'thinkingDetail': thinkingDetail,
        'inputDetail': inputDetail,
        'outputDetail': outputDetail,
        'promptDetail': promptDetail,
        'previousPromptDetail': previousPromptDetail,
        'timeSeconds': _duration(timeSeconds),
        'isError': isError,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
        'requestOnly': requestOnly,
        'displayText': displayText,
        'requestDetail': requestDetail?.toJson(),
      });
    case TrajectoryToolRecord(
      :final callId,
      :final parentCallId,
      :final name,
      :final argsRaw,
      :final result,
      :final resultPreviewMarkdown,
      :final isError,
      :final timeSeconds,
      :final startedAt,
    ):
      json.addAll({
        'callId': callId,
        'parentCallId': parentCallId,
        'name': name,
        'argsRaw': argsRaw,
        'result': result,
        'resultPreviewMarkdown': resultPreviewMarkdown,
        'isError': isError,
        'timeSeconds': _duration(timeSeconds),
        'startedAt': _timestamp(startedAt),
      });
    case TrajectoryUserRecord(
      :final text,
      :final previewMarkdown,
      :final sourceBlocks,
      :final opensTurn,
      :final inputDetail,
      :final startedAt,
      :final sourceSeq,
    ):
      json.addAll({
        'text': text,
        'previewMarkdown': previewMarkdown,
        'sourceBlocks': _sourceBlocksJson(sourceBlocks),
        'opensTurn': opensTurn,
        'inputDetail': inputDetail,
        'startedAt': _timestamp(startedAt),
        'sourceSeq': sourceSeq,
      });
    case TrajectoryContextRecord(
      :final text,
      :final previewMarkdown,
      :final sourceSeq,
      :final startedAt,
    ):
      json.addAll({
        'text': text,
        'previewMarkdown': previewMarkdown,
        'sourceSeq': sourceSeq,
        'startedAt': _timestamp(startedAt),
      });
    case TrajectoryCompactedRecord(
      :final text,
      :final summary,
      :final firstKeptEntryId,
      :final timeSeconds,
      :final startedAt,
      :final interrupted,
    ):
      json.addAll({
        'text': text,
        'summary': summary,
        'firstKeptEntryId': firstKeptEntryId,
        'timeSeconds': _duration(timeSeconds),
        'startedAt': _timestamp(startedAt),
        'interrupted': interrupted,
      });
    case TrajectorySystemRecord(
      :final text,
      :final change,
      :final detail,
      :final time,
      :final errorCode,
      :final errorMessage,
    ):
      json.addAll({
        'text': text,
        'change': change.name,
        'detail': detail,
        'time': _timestamp(time),
        'errorCode': errorCode,
        'errorMessage': errorMessage,
      });
  }
  return json;
}

Map<String, dynamic> _requestJson(TrajectoryRequestNumber request) => {
  'seq': request.seq,
  'turn': request.turn,
  'step': request.step,
  'purpose': request.purpose.name,
  'provider': request.provider,
  'model': request.model,
  'status': request.status.name,
  'startedAt': _timestamp(request.startedAt),
  'completedAt': _timestamp(request.completedAt),
  'usage': request.usage?.toJson(),
  'cumulativeUsage': request.cumulativeUsage?.toJson(),
};

List<Map<String, dynamic>> _sourceBlocksJson(
  List<TrajectorySourceBlock> blocks,
) => [
  for (final block in blocks)
    {
      'type': block.type,
      'content': block.content,
      'attachmentName': block.attachmentName,
      'callId': block.callId,
      'toolName': block.toolName,
    },
];

String? _timestamp(DateTime? time) => time?.toIso8601String();

double? _duration(Duration? duration) => duration == null
    ? null
    : duration.inMicroseconds / Duration.microsecondsPerSecond;
