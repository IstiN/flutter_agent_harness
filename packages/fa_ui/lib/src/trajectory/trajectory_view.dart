// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../chat/fa_chat_screen.dart' show kWideLayoutBreakpoint;
import '../theme/app_theme.dart';
import 'trajectory_controller.dart';
import 'trajectory_details.dart';
import 'trajectory_details_tabs.dart';
import 'trajectory_strings.dart';
import 'trajectory_table.dart';
import 'trajectory_timeline.dart';
import 'trajectory_toolbar.dart';

/// Builds the timeline strip above the ledger; defaults to the real
/// [TrajectoryTimeline]. Tests and hosts can inject a replacement.
typedef TrajectoryTimelineBuilder =
    Widget Function(BuildContext context, TrajectoryController controller);

/// Builds the ledger table; defaults to the real [TrajectoryTable] wired
/// to the details sheet. Tests and hosts can inject a replacement.
typedef TrajectoryTableBuilder =
    Widget Function(BuildContext context, TrajectoryController controller);

/// The trajectory ledger surface: toolbar, timeline strip, and event table
/// driven by one [TrajectoryController].
///
/// With an empty snapshot the table area shows a "no records" placeholder
/// and the toolbar disables. The seams exist so hosts (and tests) can
/// replace the timeline and table independently.
class TrajectoryView extends StatefulWidget {
  /// Creates a view bound to [controller].
  const TrajectoryView({
    super.key,
    required this.controller,
    this.tableBuilder,
    this.timelineBuilder,
  });

  /// The controller holding the snapshot and interaction state.
  final TrajectoryController controller;

  /// The ledger table seam; null renders nothing.
  final TrajectoryTableBuilder? tableBuilder;

  /// The timeline strip seam; null renders nothing.
  final TrajectoryTimelineBuilder? timelineBuilder;

  @override
  State<TrajectoryView> createState() => _TrajectoryViewState();
}

class _TrajectoryViewState extends State<TrajectoryView> {
  void _rebuild() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(TrajectoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = TrajectoryStrings.of(context);
    final controller = widget.controller;
    final empty = controller.snapshot.records.isEmpty;
    final timeline =
        widget.timelineBuilder?.call(context, controller) ??
        TrajectoryTimeline(controller: controller);
    // An empty snapshot renders the placeholder instead of the table seam,
    // so the builder is not invoked at all.
    final table = empty
        ? null
        : widget.tableBuilder?.call(context, controller) ??
              TrajectoryTable(
                controller: controller,
                onRecordTap: (record) => showTrajectoryDetails(
                  context,
                  record: record,
                  snapshot: controller.snapshot,
                ),
              );
    return Semantics(
      container: true,
      label: strings.viewTrajectory,
      child: Column(
        children: [
          TrajectoryToolbar(controller: controller),
          timeline,
          Expanded(
            child: empty
                ? Center(child: Text(strings.viewNoRecords))
                : (table ?? const SizedBox.shrink()),
          ),
        ],
      ),
    );
  }
}

/// The trajectory surface shell: [TrajectoryHeader] above the ledger, and
/// on wide canvases (>= [kWideLayoutBreakpoint]) a persistent details pane
/// split against it (ledger ~55% / details ~45%) bound to the selected
/// record. Narrow canvases keep the tap-for-details sheet. [onClose] null
/// hides the header's close affordance (embedded hosts).
class TrajectoryBody extends StatelessWidget {
  /// Creates the shell body bound to [controller].
  const TrajectoryBody({super.key, required this.controller, this.onClose});

  /// The controller holding the snapshot and interaction state.
  final TrajectoryController controller;

  /// Pops the surface (route close / switch back to chat); null hides it.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    // Wide master-detail: row taps select (the pane follows) instead of
    // opening the modal sheet.
    final feed = TrajectoryView(
      controller: controller,
      tableBuilder: isWide
          ? (context, controller) => TrajectoryTable(controller: controller)
          : null,
    );
    return Column(
      children: [
        TrajectoryHeader(controller: controller, onClose: onClose),
        const Divider(height: 1),
        Expanded(
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 55, child: feed),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 45, child: TrajectoryDetailsPane(controller: controller)),
                  ],
                )
              : feed,
        ),
      ],
    );
  }
}

/// The trajectory header: title + session label, the stats cluster, the
/// search field with match count and prev/next navigation, and the ledger
/// filter chips. Every control binds straight to the controller.
class TrajectoryHeader extends StatelessWidget {
  /// Creates the header bound to [controller].
  const TrajectoryHeader({super.key, required this.controller, this.onClose});

  /// The controller whose search/filter/stats state this header drives.
  final TrajectoryController controller;

  /// Closes the surface; null hides the close button.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final strings = TrajectoryStrings.of(context);
    final colors = FahColors.of(context);
    final theme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: strings.headerAria,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final stats = controller.stats;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(strings.viewTrajectory, style: theme.titleMedium),
                          if (stats.startedAt case final startedAt?)
                            Text(
                              strings.headerSession(_formatStamp(startedAt)),
                              style: theme.bodySmall?.copyWith(color: colors.dim),
                            ),
                        ],
                      ),
                    ),
                    if (onClose != null)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: strings.headerClose,
                        onPressed: onClose,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StatPill(
                      label: strings.statsTurns(stats.turnCount),
                      colors: colors,
                    ),
                    if (stats.totalDuration > Duration.zero)
                      _StatPill(
                        label: strings.statsDuration(
                          _formatDuration(stats.totalDuration),
                        ),
                        colors: colors,
                      ),
                    _StatPill(
                      label: strings.statsTokensIn('${stats.inputTokens}'),
                      colors: colors,
                    ),
                    _StatPill(
                      label: strings.statsTokensOut('${stats.outputTokens}'),
                      colors: colors,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _TrajectorySearchField(controller: controller),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final filter in TrajectoryLedgerFilter.values)
                      FilterChip(
                        label: Text(_filterLabel(filter, strings)),
                        selected: controller.filters.contains(filter),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => controller.toggleFilter(filter),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _filterLabel(TrajectoryLedgerFilter filter, TrajectoryStrings strings) =>
      switch (filter) {
        TrajectoryLedgerFilter.messages => strings.filterMessages,
        TrajectoryLedgerFilter.tools => strings.filterTools,
        TrajectoryLedgerFilter.errors => strings.filterErrors,
        TrajectoryLedgerFilter.system => strings.filterSystem,
      };
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.label, required this.colors});

  final String label;
  final FahColors colors;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: colors.panelAlt,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(label, style: TextStyle(fontSize: 12, color: colors.dim)),
  );
}

class _TrajectorySearchField extends StatelessWidget {
  const _TrajectorySearchField({required this.controller});

  final TrajectoryController controller;

  @override
  Widget build(BuildContext context) {
    final strings = TrajectoryStrings.of(context);
    final enabled = controller.snapshot.records.isNotEmpty;
    final order = controller.searchMatchOrder;
    final index = controller.currentMatchIndex;
    return TextField(
      enabled: enabled,
      onChanged: (value) => controller.searchQuery = value,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        hintText: strings.toolbarSearchPlaceholder,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (order.isNotEmpty) ...[
              Semantics(
                label: strings.searchMatchPosition((index ?? 0) + 1, order.length),
                child: Text(
                  strings.searchMatchPosition((index ?? 0) + 1, order.length),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up),
                tooltip: strings.searchPreviousMatch,
                onPressed: controller.previousSearchMatch,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: strings.searchNextMatch,
                onPressed: controller.nextSearchMatch,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The persistent details pane (wide master-detail): the real tab content
/// for the selected record via [trajectoryDetailTabs], or a placeholder
/// while nothing is selected.
class TrajectoryDetailsPane extends StatelessWidget {
  /// Creates the pane bound to [controller].
  const TrajectoryDetailsPane({super.key, required this.controller});

  /// The controller whose selected record this pane renders.
  final TrajectoryController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final id = controller.selectedRecordId;
        TrajectoryRecord? record;
        for (final candidate in controller.records) {
          if (candidate.recordId == id) {
            record = candidate;
            break;
          }
        }
        final strings = TrajectoryStrings.of(context);
        if (record == null) {
          return Center(
            child: Text(
              strings.detailsPanePlaceholder,
              style: TextStyle(
                fontSize: 13,
                color: FahColors.of(context).dim,
              ),
            ),
          );
        }
        final tabs = trajectoryDetailTabs(record, controller.snapshot, strings);
        return DefaultTabController(
          key: ValueKey(record.recordId),
          length: tabs.length,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabs: [for (final tab in tabs) Tab(text: tab.label)],
              ),
              Expanded(
                child: TabBarView(
                  children: [for (final tab in tabs) tab.build(context)],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _formatStamp(DateTime time) {
  final two = (int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

String _formatDuration(Duration duration) {
  if (duration < const Duration(seconds: 1)) {
    return '${duration.inMilliseconds} ms';
  }
  if (duration < const Duration(minutes: 1)) {
    return '${(duration.inMicroseconds / 1e6).toStringAsFixed(1)} s';
  }
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes m ${seconds}s';
}
