/// Minimal session-record walker producing trajectory snapshots.
///
/// Ported in reduced form from deepseek-harness `packages/client/ui-trajectory/
/// src/client/trajectory-snapshot-builder.ts`. Phase 1 populates identity,
/// kind, relations, and text basics; full detail (source blocks, timing,
/// schemas, request roll-ups) is a later phase. Hosts feed records — the
/// builder performs no IO.
library;

import 'dart:collection';
import 'dart:convert';

import '../context.dart';
import '../session/session_record.dart';
import '../types.dart';
import 'trajectory_record.dart';
import 'trajectory_snapshot.dart';

/// Walks session records and projects them into immutable
/// [TrajectorySnapshot]s.
///
/// Every [append] returns a fresh snapshot whose [TrajectorySnapshot.revision]
/// grows by one; [build] re-reads the current state without incrementing.
/// Records that are not ledger rows (labels, session info, leaves, custom
/// payloads, hidden custom messages) are indexed but produce no row.
final class TrajectorySnapshotBuilder {
  final List<TrajectoryRecord> _records = [];
  final Map<String, SessionRecord> _byId = {};
  final Map<String, int> _toolIndexByCallId = {};
  final Map<String, String> _toolOwnerByCallId = {};
  int _revision = 0;

  /// Projects [record] and returns the updated snapshot.
  TrajectorySnapshot append(SessionRecord record) {
    _byId[record.id] = record;
    _revision++;
    switch (record) {
      case MessageRecord():
        _appendMessage(record);
      case CompactionRecord() || BranchSummaryRecord():
        _appendCompacted(record);
      case ModelChangeRecord() ||
          ActiveToolsChangeRecord() ||
          ThinkingLevelChangeRecord() ||
          CheckpointRecord():
        _appendSystem(record);
      case CustomMessageRecord(display: true, customType: 'context'):
        _appendContext(record);
      default:
        break; // Not a ledger row.
    }
    return _snapshot();
  }

  /// The current snapshot state without appending.
  TrajectorySnapshot build() => _snapshot();

  /// Clears all projected state.
  void reset() {
    _records.clear();
    _byId.clear();
    _toolIndexByCallId.clear();
    _toolOwnerByCallId.clear();
    _revision = 0;
  }

  void _appendMessage(MessageRecord record) {
    switch (record.message.role) {
      case 'user':
        _appendUser(record);
      case 'assistant':
        _appendAssistant(record);
      case 'toolResult':
        _applyToolResult(record);
    }
  }

  void _appendUser(MessageRecord record) {
    final message = record.message as UserMessage;
    final text = _textOf(message.content);
    _records.add(
      TrajectoryUserRecord(
        index: _records.length + 1,
        recordId: trajectoryRecordId(
          kind: 'user',
          recordId: record.id,
          index: _records.length + 1,
        ),
        text: text,
        previewMarkdown: text,
        opensTurn: _openedTurnByUser(record),
        startedAt: record.timestamp,
      ),
    );
  }

  void _appendAssistant(MessageRecord record) {
    final message = record.message as AssistantMessage;
    final failed =
        message.stopReason == StopReason.error ||
        message.stopReason == StopReason.aborted;
    _records.add(
      TrajectoryAssistantRecord(
        index: _records.length + 1,
        recordId: trajectoryRecordId(
          kind: 'message',
          recordId: record.id,
          index: _records.length + 1,
        ),
        messageId: record.id,
        turn: _turnStep(record).turn,
        step: _turnStep(record).step,
        provider: message.provider,
        model: message.model,
        usage: message.usage,
        inputTokens: message.usage.input,
        cacheReadTokens: message.usage.cacheRead,
        cacheWriteTokens: message.usage.cacheWrite,
        outputTokens: message.usage.output,
        reasoningTokens: message.usage.reasoning,
        completedTime: message.timestamp,
        isError: failed,
        errorMessage: message.errorMessage,
      ),
    );
    for (final block in message.content) {
      if (block is ToolCall) _appendToolCall(record, block);
    }
  }

  void _appendToolCall(MessageRecord owner, ToolCall call) {
    final index = _records.length + 1;
    _records.add(
      TrajectoryToolRecord(
        index: index,
        recordId: trajectoryRecordId(
          kind: 'tool',
          callId: call.id,
          index: index,
        ),
        callId: call.id,
        parentCallId: null,
        name: call.name,
        argsRaw: jsonEncode(call.arguments),
      ),
    );
    _toolIndexByCallId[call.id] = index - 1;
    _toolOwnerByCallId[call.id] = owner.id;
  }

  void _applyToolResult(MessageRecord record) {
    final result = record.message as ToolResultMessage;
    final toolIndex = _toolIndexByCallId[result.toolCallId];
    if (toolIndex == null) return; // Result for a call we never saw.
    final ownerId = _toolOwnerByCallId[result.toolCallId];
    final owner = _byId[ownerId];
    final tool = _records[toolIndex] as TrajectoryToolRecord;
    _records[toolIndex] = tool.withResult(
      result: _textOf(result.content),
      isError: result.isError,
      timeSeconds: owner == null
          ? null
          : record.timestamp.difference(owner.timestamp),
    );
  }

  void _appendCompacted(SessionRecord record) {
    final firstKept = switch (record) {
      CompactionRecord() => record.firstKeptEntryId,
      _ => null,
    };
    final summary = switch (record) {
      CompactionRecord() => record.summary,
      BranchSummaryRecord() => record.summary,
      _ => '',
    };
    _records.add(
      TrajectoryCompactedRecord(
        index: _records.length + 1,
        recordId: trajectoryRecordId(
          kind: 'compacted',
          recordId: record.id,
          index: _records.length + 1,
        ),
        text: summary,
        summary: summary,
        firstKeptEntryId: firstKept,
        startedAt: record.timestamp,
      ),
    );
  }

  void _appendSystem(SessionRecord record) {
    final (change, text) = switch (record) {
      ModelChangeRecord(:final provider, :final modelId) => (
        TrajectorySystemChange.modelChange,
        '$provider/$modelId',
      ),
      ActiveToolsChangeRecord(:final activeToolNames) => (
        TrajectorySystemChange.toolsChange,
        activeToolNames.join(', '),
      ),
      ThinkingLevelChangeRecord(:final thinkingLevel) => (
        TrajectorySystemChange.thinkingLevelChange,
        thinkingLevel,
      ),
      CheckpointRecord(:final goal) => (
        TrajectorySystemChange.checkpoint,
        goal ?? 'checkpoint',
      ),
      _ => (TrajectorySystemChange.initial, ''),
    };
    _records.add(
      TrajectorySystemRecord(
        index: _records.length + 1,
        recordId: trajectoryRecordId(
          kind: 'system',
          recordId: record.id,
          index: _records.length + 1,
        ),
        text: text,
        change: change,
        detail: text,
        time: record.timestamp,
      ),
    );
  }

  void _appendContext(CustomMessageRecord record) {
    final text = _textOf(record.content);
    _records.add(
      TrajectoryContextRecord(
        index: _records.length + 1,
        recordId: trajectoryRecordId(
          kind: 'context',
          recordId: record.id,
          index: _records.length + 1,
        ),
        text: text,
        previewMarkdown: text,
      ),
    );
  }

  /// Turn/step of [record] derived by walking the parentId chain.
  ///
  /// A user message opens a turn unless the previous message on the chain is
  /// also a user message (queued prompts merge into one turn). Assistants
  /// count steps since the last user message. System records do not
  /// intervene.
  ({int turn, int step}) _turnStep(SessionRecord record) {
    var turn = 0;
    var step = 0;
    var previousWasUser = false;
    for (final entry in _chainToRoot(record).reversed) {
      if (entry is! MessageRecord) continue;
      switch (entry.message.role) {
        case 'user':
          if (!previousWasUser) turn++;
          previousWasUser = true;
          step = 0;
        case 'assistant':
          previousWasUser = false;
          step++;
      }
    }
    return (turn: turn, step: step);
  }

  /// Whether [record] is a user message that opens a turn: the previous
  /// message on its chain is not another user message.
  bool _openedTurnByUser(MessageRecord record) =>
      _previousMessageRole(record) != 'user';

  String? _previousMessageRole(SessionRecord record) {
    for (final entry in _chainToRoot(record)) {
      if (identical(entry, record)) continue;
      if (entry is MessageRecord) return entry.message.role;
    }
    return null;
  }

  /// Plain text of a String or content-block payload.
  String _textOf(Object content) {
    if (content is String) return content;
    if (content is! List<ContentBlock>) return '';
    return [
      for (final block in content)
        if (block is TextContent) block.text,
    ].join('\n\n');
  }

  /// Records from [record] (inclusive) to the root, leaf-first.
  List<SessionRecord> _chainToRoot(SessionRecord record) {
    final chain = <SessionRecord>[record];
    var current = record;
    while (current.parentId != null) {
      final parent = _byId[current.parentId!];
      if (parent == null) break;
      chain.add(parent);
      current = parent;
    }
    return chain;
  }

  TrajectorySnapshot _snapshot() {
    final locations = <String, int>{
      for (final record in _records) record.recordId: record.index - 1,
    };
    return TrajectorySnapshot(
      records: UnmodifiableListView(List.of(_records)),
      requests: UnmodifiableListView(const []),
      callSchemas: const {},
      partial: null,
      runningCalls: UnmodifiableListView(const []),
      recordLocations: Map.unmodifiable(locations),
      revision: _revision,
    );
  }
}
