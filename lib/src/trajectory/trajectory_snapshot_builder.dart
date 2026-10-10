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
import '../agent/finalize_gate.dart';
import '../context.dart';
import '../session/obligations_ledger.dart' show obligationsLedgerRecordType;
import '../session/session_record.dart';
import '../tools/checkpoint_tool.dart';
import '../types.dart';
import '../usage/usage_chain.dart' show usageSegmentStartCustomType;
import 'event_projection.dart';
import 'trajectory_blobs.dart';
import 'trajectory_record.dart';
import 'trajectory_snapshot.dart';

/// Custom-record types the trajectory ledger deliberately does NOT render:
/// hosts' non-row payloads consumed by other surfaces (request summaries
/// and issue-385 blobs are handled above this set; anything else renders
/// as an `unknown record` context row — F6, the ledger stays lossless).
const hiddenCustomRecordTypes = {
  'subagent_registry',
  'ttsr_injection',
  'dynamic_widget',
  'dynamic_message',
  // gh-1241: the usage ledger's segment boundary (gh-1241) — bookkeeping
  // for the usage fold, not a ledger row.
  usageSegmentStartCustomType,
  // Issue #1380 A1: engine-maintained snapshot ledger — the obligations
  // surface in model context is the rendered block, not trajectory rows.
  obligationsLedgerRecordType,
};

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
  /// Ledger rows in append order, chunked for copy-on-write publishing
  /// (issue #1497): per-append snapshots share frozen chunks instead of
  /// copying the whole row list — a full copy per append was O(n) per
  /// record, O(n²) per live session.
  final _ChunkStore<TrajectoryRecord> _rows = _ChunkStore<TrajectoryRecord>();
  final Map<String, SessionRecord> _byId = {};
  final Map<String, int> _toolIndexByCallId = {};
  final Map<String, String> _toolOwnerByCallId = {};

  /// Content-addressed blobs folded from the session's blob records
  /// (F1/F2/F5). The blob records themselves produce no ledger row.
  TrajectoryBlobTable _blobs = const TrajectoryBlobTable();
  TaskLedger? _taskLedger;

  /// Unknown record kinds rendered as context rows (F6).
  int _unknownRecordCount = 0;

  /// Row indexes of the latest prompt-bearing and tools-bearing system
  /// rows, stamped with blob pointers when their following request
  /// summary lands (F7).
  int? _lastPromptRowIndex;
  int? _lastToolsRowIndex;

  /// Prompt/manifest versions currently active, with their predecessors,
  /// for the system-row diff stamps.
  String? _activePromptHash;
  String? _prevPromptHash;
  String? _activeManifestHash;
  String? _prevManifestHash;

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

  // ── Requests derivation cache (issue #1497) ───────────────────────────
  // Sorting every request fact and refolding cumulative usage on every
  // snapshot is O(k log k) per append — O(n²) over a live session. The
  // sorted fact order and the built TrajectoryRequestNumbers are cached;
  // a snapshot rebuilds only the dirty suffix. New facts fold in with
  // order = the row count at their creation, which only grows, so they
  // land at the sorted tail; any event the incremental path cannot prove
  // order-stable flips back to the exact full sort.
  List<_RequestFacts>? _reqSorted;
  final Map<_RequestFacts, int> _reqPositions = {};
  List<Usage?> _reqCumulative = <Usage?>[];
  final List<_RequestFacts> _reqAdded = <_RequestFacts>[];
  final _ChunkStore<TrajectoryRequestNumber> _reqNumberRows =
      _ChunkStore<TrajectoryRequestNumber>();
  UnmodifiableListView<TrajectoryRequestNumber>? _reqPublished;
  int _reqDirtyFrom = _reqUntouched;
  bool _reqDirty = true;
  bool _reqResort = false;

  /// Dirty-position sentinel: no cached position touched yet.
  static const int _reqUntouched = 1 << 60;

  /// How many snapshots [_snapshot] has materialized. Hosts bulk-loading a
  /// session must see exactly one; the per-append live tail grows this by
  /// one per record/event.
  int get snapshotsBuilt => _snapshotsBuilt;
  int _snapshotsBuilt = 0;

  /// Total parent hops walked by [_chainToRoot] over this builder's life.
  ///
  /// Linear backfills fold turn/step incrementally (issue #262) and walk
  /// O(1) hops per record; the pre-#262 quadratic fold walked the whole
  /// parent chain per user/assistant record — O(n²) hops over a backfill.
  /// Scaling tests assert against this instead of wall-clock ratios, which
  /// flake on loaded shared runners when one GC/scheduler pause lands in
  /// the larger window (issue #358).
  int get chainWalkHops => _chainWalkHops;
  int _chainWalkHops = 0;

  /// Total row references the snapshot publisher copied (chunk clones +
  /// per-publish chunk-pointer copies) over this builder's life.
  ///
  /// The #1497 per-append snapshot copied EVERY row on every append —
  /// O(n) per append, O(n²) over a live session (~10ms per append at 65k
  /// records). Publishing now shares frozen chunks: an append copies only
  /// its chunk pointers plus a bounded copy-on-write clone for patched
  /// rows, a small constant per append. Like [chainWalkHops], scaling
  /// tests assert against this instead of wall-clock ratios, which cannot
  /// tell a loaded shared runner from a quadratic algorithm (issue #358)
  /// and here additionally carry a JIT-tier cliff on cold first runs.
  int get snapshotRowCopies => _rows.copiedRows + _reqNumberRows.copiedRows;

  // Incremental turn/step fold over the appended record chain (issue #262):
  // `_turnStep`'s full parent-chain walk per user/assistant record is O(n)
  // per append — O(n²) over a backfill. These track the fold state through
  // the chain tip so a record extending the tip folds in O(1); any other
  // parent (branching, replayed tails) falls back to the walk and re-adopts
  // the state from its result.
  String? _incTipId;
  int _incTurn = 0;
  int _incStep = 0;
  bool _incPrevWasUser = false;

  /// Projects [record] and returns the updated snapshot.
  TrajectorySnapshot append(SessionRecord record) {
    _appendRecord(record, synthetic: false);
    return _snapshot();
  }

  /// Projects a whole backfill — a session open or branch page-in — and
  /// builds exactly ONE snapshot at the end. Intermediate snapshots are
  /// suppressed: nobody renders them, and per-append materialization is
  /// O(n²) over a 30k-record session (issue #262). The live tail keeps
  /// using [append] with its per-record snapshots.
  TrajectorySnapshot appendAll(Iterable<SessionRecord> records) {
    for (final record in records) {
      _appendRecord(record, synthetic: false);
    }
    return _snapshot();
  }

  void _appendRecord(SessionRecord record, {required bool synthetic}) {
    _byId[record.id] = record;
    _revision++;
    final rowsBefore = _rows.length;
    final discarded = _foldRecordRows(record, synthetic: synthetic);
    // Only durable appends advance the cursor; replacing mirrored
    // placeholders still counts as placing rows even when net growth is 0.
    if (!synthetic && _rows.length + discarded > rowsBefore) {
      _prevAbsTime = record.timestamp;
    }
    _lastRecordId = record.id;
    // The chain tip advanced: the next record parented here folds in O(1).
    if (_chainsToTip(record)) _incTipId = record.id;
  }

  /// Dispatches one session record to its ledger rows (or the blob
  /// table); returns the number of mirrored rows it replaced.
  int _foldRecordRows(SessionRecord record, {required bool synthetic}) {
    switch (record) {
      case MessageRecord():
        return _appendMessage(record, synthetic: synthetic);
      case CustomRecord(customType: final customType, data: final data):
        _foldCustomRecord(record, customType, data);
      case CustomMessageRecord():
        return _foldCustomMessage(record);
      default:
        _foldStateRecord(record);
    }
    return 0;
  }

  /// The record-class rows: compaction-family and system-family records
  /// (issue #286 audit rides the system arm). Unknown classes fall here
  /// and are indexed without rows.
  void _foldStateRecord(SessionRecord record) {
    switch (record) {
      case CompactionRecord() ||
          BranchSummaryRecord() ||
          HiddenRangeRecord() ||
          CompactCheckpointRecord() ||
          SegmentPinRecord():
        _appendCompacted(record);
      case ModelChangeRecord() ||
          ActiveToolsChangeRecord() ||
          ThinkingLevelChangeRecord() ||
          CheckpointRecord():
        _appendSystem(record);
      default:
        break; // Labels, session info, leaves: indexed, not rows.
    }
  }

  /// The custom-message rows (context injection, the issue #286 audit
  /// trail, producer-hidden payloads, unknown types).
  int _foldCustomMessage(CustomMessageRecord record) {
    if (record.display && record.customType == 'context') {
      _appendContext(record);
      return 0;
    }
    // The checkpoint lifecycle audit trail (issue #286): renders as a
    // system row so the trajectory shows why protection ended.
    if (record.customType == checkpointAutoClosedCustomType) {
      _appendSystem(record);
      return 0;
    }
    if (!record.display) return 0; // Hidden by its producer, not unknown.
    _appendUnknown(record.id, record.customType, record.timestamp);
    return 0;
  }

  /// The custom-record payloads: request summaries, the issue #385 blob
  /// table, the FinalizeGate task ledger (gh-1412), other surfaces'
  /// hidden records, and unknown types.
  void _foldCustomRecord(CustomRecord record, String customType, Object? data) {
    if (customType == 'model_request_summary') {
      _applyRequestSummary(record, data);
      return;
    }
    // The TaskLedger (gh-1412): hidden last-wins snapshot field, never a
    // ledger row. Corrupt payloads degrade to "no ledger" (a post-mortem
    // artifact must not break a replay).
    if (customType == taskLedgerRecordType) {
      _taskLedger = TaskLedger.fromJson(data);
      return;
    }
    if (_foldBlobRecord(customType, data)) return;
    // Another surface's payload; not a ledger row, not unknown.
    if (hiddenCustomRecordTypes.contains(customType)) return;
    _appendUnknown(record.id, customType, record.timestamp);
  }

  /// Folds a trajectory blob record (issue #385 F1/F2/F5: a unique
  /// prompt/manifest/wire-dump version, stored once) into the blob
  /// table; returns whether [customType] named a blob kind.
  bool _foldBlobRecord(String customType, Object? data) {
    final map = data is Map ? data.cast<String, dynamic>() : null;
    switch (customType) {
      case 'trajectory_prompt_blob':
        if (map != null) {
          _blobs = _blobs.withPromptBlob(TrajectoryPromptBlob.fromJson(map));
        }
      case 'trajectory_manifest_blob':
        if (map != null) {
          _blobs = _blobs.withManifestBlob(
            TrajectoryToolManifestBlob.fromJson(map),
          );
        }
      case 'trajectory_wire_dump':
        if (map != null) {
          _blobs = _blobs.withWireDump(TrajectoryWireDump.fromJson(map));
        }
      default:
        return false;
    }
    return true;
  }

  /// Whether [record] extends the tracked chain tip (or starts the chain).
  bool _chainsToTip(SessionRecord record) =>
      record.parentId == _incTipId ||
      (_incTipId == null && record.parentId == null);

  TrajectorySnapshot applyEvent(AgentEvent event) {
    switch (event) {
      case MessageEndEvent(message: final message):
        _appendRecord(
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
    _rows.reset();
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
    _snapshotsBuilt = 0;
    _chainWalkHops = 0;
    _incTipId = null;
    _incTurn = 0;
    _incStep = 0;
    _incPrevWasUser = false;
    _blobs = const TrajectoryBlobTable();
    _unknownRecordCount = 0;
    _lastPromptRowIndex = null;
    _lastToolsRowIndex = null;
    _activePromptHash = null;
    _prevPromptHash = null;
    _activeManifestHash = null;
    _prevManifestHash = null;
    _reqSorted = null;
    _reqPositions.clear();
    _reqCumulative = <Usage?>[];
    _reqAdded.clear();
    _reqNumberRows.reset();
    _reqPublished = null;
    _reqDirtyFrom = _reqUntouched;
    _reqDirty = true;
    _reqResort = false;
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
    final resolved = _resolveTurnStep(record);
    final turn = resolved.turn;
    final discarded = _discardSyntheticRows('u\u0000$turn');
    final index = _rows.length + 1;
    _rows.add(
      projectUserRecord(
        record: record,
        index: index,
        recordId: trajectoryRecordId(
          kind: 'user',
          recordId: record.id,
          index: index,
        ),
        // A user message opens a turn unless the previous message on its
        // chain is another user message — the fold's carried flag.
        opensTurn: !resolved.previousWasUser,
      ),
    );
    if (synthetic) _registerSyntheticRows('u\u0000$turn', index - 1);
    _liveTurn = turn;
    _liveStep = 0;
    return discarded;
  }

  int _appendAssistant(MessageRecord record, {bool synthetic = false}) {
    final message = record.message as AssistantMessage;
    final resolved = _resolveTurnStep(record);
    final turn = resolved.turn;
    final step = resolved.step;
    final discarded = _discardSyntheticRows('$turn\u0000$step');
    final index = _rows.length + 1;
    _rows.add(
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
    final index = _rows.length + 1;
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
    _rows.add(tool);
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
    final tool = _rows[toolIndex] as TrajectoryToolRecord;
    _rows[toolIndex] = tool.withResult(
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
      CompactCheckpointRecord() => record.text,
      HiddenRangeRecord() => 'hidden ${record.recordIds.length} records',
      SegmentPinRecord() =>
        '${record.pinned ? 'pin' : 'unpin'} ${record.recordIds.length} records',
      _ => '',
    };
    final hiddenRecordIds = record is HiddenRangeRecord
        ? record.recordIds
        : null;
    _rows.add(
      projectCompactedRecord(
        record: record,
        index: _rows.length + 1,
        recordId: trajectoryRecordId(
          kind: 'compacted',
          recordId: record.id,
          index: _rows.length + 1,
        ),
        summary: summary,
        firstKeptEntryId: firstKept,
        previousTime: _prevAbsTime,
        hiddenRecordIds: hiddenRecordIds,
      ),
    );
    final compactionFact = _RequestFacts(
      order: _rows.length.toDouble(),
      turn: _chainTurn(record),
      step: 0,
      purpose: TrajectoryRequestPurpose.compaction,
      provider: '',
      model: '',
      status: TrajectoryRequestStatus.completed,
      startedAt: record.timestamp,
      completedAt: record.timestamp,
    );
    _compactionRequests.add(compactionFact);
    _requestFactAdded(compactionFact);
  }

  void _appendSystem(SessionRecord record) {
    // The checkpoint auto-close audit record (issue #286) is a custom
    // message, not a system record; give it its own system row here.
    if (record is CustomMessageRecord &&
        record.customType == checkpointAutoClosedCustomType) {
      final (change, text) = (
        TrajectorySystemChange.checkpointAutoClosed,
        textPayloadOf(record.content),
      );
      _rows.add(
        TrajectorySystemRecord(
          index: _rows.length + 1,
          recordId: trajectoryRecordId(
            kind: 'system',
            recordId: record.id,
            index: _rows.length + 1,
          ),
          text: text,
          change: change,
          detail: text,
          time: record.timestamp,
        ),
      );
      _lastPromptRowIndex = _rows.length - 1;
      return;
    }
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
    _rows.add(
      TrajectorySystemRecord(
        index: _rows.length + 1,
        recordId: trajectoryRecordId(
          kind: 'system',
          recordId: record.id,
          index: _rows.length + 1,
        ),
        text: text,
        change: change,
        detail: text,
        time: record.timestamp,
        // F7b: the Tools tab renders the real set, not a missing stub.
        activeToolNames: record is ActiveToolsChangeRecord
            ? record.activeToolNames
            : null,
      ),
    );
    // The row stamps with the prompt/manifest pointers its following
    // request summary carries (F7a) — remember where it lives.
    _lastPromptRowIndex = _rows.length - 1;
    if (record is ActiveToolsChangeRecord) {
      _lastToolsRowIndex = _rows.length - 1;
    }
  }

  void _appendContext(CustomMessageRecord record) {
    final text = textPayloadOf(record.content);
    _rows.add(
      TrajectoryContextRecord(
        index: _rows.length + 1,
        recordId: trajectoryRecordId(
          kind: 'context',
          recordId: record.id,
          index: _rows.length + 1,
        ),
        text: text,
        previewMarkdown: text,
        startedAt: record.timestamp,
      ),
    );
  }

  /// Renders an unknown record kind as a context row (F6): the ledger is
  /// provably lossless — nothing vanishes without a trace.
  void _appendUnknown(String recordId, String customType, DateTime time) {
    final text = 'unknown record: $customType';
    _rows.add(
      TrajectoryContextRecord(
        index: _rows.length + 1,
        recordId: trajectoryRecordId(
          kind: 'context',
          recordId: recordId,
          index: _rows.length + 1,
        ),
        text: text,
        previewMarkdown: text,
        startedAt: time,
      ),
    );
    _unknownRecordCount++;
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
      _requestFactTouched(existing);
      return;
    }
    final facts = _RequestFacts(
      order: _rows.length + 0.5,
      turn: turn,
      step: step,
      purpose: TrajectoryRequestPurpose.assistant,
      provider: message.provider,
      model: message.model,
      status: TrajectoryRequestStatus.running,
      startedAt: message.timestamp,
    );
    _assistantRequests[key] = facts;
    _requestFactAdded(facts);
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
    final tool = _rows[toolIndex] as TrajectoryToolRecord;
    _rows[toolIndex] = tool.withStartedAt(startedAt);
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
      // requestDetail does not project into the snapshot's request list.
      facts.requestDetail = detail;
    } else {
      final created = _RequestFacts(
        order: _rows.length + 0.5,
        turn: turnStep.$1,
        step: turnStep.$2,
        purpose: TrajectoryRequestPurpose.assistant,
        provider: '',
        model: '',
        status: TrajectoryRequestStatus.running,
        requestDetail: detail,
      );
      _assistantRequests[key] = created;
      _requestFactAdded(created);
    }
    _stampSystemHashes(detail);
  }

  /// Stamps the latest prompt-bearing/tools-bearing system rows with the
  /// blob pointers this request carries (F7): the System-prompt and Tools
  /// tabs resolve real content from the snapshot's blob table, with the
  /// previous version for the diff views. Version tracking advances only
  /// when the hash changes, so a version's later requests re-stamp the
  /// same pointers without corrupting "previous".
  void _stampSystemHashes(TrajectoryRequestDetail detail) {
    final promptHash = detail.systemPromptHash;
    if (promptHash != null && promptHash != _activePromptHash) {
      _prevPromptHash = _activePromptHash;
      _activePromptHash = promptHash;
    }
    final manifestHash = detail.toolManifestHash;
    if (manifestHash != null && manifestHash != _activeManifestHash) {
      _prevManifestHash = _activeManifestHash;
      _activeManifestHash = manifestHash;
    }
    final promptIndex = _lastPromptRowIndex;
    if (promptIndex != null && promptIndex < _rows.length) {
      final row = _rows[promptIndex];
      if (row is TrajectorySystemRecord) {
        _rows[promptIndex] = row.withHashes(
          systemPromptHash: _activePromptHash,
          previousSystemPromptHash: _prevPromptHash,
        );
      }
    }
    final toolsIndex = _lastToolsRowIndex;
    if (toolsIndex != null && toolsIndex < _rows.length) {
      final row = _rows[toolsIndex];
      if (row is TrajectorySystemRecord) {
        _rows[toolsIndex] = row.withHashes(
          toolManifestHash: _activeManifestHash,
          previousToolManifestHash: _prevManifestHash,
        );
      }
    }
  }

  /// Replays a persisted `model_request_summary` payload onto the matching
  /// turn/step so replayed sessions carry the same request detail as the
  /// live path. The record sits on the chain before its assistant message,
  /// so the chain walk yields the upcoming turn and the step AFTER it (+1).
  void _applyRequestSummary(SessionRecord record, Object? data) {
    if (data is! Map) return;
    // The summary record is not a ledger row: chained appends leave the
    // fold state untouched, so the upcoming assistant sits at
    // (tip turn, tip step + 1) without a walk; a non-chained record falls
    // back to the pure chain walk.
    final (:turn, :step) = _chainsToTip(record)
        ? (turn: _incTurn, step: _incStep)
        : _turnStep(record);
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
      final created = _RequestFacts(
        order: _rows.length.toDouble(),
        turn: turn,
        step: step,
        purpose: TrajectoryRequestPurpose.assistant,
        provider: message.provider,
        model: message.model,
        status: status,
        completedAt: message.timestamp,
        usage: message.usage,
      );
      _assistantRequests['$turn\u0000$step'] = created;
      _requestFactAdded(created);
      return;
    }
    facts
      ..order = _rows.length.toDouble()
      ..status = status
      ..completedAt = message.timestamp
      ..usage = message.usage;
    _requestFactTouched(facts);
  }

  /// Drops streamed rows for [key] so the real record can replace them.
  ///
  /// Streamed rows are the live tail, so removal usually truncates a
  /// contiguous suffix: the tool-row indexes below the cut stay valid and
  /// no rebuild is needed (issue #1497 — the per-discard full rebuild was
  /// O(n), O(n²) over a live session). Rows that are no longer the tail
  /// fall back to the legacy filter + full index rebuild.
  int _discardSyntheticRows(String key) {
    final ids = _syntheticRowsByKey.remove(key);
    if (ids == null || ids.isEmpty) return 0;
    var cut = _rows.length;
    while (cut > 0 && ids.contains(_rows[cut - 1].recordId)) {
      cut--;
    }
    if (ids.length == _rows.length - cut) {
      for (var i = cut; i < _rows.length; i++) {
        final row = _rows[i];
        if (row is TrajectoryToolRecord) {
          _toolIndexByCallId.remove(row.callId);
          _toolOwnerByCallId.remove(row.callId);
        }
      }
      _rows.truncate(cut);
      return ids.length;
    }
    return _discardSyntheticRowsLegacy(ids);
  }

  /// The non-tail fallback: filter the dropped rows out of the middle and
  /// rebuild the tool-row indexes from scratch.
  int _discardSyntheticRowsLegacy(Set<String> ids) {
    final removed = <TrajectoryRecord>[
      for (var i = 0; i < _rows.length; i++)
        if (ids.contains(_rows[i].recordId)) _rows[i],
    ];
    if (removed.isEmpty) return 0;
    var write = 0;
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (!ids.contains(row.recordId)) {
        if (write != i) _rows[write] = row;
        write++;
      }
    }
    _rows.truncate(write);
    for (final row in removed) {
      if (row is TrajectoryToolRecord) {
        _toolIndexByCallId.remove(row.callId);
        _toolOwnerByCallId.remove(row.callId);
      }
    }
    _toolIndexByCallId.clear();
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row is TrajectoryToolRecord) _toolIndexByCallId[row.callId] = i;
    }
    return removed.length;
  }

  void _registerSyntheticRows(String key, int fromIndex) {
    final ids = _syntheticRowsByKey.putIfAbsent(key, () => <String>{});
    for (var i = fromIndex; i < _rows.length; i++) {
      ids.add(_rows[i].recordId);
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

  /// Turn/step of a user or assistant [record] plus the previous-message
  /// role flag its projection needs, folding the chain incrementally
  /// (issue #262): a record extending the tracked chain tip reuses the
  /// carried fold state in O(1); anything else (a branch point, a durable
  /// record landing after streamed rows) walks the parent chain once and
  /// re-adopts the carried state from the walk's result.
  ({int turn, int step, bool previousWasUser}) _resolveTurnStep(
    MessageRecord record,
  ) {
    var previousWasUserBefore = _incPrevWasUser;
    if (_chainsToTip(record)) {
      switch (record.message.role) {
        case 'user':
          if (!previousWasUserBefore) _incTurn++;
          _incStep = 0;
          _incPrevWasUser = true;
        case 'assistant':
          _incStep++;
          _incPrevWasUser = false;
      }
      return (
        turn: _incTurn,
        step: _incStep,
        previousWasUser: previousWasUserBefore,
      );
    }
    var turn = 0;
    var step = 0;
    var previousWasUser = false;
    for (final entry in _chainToRoot(record).reversed) {
      if (entry is! MessageRecord) continue;
      previousWasUserBefore = previousWasUser;
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
    _incTurn = turn;
    _incStep = step;
    _incPrevWasUser = previousWasUser;
    return (turn: turn, step: step, previousWasUser: previousWasUserBefore);
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

  /// Records from [record] (inclusive) to the root, leaf-first.
  List<SessionRecord> _chainToRoot(SessionRecord record) {
    final chain = <SessionRecord>[record];
    var current = record;
    while (current.parentId != null) {
      final parent = _byId[current.parentId!];
      if (parent == null) break;
      _chainWalkHops++;
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
    _snapshotsBuilt++;
    final records = _rows.publish();
    final partial = _partial;
    return TrajectorySnapshot(
      records: UnmodifiableListView(records),
      requests: _publishRequests(),
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
      recordLocations: _LazyRecordLocations(records),
      revision: _revision,
      blobs: _blobs,
      taskLedger: _taskLedger,
      unknownRecordCount: _unknownRecordCount,
    );
  }

  /// The snapshot's request list, shared while no fact changed (issue
  /// #1497): a clean state re-serves the published list, a dirty one
  /// rebuilds only the suffix at/after the first touched fact, and any
  /// state the incremental path cannot prove order-stable falls back to
  /// the exact full sort the pre-#1497 derivation ran.
  UnmodifiableListView<TrajectoryRequestNumber> _publishRequests() {
    if (!_reqDirty) {
      final published = _reqPublished;
      if (published != null) return published;
    }
    if (_reqResort || _reqSorted == null) {
      _rebuildAllRequests();
    } else {
      _insertAddedRequests();
      if (_reqResort) return _publishRequests();
      final from = _reqDirtyFrom < _reqNumberRows.length
          ? _reqDirtyFrom
          : _reqNumberRows.length;
      _rebuildRequestsSuffix(from);
    }
    _reqAdded.clear();
    _reqDirty = false;
    _reqResort = false;
    _reqDirtyFrom = _reqUntouched;
    _reqPublished = UnmodifiableListView(_reqNumberRows.publish());
    return _reqPublished!;
  }

  /// The fallback derivation — byte-identical to the pre-#1497 code: sort
  /// every fact by order and refold cumulative usage from scratch.
  void _rebuildAllRequests() {
    final facts = [..._assistantRequests.values, ..._compactionRequests]
      ..sort((left, right) => left.order.compareTo(right.order));
    _reqSorted = facts;
    _reqPositions.clear();
    _reqNumberRows.reset();
    _reqCumulative = <Usage?>[];
    for (var i = 0; i < facts.length; i++) {
      _reqPositions[facts[i]] = i;
      _foldRequestNumber(i, facts[i], null);
    }
  }

  /// Folds the facts created since the last snapshot into the cached sort.
  void _insertAddedRequests() {
    final sorted = _reqSorted!;
    for (final fact in _reqAdded) {
      // Fact orders fold in from the row count at their creation, which
      // only grows, so a new fact lands at the sorted tail; an
      // out-of-order arrival reverts to the full sort.
      if (sorted.isNotEmpty && fact.order < sorted.last.order) {
        _reqResort = true;
        return;
      }
      _reqPositions[fact] = sorted.length;
      sorted.add(fact);
    }
  }

  /// Rebuilds the cached numbers from [from] to the end: facts before it
  /// are unchanged, so their numbers (and running cumulative usage) carry
  /// over unchanged.
  void _rebuildRequestsSuffix(int from) {
    final sorted = _reqSorted!;
    var cumulative = from == 0 ? null : _reqCumulative[from - 1];
    for (var i = from; i < sorted.length; i++) {
      cumulative = _foldRequestNumber(i, sorted[i], cumulative);
    }
  }

  /// Folds fact [i]'s number and the running cumulative usage into the
  /// cached rows; returns the updated cumulative.
  Usage? _foldRequestNumber(int i, _RequestFacts fact, Usage? cumulative) {
    cumulative = accumulateUsage(cumulative, fact.usage);
    if (i < _reqCumulative.length) {
      _reqCumulative[i] = cumulative;
    } else {
      _reqCumulative.add(cumulative);
    }
    final number = TrajectoryRequestNumber(
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
    );
    if (i < _reqNumberRows.length) {
      _reqNumberRows[i] = number;
    } else {
      _reqNumberRows.add(number);
    }
    return cumulative;
  }

  /// Registers a request fact created since the last snapshot — it has no
  /// cached sorted position yet.
  void _requestFactAdded(_RequestFacts fact) {
    _reqDirty = true;
    _reqAdded.add(fact);
  }

  /// Invalidates the cached requests for a fact whose projected fields
  /// changed.
  void _requestFactTouched(_RequestFacts fact) {
    _reqDirty = true;
    final position = _reqPositions[fact];
    if (position == null) return; // Not built into a cached order yet.
    final sorted = _reqSorted!;
    if (position + 1 < sorted.length &&
        sorted[position + 1].order < fact.order) {
      // The order bump moved the fact past its successor: the cached order
      // is no longer provably the full sort's order — rebuild from scratch.
      _reqResort = true;
    }
    if (position < _reqDirtyFrom) _reqDirtyFrom = position;
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

/// Chunked mutable storage whose published views share frozen chunks
/// (issue #1497).
///
/// The builder appends and patches rows in O(1)/O(chunk); [publish] hands
/// snapshots an immutable list sharing the current chunks, so a snapshot
/// costs O(chunks) reference copies instead of a full row-list copy. The
/// next publish cycle clones a chunk before its first in-place write
/// (copy-on-write per cycle), keeping every published snapshot immutable.
final class _ChunkStore<T> {
  _ChunkStore();

  final List<List<T>> _chunks = <List<T>>[<T>[]];
  final List<int> _chunkEpoch = <int>[0];
  int _length = 0;
  int _epoch = 0;

  /// Total row references copied into published/cloned structures over
  /// this store's life — the deterministic cost metric for the #1497
  /// scaling guard.
  int copiedRows = 0;

  int get length => _length;

  void add(T value) {
    var chunk = _chunks.last;
    if (chunk.length == _chunkSize) {
      chunk = <T>[];
      _chunks.add(chunk);
      _chunkEpoch.add(_epoch);
    }
    chunk.add(value);
    _length++;
  }

  T operator [](int index) => _chunks[index >> _chunkShift][index & _chunkMask];

  void operator []=(int index, T value) {
    final chunkIndex = index >> _chunkShift;
    if (_chunkEpoch[chunkIndex] != _epoch) {
      // Copy-on-write: a published snapshot still shares this chunk.
      copiedRows += _chunks[chunkIndex].length;
      _chunks[chunkIndex] = List.of(_chunks[chunkIndex]);
      _chunkEpoch[chunkIndex] = _epoch;
    }
    _chunks[chunkIndex][index & _chunkMask] = value;
  }

  /// Drops tail rows (streamed-row replacement); published snapshots keep
  /// their view of the dropped chunks.
  void truncate(int newLength) {
    if (newLength == _length) return;
    if (newLength == 0) {
      _chunks.length = 1;
      _chunks[0] = <T>[];
      _chunkEpoch.length = 1;
      _chunkEpoch[0] = _epoch;
      _length = 0;
      return;
    }
    final lastChunk = (newLength - 1) >> _chunkShift;
    if (_chunkEpoch[lastChunk] != _epoch) {
      copiedRows += _chunks[lastChunk].length;
      _chunks[lastChunk] = List.of(_chunks[lastChunk]);
      _chunkEpoch[lastChunk] = _epoch;
    }
    _chunks[lastChunk].length = newLength - (lastChunk << _chunkShift);
    _chunks.length = lastChunk + 1;
    _chunkEpoch.length = lastChunk + 1;
    _length = newLength;
  }

  /// Drops everything (builder reset).
  void reset() {
    _chunks.length = 1;
    _chunks[0] = <T>[];
    _chunkEpoch.length = 1;
    _chunkEpoch[0] = _epoch;
    _length = 0;
    copiedRows = 0;
  }

  /// Publishes the current rows as an immutable shared list and starts a
  /// new copy-on-write cycle.
  List<T> publish() {
    _epoch++;
    copiedRows += _chunks.length;
    return _ChunkList<T>._(List.of(_chunks), _length);
  }

  static const int _chunkShift = 9;
  static const int _chunkSize = 1 << _chunkShift;
  static const int _chunkMask = _chunkSize - 1;
}

/// Immutable chunk-backed list view handed to snapshots (issue #1497): O(1)
/// indexing over shared chunks; every mutator throws, like the
/// `UnmodifiableListView` the snapshots wrap it in.
final class _ChunkList<T> extends ListBase<T> {
  _ChunkList._(this._chunks, this.length);

  final List<List<T>> _chunks;

  @override
  final int length;

  @override
  T operator [](int index) =>
      _chunks[index >> _ChunkStore._chunkShift][index & _ChunkStore._chunkMask];

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');
}

/// Lazily derived `recordLocations` view (issue #1497): the full
/// id→index map is built on first access per snapshot instead of eagerly
/// per append — no lib/ reader touches it on the append path, and the
/// derived content is identical to the eager map it replaces.
final class _LazyRecordLocations extends MapBase<String, int> {
  _LazyRecordLocations(this._rows);

  final List<TrajectoryRecord> _rows;
  Map<String, int>? _derived;

  Map<String, int> get _map => _derived ??= {
    for (final record in _rows) record.recordId: record.index - 1,
  };

  @override
  int? operator [](Object? key) => _map[key];

  @override
  Iterable<String> get keys => _map.keys;

  @override
  void operator []=(String key, int value) =>
      throw UnsupportedError('Cannot modify an unmodifiable map');

  @override
  int? remove(Object? key) =>
      throw UnsupportedError('Cannot modify an unmodifiable map');

  @override
  void clear() => throw UnsupportedError('Cannot modify an unmodifiable map');
}
