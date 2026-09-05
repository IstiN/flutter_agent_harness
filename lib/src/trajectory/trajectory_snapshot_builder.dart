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
    var discarded = 0;
    switch (record) {
      case MessageRecord():
        discarded = _appendMessage(record, synthetic: synthetic);
      case CompactionRecord() || BranchSummaryRecord():
        _appendCompacted(record);
      case ModelChangeRecord() ||
          ActiveToolsChangeRecord() ||
          ThinkingLevelChangeRecord() ||
          CheckpointRecord():
        _appendSystem(record);
      case CustomMessageRecord(display: true, customType: 'context'):
        _appendContext(record);
      case CustomRecord(customType: 'model_request_summary', data: final data):
        _applyRequestSummary(record, data);
      default:
        break; // Not a ledger row.
    }
    // Only durable appends advance the cursor; replacing mirrored
    // placeholders still counts as placing rows even when net growth is 0.
    if (!synthetic && _records.length + discarded > rowsBefore) {
      _prevAbsTime = record.timestamp;
    }
    _lastRecordId = record.id;
    return _snapshot();
  }

  TrajectorySnapshot applyEvent(AgentEvent event) {
    switch (event) {
      case MessageEndEvent(message: final message):
        return _appendRecord(
          _syntheticRecord(_eventRole(message), message),
          synthetic: true,
        );
      case MessageStartEvent(message: final AssistantMessage message):
        _beginAssistantStream(message);
      case MessageStartEvent(message: UserMessage()):
        _beginUserTurn();
      case MessageUpdateEvent(:final message):
        _updateAssistantStream(message);
      case ToolExecutionStartEvent(
        :final toolCallId,
        :final toolName,
        :final timestamp,
      ):
        _beginToolCall(toolCallId, toolName, timestamp);
      case ModelRequestEvent(:final detail):
        _attachRequestDetail(_nextAssistantStep(), detail);
      default:
        break; // Not a transcript message; nothing to project.
    }
    _revision++;
    return _snapshot();
  }

  /// The ledger record kind a transcript message projects to.
  String _eventRole(Message message) => switch (message) {
    AssistantMessage() => 'assistant',
    UserMessage() => 'user',
    ToolResultMessage() => 'result',
    _ => 'message',
  };

  void _beginUserTurn() {
    _liveTurn = _lastAssistantTurn + 1;
    _liveStep = 0;
  }

  void _beginToolCall(String toolCallId, String toolName, DateTime timestamp) {
    _runningCalls[toolCallId] = TrajectoryRunningToolCall(
      callId: toolCallId,
      name: toolName,
      turn: _liveTurn ?? _lastAssistantTurn,
      step: _liveStep != 0
          ? _liveStep
          : (_lastAssistantStep != 0 ? _lastAssistantStep : 1),
      startedAt: timestamp,
    );
    _markToolStarted(toolCallId, timestamp);
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

  int _appendMessage(MessageRecord record, {bool synthetic = false}) {
    switch (record.message.role) {
      case 'user':
        return _appendUser(record, synthetic: synthetic);
      case 'assistant':
        return _appendAssistant(record, synthetic: synthetic);
      case 'toolResult':
        _applyToolResult(record);
        return 0;
    }
    return 0;
  }

  int _appendUser(MessageRecord record, {bool synthetic = false}) {
    final turn = _turnStep(record).turn;
    final discarded = _discardSyntheticRows('u\u0000$turn');
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
    return discarded;
  }

  int _appendAssistant(MessageRecord record, {bool synthetic = false}) {
    final message = record.message as AssistantMessage;
    final (:turn, :step) = _turnStep(record);
    final discarded = _discardSyntheticRows('$turn\u0000$step');
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
        requestDetail: _assistantRequests['$turn\u0000$step']?.requestDetail,
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
    return discarded;
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
      parentCallId: call.parentCallId,
      name: call.name,
      argsRaw: jsonEncode(call.arguments),
      startedAt: owner.timestamp,
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
        previousTime: _prevAbsTime,
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
        startedAt: record.timestamp,
      ),
    );
  }

  void _beginAssistantStream(AssistantMessage message) {
    final (turn, step) = _nextAssistantStep();
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
    if (existing != null) {
      // A ModelRequestEvent pre-registered this request; fill in what the
      // stream start knows and keep the attached request detail.
      existing
        ..provider = message.provider
        ..model = message.model
        ..startedAt ??= message.timestamp;
      return;
    }
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

  /// Turn/step the NEXT assistant response will occupy (the request always
  /// precedes its message, so this is where [ModelRequestEvent] details and
  /// new streams attach).
  (int, int) _nextAssistantStep() {
    return (_liveTurn ?? _lastAssistantTurn, _liveStep + 1);
  }

  /// Stamps the execution start onto a tool row that was already projected
  /// from its assistant message (live-tail order: message first, then
  /// tool-execution events).
  void _markToolStarted(String callId, DateTime startedAt) {
    final toolIndex = _toolIndexByCallId[callId];
    if (toolIndex == null) return;
    final tool = _records[toolIndex] as TrajectoryToolRecord;
    _records[toolIndex] = tool.withStartedAt(startedAt);
  }

  /// Attaches a live [ModelRequestEvent] summary to the assistant request
  /// the upcoming stream belongs to.
  void _attachRequestDetail(
    (int, int) turnStep,
    TrajectoryRequestDetail detail,
  ) {
    final key = '${turnStep.$1}\u0000${turnStep.$2}';
    final facts = _assistantRequests[key];
    if (facts != null) {
      facts.requestDetail = detail;
      return;
    }
    _assistantRequests[key] = _RequestFacts(
      order: _records.length + 0.5,
      turn: turnStep.$1,
      step: turnStep.$2,
      purpose: TrajectoryRequestPurpose.assistant,
      provider: '',
      model: '',
      status: TrajectoryRequestStatus.running,
      requestDetail: detail,
    );
  }

  /// Replays a persisted `model_request_summary` payload onto the matching
  /// turn/step so replayed sessions carry the same request detail as the
  /// live path. The record sits on the chain before its assistant message,
  /// so the chain walk yields the upcoming turn and the step AFTER it (+1).
  void _applyRequestSummary(SessionRecord record, Object? data) {
    if (data is! Map) return;
    final (:turn, :step) = _turnStep(record);
    _attachRequestDetail((
      turn,
      step + 1,
    ), TrajectoryRequestDetail.fromJson(data.cast<String, dynamic>()));
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
  int _discardSyntheticRows(String key) {
    final ids = _syntheticRowsByKey.remove(key);
    if (ids == null || ids.isEmpty) return 0;
    final removed = _records
        .where((row) => ids.contains(row.recordId))
        .toList();
    if (removed.isEmpty) return 0;
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
    return removed.length;
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
    this.requestDetail,
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

  /// Outbound-request summary captured before the provider call.
  TrajectoryRequestDetail? requestDetail;
}
