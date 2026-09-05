// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;

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

/// Left padding added to subtool rows (nested under their parent call).
const double _subtoolIndent = 24;

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
  final FocusNode _feedFocus = FocusNode();
  bool _following = true;
  int _lastRevision = -1;
  int _lastRowCount = -1;

  /// Cell rows as `(listViewIndex, recordId)` in display order — the
  /// arrow-key navigation path.
  List<(int, String)> _cellEntries = const [];

  /// Per-list-index row contexts, for scrolling the selected row into
  /// view during keyboard navigation.
  final Map<int, BuildContext> _rowContexts = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackFollowing);
  }

  @override
  void dispose() {
    _scroll.removeListener(_trackFollowing);
    _scroll.dispose();
    _feedFocus.dispose();
    super.dispose();
  }

  void _trackFollowing() {
    final position = _scroll.position;
    _following =
        position.maxScrollExtent - position.pixels <= _bottomFollowThresholdPx;
  }

  /// Moves the selection by [delta] cell rows and scrolls it into view.
  /// Only active while the feed itself holds focus, so the search field
  /// keeps its arrow keys.
  void _moveSelection(int delta) {
    final entries = _cellEntries;
    if (entries.isEmpty) return;
    var index = entries.indexWhere(
      (entry) => entry.$2 == widget.controller.selectedRecordId,
    );
    index = index < 0
        ? (delta > 0 ? 0 : entries.length - 1)
        : (index + delta).clamp(0, entries.length - 1);
    final (listIndex, recordId) = entries[index];
    widget.controller.selectRecord(recordId);
    final rowContext = _rowContexts[listIndex];
    if (rowContext != null) {
      Scrollable.ensureVisible(
        rowContext,
        duration: const Duration(milliseconds: 80),
      );
    }
    _feedFocus.requestFocus();
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
        _cellEntries = [
          for (final (index, row) in rows.indexed)
            if (row is TrajectoryCellRow) (index, row.record.recordId),
        ];
        _rowContexts.clear();
        return SelectionArea(
          child: CallbackShortcuts(
            bindings: {
              SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _moveSelection(-1),
              SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _moveSelection(1),
            },
            child: Focus(
              focusNode: _feedFocus,
              child: ListView.builder(
                controller: _scroll,
                itemCount: rows.length,
                // Keep ~4 viewports of rows built so tail-follow and the
                // anchor stays smooth on long sessions.
                scrollCacheExtent: ScrollCacheExtent.viewport(4),
                itemBuilder: (context, index) {
                  _rowContexts[index] = context;
                  return _buildRow(context, controller, rows[index]);
                },
              ),
            ),
          ),
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
    final order = controller.searchMatchOrder;
    final currentMatch =
        controller.currentMatchIndex != null &&
        order.isNotEmpty &&
        order[controller.currentMatchIndex!] == record.recordId;
    // Tint precedence: selection > current match > match > error.
    final tint = selected
        ? colors.panelAlt
        : currentMatch
        ? colors.teal.withValues(alpha: 0.16)
        : searchMatch
        ? colors.teal.withValues(alpha: 0.08)
        : trajectoryRecordIsError(record)
        ? colors.error.withValues(alpha: 0.07)
        : null;
    return _FeedRow(
      controller: controller,
      record: record,
      selected: selected,
      tint: tint,
      expanded: controller.expandedRecordIds.contains(record.recordId),
      onToggleExpanded: () => controller.toggleExpandedRow(record.recordId),
      onTap: () {
        controller.selectRecord(record.recordId);
        _feedFocus.requestFocus();
        widget.onRecordTap?.call(record);
      },
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

/// Whether the record failed, for the row tint. Mirrors the controller's
/// filter predicate (private there).
bool trajectoryRecordIsError(TrajectoryRecord record) => switch (record) {
  TrajectoryAssistantRecord(:final isError) => isError ?? false,
  TrajectoryToolRecord(:final isError) => isError,
  TrajectoryCompactedRecord(:final interrupted) => interrupted,
  TrajectorySystemRecord(:final errorCode, :final errorMessage) =>
    errorCode != null || errorMessage != null,
  _ => false,
};

/// One virtualised feed row: tint + selection state around the cell, the
/// expand chevron and hover-reveal copy affordance, the subtool indent,
/// and the inline expanded body when open.
///
/// Wrapping the whole table in a [SelectionArea] keeps rows selectable
/// and copyable across rows while taps still select the record.
class _FeedRow extends StatefulWidget {
  const _FeedRow({
    required this.controller,
    required this.record,
    required this.selected,
    required this.tint,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onTap,
  });

  final TrajectoryController controller;
  final TrajectoryRecord record;
  final bool selected;
  final Color? tint;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onTap;

  @override
  State<_FeedRow> createState() => _FeedRowState();
}

class _FeedRowState extends State<_FeedRow> {
  var _hovering = false;

  /// Touch platforms have no hover — there the copy affordance stays
  /// visible instead. (Long-press stays with the SelectionArea's word
  /// selection, so it cannot be the copy gesture.)
  bool get _alwaysVisibleCopy =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  void _copy() => copyTrajectoryRecord(widget.record);

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    final record = widget.record;
    final indent = record is TrajectoryToolRecord && record.parentCallId != null
        ? _subtoolIndent
        : 0.0;
    final expandable = trajectoryRowExpandable(record);
    final copyVisible = _alwaysVisibleCopy || _hovering;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(12 + indent, 4, 4, 4),
          decoration: BoxDecoration(
            color: widget.tint,
            border: widget.selected
                ? Border(left: BorderSide(color: colors.teal, width: 2))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (expandable) _chevron(context, strings),
                  Expanded(child: buildTrajectoryCell(context, record)),
                  _copyButton(context, strings, copyVisible),
                ],
              ),
              if (widget.expanded) TrajectoryExpandedBody(record: record),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chevron(BuildContext context, TrajectoryStrings strings) =>
      IconButton(
        onPressed: widget.onToggleExpanded,
        tooltip: widget.expanded ? strings.rowCollapse : strings.rowExpand,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        icon: AnimatedRotation(
          turns: widget.expanded ? 0 : -0.25,
          duration: const Duration(milliseconds: 120),
          child: const Icon(Icons.expand_more, size: 16),
        ),
      );

  Widget _copyButton(
    BuildContext context,
    TrajectoryStrings strings,
    bool visible,
  ) => Opacity(
    opacity: visible ? 1 : 0,
    child: IgnorePointer(
      ignoring: !visible,
      child: IconButton(
        onPressed: _copy,
        tooltip: strings.detailsCopy,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        icon: const Icon(Icons.copy, size: 13),
      ),
    ),
  );
}
