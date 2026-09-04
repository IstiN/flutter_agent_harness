// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_cell.dart';
import 'trajectory_controller.dart';
import 'trajectory_group_header.dart';
import 'trajectory_strings.dart';
import 'trajectory_turn.dart';
import 'trajectory_turn_header.dart';

/// Tail-follow engages while the viewport sits within this distance of
/// the bottom edge (TS `BOTTOM_FOLLOW_THRESHOLD_PX`).
const double _bottomFollowThresholdPx = 2;

/// The virtualised trajectory ledger: `ListView.builder` over the flat,
/// projected row list with turn/assistant collapse summaries, search
/// filtering, selection, and tail-follow scrolling.
///
/// Tapping a record row selects it on the controller and reports it
/// through [onRecordTap] (the details-panel seam). While the viewport
/// follows the tail, any structure change (new snapshot, fold, search)
/// scrolls back to the newest row.
class TrajectoryTable extends StatefulWidget {
  /// Creates a table bound to [controller].
  const TrajectoryTable({
    super.key,
    required this.controller,
    this.onRecordTap,
  });

  /// The controller holding the snapshot and interaction state.
  final TrajectoryController controller;

  /// Reports the tapped record after it is selected.
  final ValueChanged<TrajectoryRecord>? onRecordTap;

  @override
  State<TrajectoryTable> createState() => _TrajectoryTableState();
}

class _TrajectoryTableState extends State<TrajectoryTable> {
  final ScrollController _scroll = ScrollController();
  bool _following = true;
  int _lastRevision = -1;
  int _lastRowCount = -1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackFollowing);
  }

  @override
  void dispose() {
    _scroll.removeListener(_trackFollowing);
    _scroll.dispose();
    super.dispose();
  }

  void _trackFollowing() {
    final position = _scroll.position;
    _following =
        position.maxScrollExtent - position.pixels <= _bottomFollowThresholdPx;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (controller.records.isEmpty) return const SizedBox.shrink();
        final rows = projectTrajectoryRows(controller);
        if (rows.isEmpty) {
          return Center(
            child: Text(
              TrajectoryStrings.of(context).searchNoMatches,
              style: TextStyle(fontSize: 13, color: FahColors.of(context).dim),
            ),
          );
        }
        _scheduleTailFollow(controller, rows.length);
        return ListView.builder(
          controller: _scroll,
          itemCount: rows.length,
          // Keep ~4 viewports of rows built so tail-follow and the
          // anchor stays smooth on long sessions.
          scrollCacheExtent: ScrollCacheExtent.viewport(4),
          itemBuilder: (context, index) =>
              _buildRow(context, controller, rows[index]),
        );
      },
    );
  }

  void _scheduleTailFollow(TrajectoryController controller, int rowCount) {
    final structureChanged =
        controller.revision != _lastRevision || rowCount != _lastRowCount;
    _lastRevision = controller.revision;
    _lastRowCount = rowCount;
    if (!_following || !structureChanged) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      _following = true;
    });
  }

  Widget _buildRow(
    BuildContext context,
    TrajectoryController controller,
    TrajectoryLedgerRow row,
  ) => switch (row) {
    TrajectoryTurnHeaderRow(:final turn) => TrajectoryTurnHeader(turn: turn),
    TrajectoryGroupHeaderRow(:final group) => TrajectoryGroupHeader(
      group: group,
    ),
    TrajectoryCellRow(:final record, :final searchMatch) => _cellRow(
      context,
      controller,
      record,
      searchMatch,
    ),
    TrajectoryTurnSummaryRow() => _turnSummaryRow(context, row),
    TrajectoryAssistantSummaryRow() => _assistantSummaryRow(context, row),
  };

  Widget _cellRow(
    BuildContext context,
    TrajectoryController controller,
    TrajectoryRecord record,
    bool searchMatch,
  ) {
    final colors = FahColors.of(context);
    final selected = controller.selectedRecordId == record.recordId;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        controller.selectRecord(record.recordId);
        widget.onRecordTap?.call(record);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? colors.panelAlt
              : searchMatch
              ? colors.teal.withValues(alpha: 0.08)
              : null,
          border: selected
              ? Border(left: BorderSide(color: colors.teal, width: 2))
              : null,
        ),
        child: buildTrajectoryCell(context, record),
      ),
    );
  }

  Widget _turnSummaryRow(BuildContext context, TrajectoryTurnSummaryRow row) {
    final strings = TrajectoryStrings.of(context);
    return _summaryRow(
      context,
      '${strings.summarySteps(row.steps)} · ${strings.summaryToolCalls(row.toolCalls)}',
      () => widget.controller.toggleTurn(row.turn),
    );
  }

  Widget _assistantSummaryRow(
    BuildContext context,
    TrajectoryAssistantSummaryRow row,
  ) {
    final strings = TrajectoryStrings.of(context);
    return _summaryRow(
      context,
      [
        strings.summaryToolCalls(row.toolCalls),
        if (row.names.isNotEmpty) row.names.join(', '),
      ].join(' · '),
      () => widget.controller.toggleAssistant(row.assistantId),
    );
  }

  Widget _summaryRow(BuildContext context, String label, VoidCallback onTap) {
    final colors = FahColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        color: colors.bgAlt,
        child: Text(
          '… $label',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colors.dim),
        ),
      ),
    );
  }
}
