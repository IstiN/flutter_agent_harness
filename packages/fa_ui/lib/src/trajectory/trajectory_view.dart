// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../chat/fa_adaptive_header.dart'
    show FaFloatingHeaderBar, FaHeaderAction, FaHeaderCircularAction;
import '../chat/fa_chat_screen.dart' show kWideLayoutBreakpoint;
import '../theme/app_theme.dart';
import '../theme/fa2_tokens.dart' show FaDesignTokens;
import '../widgets/fa2_controls.dart' show FaSurface;
import '../widgets/fa_icon_action_band.dart' show FaIconActionBand;
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

/// What the trajectory's projected window covers (issue #135 AC11):
/// the ledger marks its WINDOWED scope — a partial projection is
/// never presented as the complete trajectory.
final class TrajectoryProjectionScope {
  /// Creates a scope from the session's window counters; null counts
  /// are unknown (edges not walked yet).
  const TrajectoryProjectionScope({this.above, this.below, this.total});

  /// Records above the resident window (earlier history).
  final int? above;

  /// Records below the resident window (later history slid out).
  final int? below;

  /// Total records in the session branch; null while unmeasured.
  final int? total;

  /// Records inside the window right now.
  int get visible => total == null
      ? 0
      : (total! - (above ?? 0) - (below ?? 0)).clamp(0, total!);

  /// Whether the projection is partial (either side outside the window).
  bool get isPartial => (above ?? 0) > 0 || (below ?? 0) > 0;
}

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
    this.leadingControls,
    this.onRecordActivate,
  });

  /// Jump-in-chat for a ledger record (issue #135 AC6): when non-null,
  /// the details sheet gains a "Jump in chat" action that pages the
  /// transcript to this record (host-supplied; null hides the action).
  final ValueChanged<TrajectoryRecord>? onRecordActivate;

  /// The controller holding the snapshot and interaction state.
  final TrajectoryController controller;

  /// The ledger table seam; null renders nothing.
  final TrajectoryTableBuilder? tableBuilder;

  /// The timeline strip seam; null renders nothing.
  final TrajectoryTimelineBuilder? timelineBuilder;

  /// Extra control deck rendered at the top of the feed, above the fold
  /// toolbar. The narrow trajectory shell re-homes the stats/search/filter
  /// deck here (the canonical bar cannot hold it); null on wide canvases.
  final Widget? leadingControls;

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
                  onJumpToChat: widget.onRecordActivate == null
                      ? null
                      : () => widget.onRecordActivate!(record),
                  resolveHiddenRecords: controller.resolveHiddenRecords,
                ),
              );
    return Semantics(
      container: true,
      label: strings.viewTrajectory,
      child: Column(
        children: [
          ?widget.leadingControls,
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
  const TrajectoryBody({
    super.key,
    required this.controller,
    this.onClose,
    this.scope,
    this.onRecordActivate,
  });

  /// The controller holding the snapshot and interaction state.
  final TrajectoryController controller;

  /// Pops the surface (route close / switch back to chat); null hides it.
  final VoidCallback? onClose;

  /// What the projected window covers (issue #135 AC11); null or
  /// complete renders no scope notice.
  final TrajectoryProjectionScope? scope;

  /// Jump-in-chat for a ledger record (issue #135 AC6); null hides it.
  final ValueChanged<TrajectoryRecord>? onRecordActivate;

  /// The ledger honesty notice (AC11): the trajectory projects the
  /// RESIDENT window — a partial window is never presented as
  /// complete.
  Widget _scopeNotice(BuildContext context) {
    final scope = this.scope;
    if (scope == null || !scope.isPartial) return const SizedBox.shrink();
    final strings = TrajectoryStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.filter_alt_outlined,
            size: 14,
            color: Theme.of(context).hintColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              scope.total == null
                  ? strings.historyScopeWindowed(
                      scope.above ?? 0,
                      scope.below ?? 0,
                    )
                  : '${strings.historyScopeWindowed(scope.above ?? 0, scope.below ?? 0)}'
                        ' · ${strings.historyScopeShownOf(scope.visible, scope.total!)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
    // Wide master-detail: row taps select (the pane follows) instead of
    // opening the modal sheet.
    final feed = TrajectoryView(
      controller: controller,
      onRecordActivate: onRecordActivate,
      tableBuilder: isWide
          ? (context, controller) => TrajectoryTable(controller: controller)
          : null,
      // Narrow canvases: the canonical header bar cannot hold the stats,
      // search, and filter deck, so it rides with the ledger's own control
      // rows (above the fold toolbar) instead of inflating the header.
      leadingControls: isWide
          ? null
          : _TrajectoryLedgerControls(controller: controller),
    );
    return Column(
      children: [
        TrajectoryHeader(controller: controller, onClose: onClose),
        _scopeNotice(context),
        const Divider(height: 1),
        Expanded(
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 55, child: feed),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 45,
                      child: TrajectoryDetailsPane(
                        controller: controller,
                        onRecordActivate: onRecordActivate,
                      ),
                    ),
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
    // Narrow canvases collapse the header to the canonical floating bar
    // (FaFloatingHeaderBar — the chat header's strip) so the trajectory
    // pane reads as the same chrome system as chats and Apps on a phone;
    // the stats/search/filter deck moves into the ledger's control rows
    // (see [_TrajectoryLedgerControls]). Wide canvases keep the rich
    // multi-row header unchanged.
    final narrow = MediaQuery.sizeOf(context).width < kWideLayoutBreakpoint;
    return Semantics(
      container: true,
      label: strings.headerAria,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (narrow) {
            return _buildNarrowBar(context, strings, controller);
          }
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
                          Text(
                            strings.viewTrajectory,
                            style: theme.titleMedium,
                          ),
                          if (stats.startedAt case final startedAt?)
                            Text(
                              strings.headerSession(_formatStamp(startedAt)),
                              style: theme.bodySmall?.copyWith(
                                color: colors.dim,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Export lives in the header overflow: compact on any
                    // canvas, hidden until the snapshot has records.
                    if (controller.snapshot.records.isNotEmpty)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.ios_share),
                        tooltip: strings.headerExport,
                        onSelected: (format) => Clipboard.setData(
                          ClipboardData(
                            text: switch (format) {
                              'json' => exportTrajectoryJson(
                                controller.snapshot,
                              ),
                              _ => exportTrajectoryMarkdown(
                                controller.snapshot,
                              ),
                            },
                          ),
                        ),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'json',
                            child: Text(strings.exportCopyJson),
                          ),
                          PopupMenuItem(
                            value: 'markdown',
                            child: Text(strings.exportCopyMarkdown),
                          ),
                        ],
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
                    // Issue #385 AC7 honesty: unknown record kinds render
                    // as context rows, and the header says how many —
                    // silence would hide ledger loss.
                    if (controller.snapshot.unknownRecordCount > 0)
                      _StatPill(
                        label: strings.statsUnknown(
                          controller.snapshot.unknownRecordCount,
                        ),
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
                        label: Text(_trajectoryFilterLabel(filter, strings)),
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

  /// The narrow canvas bar: the chat floating glass header's canonical
  /// strip ([FaFloatingHeaderBar.barExtent] below the pane's top edge).
  /// Same paddings, 36pt leading circle, 40pt centered title pill (with
  /// the session stamp as the eyebrow line), and a 40pt glass action band
  /// on the circle's centerline — export (when records exist) and close.
  /// The rich header's stats pills, search field, and filter chips live
  /// in the ledger's control deck instead ([_TrajectoryLedgerControls]).
  Widget _buildNarrowBar(
    BuildContext context,
    TrajectoryStrings strings,
    TrajectoryController controller,
  ) {
    final tokens = FaDesignTokens.of(context);
    final stats = controller.stats;
    final hasRecords = controller.snapshot.records.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(0.0, constraints.maxWidth);
        final titleSideWidth = math.min(360.0, contentWidth * .38);
        final titleWidth = math.min(
          320.0,
          math.max(200.0, contentWidth - 2 * (titleSideWidth + 12)),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FaFloatingHeaderBar.padHorizontal,
            vertical: FaFloatingHeaderBar.padVertical,
          ),
          child: SizedBox(
            height: FaFloatingHeaderBar.contentHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          top: FaFloatingHeaderBar.iconTop,
                        ),
                        child: FaHeaderCircularAction(
                          key: const ValueKey('trajectoryBarIcon'),
                          dimension: FaFloatingHeaderBar.actionDimension,
                          glass: true,
                          child: Icon(
                            Icons.timeline,
                            size: 18,
                            color: tokens.ink1,
                          ),
                        ),
                      ),
                      const SizedBox(height: FaFloatingHeaderBar.iconTitleGap),
                      FaSurface(
                        key: const ValueKey('trajectoryBarTitlePill'),
                        glass: true,
                        useBackdropGroup: true,
                        color: tokens.surface1,
                        borderRadius: BorderRadius.circular(14),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          width: titleWidth,
                          height: FaFloatingHeaderBar.pillHeight,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (stats.startedAt case final startedAt?)
                                Text(
                                  strings.headerSession(
                                    _formatStamp(startedAt),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: tokens.ink2,
                                    fontSize: 10,
                                    height: 1.2,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              Text(
                                strings.viewTrajectory,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: tokens.ink1,
                                  fontSize: 13,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: FaFloatingHeaderBar.actionBandTop,
                  right: 0,
                  height: FaFloatingHeaderBar.pillHeight,
                  child: FaIconActionBand<String>(
                    key: const ValueKey('trajectoryBarActions'),
                    glass: true,
                    actions: [
                      ?_narrowExportAction(context, strings, hasRecords),
                      if (onClose != null)
                        FaHeaderAction(
                          key: const ValueKey('trajectoryBarClose'),
                          icon: Icons.close,
                          label: strings.headerClose,
                          onPressed: onClose,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Export keeps its format menu: the glass band button opens the same
  /// json/markdown popup the wide header's `PopupMenuButton` shows.
  FaHeaderAction? _narrowExportAction(
    BuildContext context,
    TrajectoryStrings strings,
    bool hasRecords,
  ) {
    if (!hasRecords) return null;
    return FaHeaderAction(
      key: _narrowExportButtonKey,
      icon: Icons.ios_share,
      label: strings.headerExport,
      onPressed: () => unawaited(_showNarrowExportMenu(context, strings)),
    );
  }

  Future<void> _showNarrowExportMenu(
    BuildContext context,
    TrajectoryStrings strings,
  ) async {
    final box =
        _narrowExportButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    if (box == null || !box.attached) return;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final format = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromCenter(center: center, width: 1, height: 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: 'json', child: Text(strings.exportCopyJson)),
        PopupMenuItem(
          value: 'markdown',
          child: Text(strings.exportCopyMarkdown),
        ),
      ],
    );
    if (format == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: switch (format) {
          'json' => exportTrajectoryJson(controller.snapshot),
          _ => exportTrajectoryMarkdown(controller.snapshot),
        },
      ),
    );
  }
}

final GlobalKey _narrowExportButtonKey = GlobalKey();

/// The ledger's narrow control deck: the stats pills, search field, and
/// filter chips that the canonical bar cannot hold. They render at the
/// top of the feed's control rows ([TrajectoryView.leadingControls]) —
/// the pane's own control area, exactly where the fold toolbar already
/// lives — instead of inflating the header past the chat bar height.
class _TrajectoryLedgerControls extends StatelessWidget {
  const _TrajectoryLedgerControls({required this.controller});

  final TrajectoryController controller;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stats = controller.stats;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                  if (controller.snapshot.unknownRecordCount > 0)
                    _StatPill(
                      label: strings.statsUnknown(
                        controller.snapshot.unknownRecordCount,
                      ),
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
                      label: Text(_trajectoryFilterLabel(filter, strings)),
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
    );
  }
}

/// The ledger filter chip's label (shared by the wide header and the
/// narrow control deck).
String _trajectoryFilterLabel(
  TrajectoryLedgerFilter filter,
  TrajectoryStrings strings,
) => switch (filter) {
  TrajectoryLedgerFilter.messages => strings.filterMessages,
  TrajectoryLedgerFilter.tools => strings.filterTools,
  TrajectoryLedgerFilter.errors => strings.filterErrors,
  TrajectoryLedgerFilter.system => strings.filterSystem,
};

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
                label: strings.searchMatchPosition(
                  (index ?? 0) + 1,
                  order.length,
                ),
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
  const TrajectoryDetailsPane({
    super.key,
    required this.controller,
    this.onRecordActivate,
  });

  /// The controller whose selected record this pane renders.
  final TrajectoryController controller;

  /// Jump-in-chat for the selected record (issue #135 AC6); null hides
  /// the action.
  final ValueChanged<TrajectoryRecord>? onRecordActivate;
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
              style: TextStyle(fontSize: 13, color: FahColors.of(context).dim),
            ),
          );
        }
        final tabs = trajectoryDetailTabs(
          record,
          controller.snapshot,
          strings,
          resolveHiddenRecords: controller.resolveHiddenRecords,
        );
        final selected = record;
        return DefaultTabController(
          key: ValueKey(record.recordId),
          length: tabs.length,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabs: [for (final tab in tabs) Tab(text: tab.label)],
              ),
              if (onRecordActivate != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.gps_fixed, size: 16),
                    label: Text(strings.detailsJumpToChat),
                    onPressed: () => onRecordActivate!(selected),
                  ),
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
  String two(int value) => value.toString().padLeft(2, '0');
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
