/// Session-record walker and live-tail event applier producing trajectory
/// snapshots.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-snapshot-builder.ts`, adapted to this repo's feed: hosts append
/// finalized [SessionRecord]s and may mirror the live tail by feeding agent
/// events to [applyEvent] — a terminal assistant message finalizes through
/// the normal append path, and a later real record for the same turn/step
/// replaces the streamed rows. The builder performs no IO.
library;

import 'dart:collection';
import 'dart:convert';

import '../agent/agent_loop.dart';
import '../context.dart';
import '../session/session_record.dart';
import '../types.dart';
import 'event_projection.dart';
import 'trajectory_record.dart';
import 'trajectory_snapshot.dart';

/// Walks session records and live agent events, projecting them into
/// immutable [TrajectorySnapshot]s.
///
/// Every [append] and [applyEvent] returns a fresh snapshot whose
/// [TrajectorySnapshot.revision] grows by one; [build] re-reads the current
/// state without incrementing. Records that are not ledger rows (labels,
/// session info, leaves, custom payloads, hidden custom messages) are indexed
/// but produce no row. Tool schemas are not derivable from session records
/// (tool-set changes carry names only), so [TrajectorySnapshot.callSchemas]
/// stays empty until a host supplies schemas.
final class TrajectorySnapshotBuilder {
  final List<TrajectoryRecord> _records = [];
  final Map<String, SessionRecord> _byId = {};
  final Map<String, int> _toolIndexByCallId = {};
  final Map<String, String> _toolOwnerByCallId = {};

  /// Settled tool results, re-applied when a replaced message re-creates its
  /// tool rows.
  final Map<String, ({String result, bool isError, Duration? timeSeconds})>
  _resultsByCallId = {};

  /// Row ids streamed in by [applyEvent], keyed for replacement when the
  /// real record lands (`turn\0step` for assistants, `u\0turn` for prompts).
  final Map<String, Set<String>> _syntheticRowsByKey = {};

  /// Assistant request facts keyed by `turn\0step`.
  final Map<String, _RequestFacts> _assistantRequests = {};

  /// Compaction request facts, one per compaction/branch-summary record.
  final List<_RequestFacts> _compactionRequests = [];

  /// Tool calls issued but not yet answered, by call id.
  final Map<String, TrajectoryRunningToolCall> _runningCalls = {};

  TrajectoryPartialAssistant? _partial;
  String? _lastRecordId;
  int? _liveTurn;
  int _liveStep = 0;
  int _lastAssistantTurn = 0;
  int _lastAssistantStep = 0;
  DateTime? _prevAbsTime;
  int _eventCounter = 0;
  int _revision = 0;

  /// Projects [record] and returns the updated snapshot.
  TrajectorySnapshot append(SessionRecord record) =>
      _appendRecord(record, synthetic: false);

  TrajectorySnapshot _appendRecord(
    SessionRecord record, {
    required bool synthetic,
  }) {
    _byId[record.id] = record;
    _revision++;
    final rowsBefore = _records.length;
    switch (record) {
      case MessageRecord():
        _appendMessage(record, synthetic: synthetic);
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
    if (_records.length > rowsBefore) _prevAbsTime = record.timestamp;
    _lastRecordId = record.id;
    return _snapshot();
  }

  TrajectorySnapshot applyEvent(AgentEvent event) {
    switch (event) {
      case MessageEndEvent(message: final AssistantMessage message):
        return _appendRecord(
          _syntheticRecord('assistant', message),
          synthetic: true,
        );
      case MessageEndEvent(message: final UserMessage message):
        return _appendRecord(
          _syntheticRecord('user', message),
          synthetic: true,
        );
      case MessageEndEvent(message: final ToolResultMessage message):
        return _appendRecord(
          _syntheticRecord('result', message),
          synthetic: true,
        );
      case MessageStartEvent(message: final AssistantMessage message):
        _beginAssistantStream(message);
      case MessageStartEvent(message: UserMessage()):
        _liveTurn = _lastAssistantTurn + 1;
        _liveStep = 0;
      case MessageUpdateEvent(:final message):
        _updateAssistantStream(message);
      case ToolExecutionStartEvent(:final toolCallId, :final toolName):
        _runningCalls[toolCallId] = TrajectoryRunningToolCall(
          callId: toolCallId,
          name: toolName,
          turn: _liveTurn ?? _lastAssistantTurn,
          step: _liveStep != 0
              ? _liveStep
              : (_lastAssistantStep != 0 ? _lastAssistantStep : 1),
        );
      default:
        break; // Not a transcript message; nothing to project.
    }
    _revision++;
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
    _resultsByCallId.clear();
    _syntheticRowsByKey.clear();
    _assistantRequests.clear();
    _compactionRequests.clear();
    _runningCalls.clear();
    _partial = null;
    _lastRecordId = null;
    _liveTurn = null;
    _liveStep = 0;
    _lastAssistantTurn = 0;
    _lastAssistantStep = 0;
    _prevAbsTime = null;
    _eventCounter = 0;
    _revision = 0;
  }

  MessageRecord _syntheticRecord(String kind, Message message) {
    return MessageRecord(
      id: 'evt\u0000$kind\u0000${++_eventCounter}',
      parentId: _lastRecordId,
      timestamp: message.timestamp,
      message: message,
    );
  }

  void _appendMessage(MessageRecord record, {bool synthetic = false}) {
    switch (record.message.role) {
      case 'user':
        _appendUser(record, synthetic: synthetic);
      case 'assistant':
        _appendAssistant(record, synthetic: synthetic);
      case 'toolResult':
        _applyToolResult(record);
    }
  }

  void _appendUser(MessageRecord record, {bool synthetic = false}) {
    final turn = _turnStep(record).turn;
    _discardSyntheticRows('u\u0000$turn');
    final index = _records.length + 1;
    _records.add(
      projectUserRecord(
        record: record,
        index: index,
        recordId: trajectoryRecordId(
          kind: 'user',
          recordId: record.id,
          index: index,
        ),
        opensTurn: _openedTurnByUser(record),
      ),
    );
    if (synthetic) _registerSyntheticRows('u\u0000$turn', index - 1);
    _liveTurn = turn;
    _liveStep = 0;
  }

  void _appendAssistant(MessageRecord record, {bool synthetic = false}) {
    final message = record.message as AssistantMessage;
    final (:turn, :step) = _turnStep(record);
    _discardSyntheticRows('$turn\u0000$step');
    final index = _records.length + 1;
    _records.add(
      projectAssistantRecord(
        record: record,
        message: message,
        index: index,
        recordId: trajectoryRecordId(
          kind: 'message',
          recordId: record.id,
          index: index,
        ),
        turn: turn,
        step: step,
        previousTime: _prevAbsTime,
      ),
    );
    _finalizeAssistantRequest(turn, step, message);
    for (final block in message.content) {
      if (block is ToolCall) {
        _appendToolCall(
          record,
          block,
          turn: turn,
          step: step,
          synthetic: synthetic,
        );
      }
    }
    if (synthetic) _registerSyntheticRows('$turn\u0000$step', index - 1);
    _lastAssistantTurn = turn;
    _lastAssistantStep = step;
    _liveTurn = turn;
    _liveStep = step;
    final partial = _partial;
    if (partial != null && partial.turn == turn && partial.step == step) {
      _partial = null;
    }
  }

  void _appendToolCall(
    MessageRecord owner,
    ToolCall call, {
    required int turn,
    required int step,
    required bool synthetic,
  }) {
    final index = _records.length + 1;
    var tool = TrajectoryToolRecord(
      index: index,
      recordId: trajectoryRecordId(kind: 'tool', callId: call.id, index: index),
      callId: call.id,
      parentCallId: null,
      name: call.name,
      argsRaw: jsonEncode(call.arguments),
    );
    final known = _resultsByCallId[call.id];
    if (known != null) {
      tool = tool.withResult(
        result: known.result,
        isError: known.isError,
        timeSeconds: known.timeSeconds,
      );
    }
    _records.add(tool);
    _toolIndexByCallId[call.id] = index - 1;
    _toolOwnerByCallId[call.id] = owner.id;
  }

  void _applyToolResult(MessageRecord record) {
    final result = record.message as ToolResultMessage;
    final ownerId = _toolOwnerByCallId[result.toolCallId];
    final owner = ownerId == null ? null : _byId[ownerId];
    final projected = projectToolResult(
      result: result,
      callTime: owner?.timestamp,
    );
    _resultsByCallId[result.toolCallId] = projected;
    _runningCalls.remove(result.toolCallId);
    final toolIndex = _toolIndexByCallId[result.toolCallId];
    if (toolIndex == null) return; // Result for a call we never saw.
    final tool = _records[toolIndex] as TrajectoryToolRecord;
    _records[toolIndex] = tool.withResult(
      result: projected.result,
      isError: projected.isError,
      timeSeconds: projected.timeSeconds,
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
      projectCompactedRecord(
        record: record,
        index: _records.length + 1,
        recordId: trajectoryRecordId(
          kind: 'compacted',
          recordId: record.id,
          index: _records.length + 1,
        ),
        summary: summary,
        firstKeptEntryId: firstKept,
      ),
    );
    _compactionRequests.add(
      _RequestFacts(
        order: _records.length.toDouble(),
        turn: _chainTurn(record),
        step: 0,
        purpose: TrajectoryRequestPurpose.compaction,
        provider: '',
        model: '',
        status: TrajectoryRequestStatus.completed,
        startedAt: record.timestamp,
        completedAt: record.timestamp,
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
    final text = textPayloadOf(record.content);
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

  void _beginAssistantStream(AssistantMessage message) {
    final turn = _liveTurn ?? _lastAssistantTurn;
    final step = _liveStep + 1;
    _liveTurn = turn;
    _liveStep = step;
    _partial = TrajectoryPartialAssistant(
      messageId:
          message.responseId ?? 'evt\u0000partial\u0000${++_eventCounter}',
      turn: turn,
      step: step,
      blocks: _partialBlocks(message.content),
      startedAt: message.timestamp,
    );
    final key = '$turn\u0000$step';
    final existing = _assistantRequests[key];
    if (existing != null) return;
    _assistantRequests[key] = _RequestFacts(
      order: _records.length + 0.5,
      turn: turn,
      step: step,
      purpose: TrajectoryRequestPurpose.assistant,
      provider: message.provider,
      model: message.model,
      status: TrajectoryRequestStatus.running,
      startedAt: message.timestamp,
    );
  }

  void _updateAssistantStream(AssistantMessage message) {
    final partial = _partial;
    if (partial == null) {
      _beginAssistantStream(message);
      return;
    }
    _partial = TrajectoryPartialAssistant(
      messageId: partial.messageId,
      turn: partial.turn,
      step: partial.step,
      blocks: _partialBlocks(message.content),
      startedAt: partial.startedAt,
    );
  }

  void _finalizeAssistantRequest(int turn, int step, AssistantMessage message) {
    final failed =
        message.stopReason == StopReason.error ||
        message.stopReason == StopReason.aborted;
    final status = failed
        ? TrajectoryRequestStatus.failed
        : TrajectoryRequestStatus.completed;
    final facts = _assistantRequests['$turn\u0000$step'];
    if (facts == null) {
      _assistantRequests['$turn\u0000$step'] = _RequestFacts(
        order: _records.length.toDouble(),
        turn: turn,
        step: step,
        purpose: TrajectoryRequestPurpose.assistant,
        provider: message.provider,
        model: message.model,
        status: status,
        completedAt: message.timestamp,
        usage: message.usage,
      );
      return;
    }
    facts
      ..order = _records.length.toDouble()
      ..status = status
      ..completedAt = message.timestamp
      ..usage = message.usage;
  }

  /// Drops streamed rows for [key] so the real record can replace them.
  ///
  /// Streamed rows are the live tail, so removal happens after all placed
  /// rows; tool-row indexes are rebuilt to stay robust regardless.
  void _discardSyntheticRows(String key) {
    final ids = _syntheticRowsByKey.remove(key);
    if (ids == null || ids.isEmpty) return;
    final removed = _records
        .where((row) => ids.contains(row.recordId))
        .toList();
    if (removed.isEmpty) return;
    _records.removeWhere((row) => ids.contains(row.recordId));
    for (final row in removed) {
      if (row is TrajectoryToolRecord) {
        _toolIndexByCallId.remove(row.callId);
        _toolOwnerByCallId.remove(row.callId);
      }
    }
    _toolIndexByCallId.clear();
    for (var i = 0; i < _records.length; i++) {
      final row = _records[i];
      if (row is TrajectoryToolRecord) _toolIndexByCallId[row.callId] = i;
    }
  }

  void _registerSyntheticRows(String key, int fromIndex) {
    final ids = _syntheticRowsByKey.putIfAbsent(key, () => <String>{});
    for (var i = fromIndex; i < _records.length; i++) {
      ids.add(_records[i].recordId);
    }
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

  /// Turn of [record]'s parent chain without counting the record itself.
  int _chainTurn(SessionRecord record) {
    var turn = 0;
    var previousWasUser = false;
    for (final entry in _chainToRoot(record)) {
      if (identical(entry, record) || entry is! MessageRecord) continue;
      if (entry.message.role == 'user' && !previousWasUser) turn++;
      previousWasUser = entry.message.role == 'user';
    }
    return turn;
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

  /// In-flight blocks of a streaming message (partial-first: the live
  /// message already carries accumulated text).
  List<TrajectoryPartialBlock> _partialBlocks(List<ContentBlock> content) {
    return [
      for (final block in content)
        switch (block) {
          TextContent(:final text) => TrajectoryPartialBlock(
            type: 'text',
            content: text,
          ),
          ThinkingContent(:final thinking) => TrajectoryPartialBlock(
            type: 'reasoning',
            content: thinking,
          ),
          ToolCall() => TrajectoryPartialBlock(
            type: 'tool-call',
            content: block.partialArguments ?? jsonEncode(block.arguments),
          ),
          _ => const TrajectoryPartialBlock(type: 'other', content: ''),
        },
    ];
  }

  TrajectorySnapshot _snapshot() {
    final locations = <String, int>{
      for (final record in _records) record.recordId: record.index - 1,
    };
    final facts = [..._assistantRequests.values, ..._compactionRequests]
      ..sort((left, right) => left.order.compareTo(right.order));
    final requests = <TrajectoryRequestNumber>[];
    Usage? cumulative;
    for (var i = 0; i < facts.length; i++) {
      final fact = facts[i];
      cumulative = accumulateUsage(cumulative, fact.usage);
      requests.add(
        TrajectoryRequestNumber(
          seq: i + 1,
          turn: fact.turn,
          step: fact.step,
          purpose: fact.purpose,
          provider: fact.provider,
          model: fact.model,
          status: fact.status,
          startedAt: fact.startedAt,
          completedAt: fact.completedAt,
          usage: fact.usage,
          cumulativeUsage: cumulative,
        ),
      );
    }
    final partial = _partial;
    return TrajectorySnapshot(
      records: UnmodifiableListView(List.of(_records)),
      requests: UnmodifiableListView(requests),
      callSchemas: const {},
      partial: partial == null
          ? null
          : TrajectoryPartialAssistant(
              messageId: partial.messageId,
              turn: partial.turn,
              step: partial.step,
              blocks: List.of(partial.blocks),
              startedAt: partial.startedAt,
            ),
      runningCalls: UnmodifiableListView(_runningCalls.values.toList()),
      recordLocations: Map.unmodifiable(locations),
      revision: _revision,
    );
  }
}

/// Mutable request bookkeeping folded into [TrajectoryRequestNumber]s.
class _RequestFacts {
  /// Creates [_RequestFacts].
  _RequestFacts({
    required this.order,
    required this.turn,
    required this.step,
    required this.purpose,
    required this.provider,
    required this.model,
    required this.status,
    this.startedAt,
    this.completedAt,
    this.usage,
  });

  /// Sort key: assistant-row index, or a fractional position for a request
  /// streamed before its record landed.
  double order;

  /// Model turn the request belongs to.
  final int turn;

  /// Assistant step within [turn]; compactions use 0.
  final int step;

  /// Whether this was a model step or a compaction request.
  final TrajectoryRequestPurpose purpose;

  /// Provider id.
  String provider;

  /// Model id.
  String model;

  /// Lifecycle state of the request.
  TrajectoryRequestStatus status;

  /// Wall-clock time the request was issued.
  DateTime? startedAt;

  /// Wall-clock time the request completed.
  DateTime? completedAt;

  /// Usage reported by this request.
  Usage? usage;
}
