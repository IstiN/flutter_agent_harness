/// Trajectory list fold: turn/group layout with wall-span descriptions.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// layout.ts` (`deriveTrajectoryLayout`), adapted to the phase-1 record
/// model: rows arrive pre-projected, so the fold groups them by turn and
/// step, inserts request-only separators for unrepresented requests, and
/// appends running calls after the entries placed by turn/step. The locale
/// stays out of the core: groups carry [TrajectoryGroupKind] plus an optional
/// step number, and hosts render titles.
library;

import 'event_projection.dart';
import 'formatters.dart';
import 'trajectory_record.dart';
import 'trajectory_snapshot.dart';

/// What a group aggregates: a loose message run, a numbered assistant step,
/// or a compaction.
enum TrajectoryGroupKind { message, step, compaction }

/// One Message or Step group inside a turn.
final class TrajectoryGroupModel {
  /// Creates a [TrajectoryGroupModel].
  const TrajectoryGroupModel({
    required this.kind,
    required this.cells,
    this.stepNumber,
    this.description,
  });

  /// Which kind of group this is.
  final TrajectoryGroupKind kind;

  /// Step number for [TrajectoryGroupKind.step] groups.
  final int? stepNumber;

  /// Wall-span duration plus tool histogram (e.g. `1,500 ms bash×6`).
  final String? description;

  /// Ledger rows of the group, in display order.
  final List<TrajectoryRecord> cells;
}

/// One sticky turn, or a standalone compaction section between turns.
///
/// [turn] is null for standalone compaction sections; hosts render a
/// "between turns" header for those.
final class TrajectoryTurnModel {
  /// Creates a [TrajectoryTurnModel].
  const TrajectoryTurnModel({required this.turn, required this.groups});

  /// 1-based turn number, or null between turns.
  final int? turn;

  /// Groups of the turn, in display order.
  final List<TrajectoryGroupModel> groups;
}

/// Folds a snapshot into turns of Message/Step groups.
///
/// User, context, and system rows enclose into the next assistant turn, else
/// the in-flight partial's turn (anchoring the streaming turn without
/// emitting cells), else one past the last assistant turn, else 1. Compaction
/// rows become standalone sections. Requests with no represented record for
/// their turn/step produce request-only separator rows; running calls append
/// after the placed entries. Orphan turn-0 cells fold into Turn 1's prefix.
List<TrajectoryTurnModel> deriveTrajectoryLayout(TrajectorySnapshot snapshot) {
  final records = snapshot.records.toList();
  final followingAssistantTurn = _indexFollowingAssistantTurns(records);
  final represented = _representedRequests(snapshot);
  final emittedCalls = {
    for (final record in records)
      if (record is TrajectoryToolRecord) record.callId,
  };

  final turns = <int, _TurnBucket>{};
  final standaloneCompactions = <_TurnBucket>[];
  var index = records.length;
  var lastAssistantTurn = 0;
  var currentTurn = 0;
  var currentStep = 0;

  _TurnBucket bucket(int turn) => turns.putIfAbsent(turn, _TurnBucket.new);

  void pushMessage(int turn, _LaidCell laid) {
    final groups = bucket(turn).groups;
    if (groups.isNotEmpty && groups.last.kind == TrajectoryGroupKind.message) {
      groups.last.laid.add(laid);
      return;
    }
    groups.add(_Group(kind: TrajectoryGroupKind.message, laid: [laid]));
  }

  void pushStep(int turn, int step, _LaidCell laid) {
    final groups = bucket(turn).groups;
    for (final group in groups) {
      if (group.kind == TrajectoryGroupKind.step && group.stepNumber == step) {
        group.laid.add(laid);
        return;
      }
    }
    groups.add(
      _Group(kind: TrajectoryGroupKind.step, stepNumber: step, laid: [laid]),
    );
  }

  for (final request in snapshot.requests) {
    if (request.purpose != TrajectoryRequestPurpose.assistant) continue;
    if (represented.contains('${request.turn}\u0000${request.step}')) continue;
    pushStep(request.turn, request.step, _requestOnlyCell(request, ++index));
  }

  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    switch (record) {
      case final TrajectoryAssistantRecord assistant:
        final laid = _LaidCell(
          cell: assistant,
          absTime: assistant.completedTime ?? assistant.stepStartTime,
        );
        if (assistant.step > 0) {
          pushStep(assistant.turn, assistant.step, laid);
        } else {
          pushMessage(assistant.turn, laid);
        }
        currentTurn = assistant.turn;
        currentStep = assistant.step;
        lastAssistantTurn = assistant.turn;
      case final TrajectoryToolRecord tool:
        pushStep(
          currentTurn,
          currentStep == 0 ? 1 : currentStep,
          _LaidCell(cell: tool, absTime: tool.startedAt, toolName: tool.name),
        );
      case TrajectoryUserRecord() || TrajectoryContextRecord():
        pushMessage(
          _enclosingTurn(
            followingAssistantTurn[i],
            snapshot.partial?.turn,
            lastAssistantTurn,
          ),
          _LaidCell(
            cell: record,
            absTime: switch (record) {
              final TrajectoryUserRecord user => user.startedAt,
              _ => null,
            },
          ),
        );
      case final TrajectorySystemRecord system:
        pushMessage(
          system.change == TrajectorySystemChange.initial
              ? _firstVisibleTurn(records, snapshot.partial?.turn)
              : _enclosingTurn(
                  followingAssistantTurn[i],
                  snapshot.partial?.turn,
                  lastAssistantTurn,
                ),
          _LaidCell(cell: system, absTime: system.time),
        );
      case final TrajectoryCompactedRecord compacted:
        standaloneCompactions.add(
          _TurnBucket([
            _Group(
              kind: TrajectoryGroupKind.compaction,
              laid: [_LaidCell(cell: compacted, absTime: compacted.startedAt)],
            ),
          ]),
        );
    }
  }

  for (final call in snapshot.runningCalls) {
    if (emittedCalls.contains(call.callId)) continue;
    index++;
    pushStep(
      call.turn,
      call.step == 0 ? 1 : call.step,
      _LaidCell(
        cell: TrajectoryToolRecord(
          index: index,
          recordId: trajectoryRecordId(
            kind: 'tool',
            callId: call.callId,
            index: index,
          ),
          callId: call.callId,
          parentCallId: null,
          name: call.name,
          argsRaw: '',
          startedAt: call.startedAt,
        ),
        absTime: call.startedAt,
        toolName: call.name,
      ),
    );
  }

  // Orphan turn-0 cells (orphaned tools) fold into Turn 1's prefix.
  final prologue = turns.remove(0);
  if (prologue != null) {
    bucket(1).groups.insertAll(0, prologue.groups);
  }

  final models =
      [
        ...turns.entries.map((entry) => (entry.key as int?, entry.value)),
        ...standaloneCompactions.map((entry) => (null, entry)),
      ]..sort(
        (left, right) => _firstCellIndex(left.$2) - _firstCellIndex(right.$2),
      );
  return [
    for (final (turn, entry) in models)
      TrajectoryTurnModel(
        turn: turn,
        groups: [
          for (final group in entry.groups)
            TrajectoryGroupModel(
              kind: group.kind,
              stepNumber: group.stepNumber,
              description: _groupDescription(group.laid),
              cells: [for (final laid in group.laid) laid.cell],
            ),
        ],
      ),
  ];
}

/// Request-only separator row for an assistant request with no represented
/// record: carries the request timing and fails visibly on error.
_LaidCell _requestOnlyCell(TrajectoryRequestNumber request, int index) {
  return _LaidCell(
    cell: TrajectoryAssistantRecord(
      index: index,
      recordId: 'request\u0000${request.seq}',
      messageId: '',
      turn: request.turn,
      step: request.step,
      requestOnly: true,
      stepStartTime: request.startedAt,
      timeSeconds: trajectoryDurationSeconds(
        request.completedAt,
        request.startedAt,
      ),
      isError: request.status == TrajectoryRequestStatus.failed ? true : null,
    ),
    absTime: request.startedAt,
  );
}

/// A cell plus the absolute time and tool name the fold needs for spans.
class _LaidCell {
  /// Creates a [_LaidCell].
  const _LaidCell({required this.cell, this.absTime, this.toolName});

  /// The ledger row.
  final TrajectoryRecord cell;

  /// Absolute wall-clock anchor of the row, when known.
  final DateTime? absTime;

  /// Tool name for histogram entries.
  final String? toolName;
}

class _Group {
  /// Creates a [_Group].
  _Group({required this.kind, required this.laid, this.stepNumber});

  /// Group kind.
  final TrajectoryGroupKind kind;

  /// Step number for step groups.
  final int? stepNumber;

  /// Cells with their fold metadata.
  final List<_LaidCell> laid;
}

class _TurnBucket {
  /// Creates a bucket, optionally seeded with groups.
  _TurnBucket([List<_Group>? initial]) : groups = initial ?? [];

  /// Groups of one turn.
  final List<_Group> groups;
}

/// Turn keys `${turn}\u0000${step}` that a placed record already represents.
Set<String> _representedRequests(TrajectorySnapshot snapshot) {
  final represented = <String>{
    for (final record in snapshot.records)
      if (record is TrajectoryAssistantRecord && record.step > 0)
        '${record.turn}\u0000${record.step}',
  };
  final partial = snapshot.partial;
  if (partial != null && partial.step > 0) {
    represented.add('${partial.turn}\u0000${partial.step}');
  }
  for (final call in snapshot.runningCalls) {
    if (call.step > 0) represented.add('${call.turn}\u0000${call.step}');
  }
  return represented;
}

/// Turn of the next assistant record after each position, null at the tail.
List<int?> _indexFollowingAssistantTurns(List<TrajectoryRecord> records) {
  final following = List<int?>.filled(records.length, null);
  int? assistantTurn;
  for (var i = records.length - 1; i >= 0; i--) {
    following[i] = assistantTurn;
    final record = records[i];
    if (record is TrajectoryAssistantRecord) assistantTurn = record.turn;
  }
  return following;
}

/// Turn enclosing a user/context/system row: next assistant turn, else the
/// in-flight partial, else one past the last assistant (or 1).
int _enclosingTurn(
  int? followingAssistant,
  int? partialTurn,
  int lastAssistant,
) {
  if (followingAssistant != null) return followingAssistant;
  if (partialTurn != null) return partialTurn;
  return lastAssistant + 1;
}

/// Earliest raw turn represented by the snapshot's assistant rows.
int _firstVisibleTurn(List<TrajectoryRecord> records, int? partialTurn) {
  final assistantTurns = [
    for (final record in records)
      if (record is TrajectoryAssistantRecord && record.turn > 0) record.turn,
    if (partialTurn != null && partialTurn > 0) partialTurn,
  ];
  return assistantTurns.isEmpty ? 1 : assistantTurns.reduce(_min);
}

int _min(int left, int right) => left < right ? left : right;

/// Chronological section position from the fold's assigned cell indexes.
int _firstCellIndex(_TurnBucket entry) {
  var best = -1;
  for (final group in entry.groups) {
    for (final laid in group.laid) {
      final index = laid.cell.index;
      if (best == -1 || index < best) best = index;
    }
  }
  return best;
}

/// Wall-span duration plus tool histogram, e.g. `1,500 ms bash×6`.
///
/// Tool rows contribute start (absolute time) and end (start plus own
/// duration) so a single tool cell still spans call→result for the group
/// wall clock; a lone time contributes that cell's own duration.
String? _groupDescription(List<_LaidCell> laid) {
  final parts = <String>[];
  final times = <DateTime>[];
  for (final laidCell in laid) {
    final start = laidCell.absTime;
    if (start == null) continue;
    times.add(start);
    final record = laidCell.cell;
    if (record is TrajectoryToolRecord && record.timeSeconds != null) {
      times.add(start.add(record.timeSeconds!));
    }
  }
  if (times.length >= 2) {
    var latest = times.first;
    var earliest = times.first;
    for (final time in times) {
      if (time.isAfter(latest)) latest = time;
      if (time.isBefore(earliest)) earliest = time;
    }
    parts.add(
      formatElapsedSeconds(latest.difference(earliest).inMilliseconds / 1000.0),
    );
  } else if (times.length == 1) {
    final own = _singleCellDuration(laid, times.single);
    if (own != null) {
      parts.add(formatElapsedSeconds(own.inMilliseconds / 1000.0));
    }
  }
  final tools = <String, int>{};
  for (final laidCell in laid) {
    final record = laidCell.cell;
    if (laidCell.toolName == null || record is! TrajectoryToolRecord) continue;
    if (record.parentCallId != null) continue;
    tools[laidCell.toolName!] = (tools[laidCell.toolName!] ?? 0) + 1;
  }
  for (final MapEntry(key: name, value: count) in tools.entries) {
    parts.add(count > 1 ? '$name×$count' : name);
  }
  return parts.isEmpty ? null : parts.join(' ');
}

/// Own duration of the lone timed cell in a single-time group.
Duration? _singleCellDuration(List<_LaidCell> laid, DateTime time) {
  for (final laidCell in laid) {
    if (laidCell.absTime != time) continue;
    final record = laidCell.cell;
    if (record is TrajectoryToolRecord) return record.timeSeconds;
    if (record is TrajectoryAssistantRecord) return record.timeSeconds;
    if (record is TrajectoryCompactedRecord) return record.timeSeconds;
  }
  return null;
}
