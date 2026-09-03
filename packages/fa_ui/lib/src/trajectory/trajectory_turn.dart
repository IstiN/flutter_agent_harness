// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_controller.dart';

/// One virtualised ledger row: a turn header, a group header, a record
/// cell, or one of the two collapse summaries.
///
/// [projectTrajectoryRows] folds the controller's turns into this flat
/// display list; [TrajectoryTable] renders it with `ListView.builder`.
sealed class TrajectoryLedgerRow {
  /// Creates the row.
  const TrajectoryLedgerRow();
}

/// A sticky "Turn N" / "Between turns" section header.
final class TrajectoryTurnHeaderRow extends TrajectoryLedgerRow {
  /// Creates the header.
  const TrajectoryTurnHeaderRow(this.turn);

  /// The section's turn model.
  final TrajectoryTurnModel turn;
}

/// A "Message" / "Step N" / "Compaction N" group header with its
/// wall-span description.
final class TrajectoryGroupHeaderRow extends TrajectoryLedgerRow {
  /// Creates the header.
  const TrajectoryGroupHeaderRow(this.group);

  /// The group the following cells belong to.
  final TrajectoryGroupModel group;
}

/// One projected record cell.
final class TrajectoryCellRow extends TrajectoryLedgerRow {
  /// Creates the cell row.
  const TrajectoryCellRow({
    required this.record,
    this.turnStart = false,
    this.turnEnd = false,
    this.searchMatch = false,
  });

  /// The projected record.
  final TrajectoryRecord record;

  /// First qualifying record of the section (not request-only, not
  /// system, compacted only in null-turn sections).
  final bool turnStart;

  /// Last record of the section.
  final bool turnEnd;

  /// Whether the active search selected this record.
  final bool searchMatch;
}

/// The summary row replacing the folded tail of a collapsed turn:
/// "N steps · M tool calls". Tapping it expands the turn.
final class TrajectoryTurnSummaryRow extends TrajectoryLedgerRow {
  /// Creates the summary.
  const TrajectoryTurnSummaryRow({
    required this.turn,
    required this.steps,
    required this.toolCalls,
  });

  /// The collapsed turn number.
  final int turn;

  /// Distinct request-group keys among the hidden rows.
  final int steps;

  /// Tool and subtool calls among the hidden rows.
  final int toolCalls;
}

/// The summary row replacing a collapsed assistant's contiguous tool
/// run: "N tool calls · name, name". Tapping it expands the run.
final class TrajectoryAssistantSummaryRow extends TrajectoryLedgerRow {
  /// Creates the summary.
  const TrajectoryAssistantSummaryRow({
    required this.assistantId,
    required this.toolCalls,
    required this.names,
  });

  /// The collapsed assistant message record id.
  final String assistantId;

  /// Hidden tool and subtool call count.
  final int toolCalls;

  /// Deduplicated tool names in display order.
  final List<String> names;
}

/// Folds the controller's turns into the flat ledger row list.
///
/// With an active search the table filters to matching records and
/// recomputes the section separators (search overrides both folds);
/// otherwise collapsed turns and collapsed assistant runs are replaced
/// by their summary rows.
List<TrajectoryLedgerRow> projectTrajectoryRows(
  TrajectoryController controller,
) {
  final matches = controller.searchMatchRecordIds;
  if (matches != null) return _searchRows(controller.turns, matches);
  final rows = <TrajectoryLedgerRow>[];
  for (final turn in controller.turns) {
    rows.add(TrajectoryTurnHeaderRow(turn));
    final collapsed =
        turn.turn != null && controller.collapsedTurns.contains(turn.turn);
    rows.addAll(
      collapsed
          ? _collapsedTurnRows(turn, controller.collapsedAssistants)
          : _expandedTurnRows(turn, controller.collapsedAssistants),
    );
  }
  return rows;
}

bool _qualifies(TrajectoryRecord record, int? turn) =>
    record is! TrajectoryAssistantRecord ||
    !record.requestOnly &&
        record.kind != TrajectoryCellKind.system &&
        (turn == null || record.kind != TrajectoryCellKind.compacted);

List<TrajectoryLedgerRow> _expandedTurnRows(
  TrajectoryTurnModel turn,
  Set<String> collapsedAssistants,
) {
  final flat = [for (final group in turn.groups) ...group.cells];
  final headers = {
    for (final group in turn.groups)
      if (group.cells.isNotEmpty) group.cells.first: group,
  };
  final turnStart = flat.indexWhere((record) => _qualifies(record, turn.turn));
  final rows = <TrajectoryLedgerRow>[];
  var i = 0;
  while (i < flat.length) {
    final record = flat[i];
    final header = headers[record];
    if (header != null) rows.add(TrajectoryGroupHeaderRow(header));
    if (record is TrajectoryAssistantRecord &&
        collapsedAssistants.contains(record.recordId)) {
      final run = <TrajectoryToolRecord>[
        for (
          var j = i + 1;
          j < flat.length && flat[j] is TrajectoryToolRecord;
          j++
        )
          flat[j] as TrajectoryToolRecord,
      ];
      if (run.isNotEmpty) {
        rows.add(_cell(record, turnStart: i == turnStart, turnEnd: false));
        rows.add(_assistantSummary(record.recordId, run));
        i += 1 + run.length;
        continue;
      }
    }
    rows.add(
      _cell(record, turnStart: i == turnStart, turnEnd: i == flat.length - 1),
    );
    i++;
  }
  return rows;
}

List<TrajectoryLedgerRow> _collapsedTurnRows(
  TrajectoryTurnModel turn,
  Set<String> collapsedAssistants,
) {
  final flat = [for (final group in turn.groups) ...group.cells];
  final content = [
    for (final record in flat)
      if (_qualifies(record, turn.turn)) record,
  ];
  // A turn with at most one content row has nothing to fold away.
  if (content.length <= 1) return _expandedTurnRows(turn, collapsedAssistants);
  final turnStart = content.first;
  final rows = <TrajectoryLedgerRow>[];
  var summaryEmitted = false;
  for (final record in flat) {
    if (identical(record, turnStart)) {
      rows.add(_cell(record, turnStart: true, turnEnd: false));
    } else if (!_qualifies(record, turn.turn)) {
      rows.add(_cell(record));
    } else if (!summaryEmitted) {
      final hidden = content.skip(1).toList();
      rows.add(
        TrajectoryTurnSummaryRow(
          turn: turn.turn!,
          steps: _steps(hidden),
          toolCalls: _toolCalls(hidden),
        ),
      );
      summaryEmitted = true;
    }
  }
  return rows;
}

List<TrajectoryLedgerRow> _searchRows(
  List<TrajectoryTurnModel> turns,
  Set<String> matches,
) {
  final rows = <TrajectoryLedgerRow>[];
  for (final turn in turns) {
    final visibleGroups = [
      for (final group in turn.groups)
        if (group.cells.any((record) => matches.contains(record.recordId)))
          group,
    ];
    if (visibleGroups.isEmpty) continue;
    rows.add(TrajectoryTurnHeaderRow(turn));
    final visible = [
      for (final group in visibleGroups) ...group.cells,
    ].where((record) => matches.contains(record.recordId)).toList();
    final turnStart = visible.indexWhere(
      (record) => _qualifies(record, turn.turn),
    );
    for (final group in visibleGroups) {
      rows.add(TrajectoryGroupHeaderRow(group));
      for (final record in group.cells) {
        if (!matches.contains(record.recordId)) continue;
        rows.add(
          _cell(
            record,
            turnStart: visible.indexOf(record) == turnStart,
            turnEnd: identical(record, visible.last),
            searchMatch: true,
          ),
        );
      }
    }
  }
  return rows;
}

TrajectoryCellRow _cell(
  TrajectoryRecord record, {
  bool turnStart = false,
  bool turnEnd = false,
  bool searchMatch = false,
}) => TrajectoryCellRow(
  record: record,
  turnStart: turnStart,
  turnEnd: turnEnd,
  searchMatch: searchMatch,
);

TrajectoryAssistantSummaryRow _assistantSummary(
  String assistantId,
  List<TrajectoryToolRecord> run,
) => TrajectoryAssistantSummaryRow(
  assistantId: assistantId,
  toolCalls: run.length,
  names: _names(run),
);

List<String> _names(List<TrajectoryToolRecord> run) {
  final seen = <String>{};
  return [
    for (final record in run)
      if (seen.add(record.name)) record.name,
  ];
}

int _steps(List<TrajectoryRecord> records) => {
  for (final record in records)
    if (record is TrajectoryAssistantRecord) '${record.turn} ${record.step}',
}.length;

int _toolCalls(List<TrajectoryRecord> records) => records
    .where(
      (record) =>
          record.kind == TrajectoryCellKind.tool ||
          record.kind == TrajectoryCellKind.subtool,
    )
    .length;
