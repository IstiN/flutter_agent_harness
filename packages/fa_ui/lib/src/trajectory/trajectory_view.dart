// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'trajectory_controller.dart';
import 'trajectory_details.dart';
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
