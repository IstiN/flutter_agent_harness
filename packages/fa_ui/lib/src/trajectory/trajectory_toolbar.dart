// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'trajectory_controller.dart';
import 'trajectory_strings.dart';

/// The trajectory ledger's control row: the duration projection toggle and
/// the turn and call fold buttons.
///
/// Every control disables while the snapshot is empty. The search field
/// lives in the full-screen header (see [TrajectoryHeader]); this row is
/// the standalone-feed control strip.
class TrajectoryToolbar extends StatelessWidget {
  /// Creates a toolbar bound to [controller].
  const TrajectoryToolbar({super.key, required this.controller});

  /// The controller whose fold/projection/search state this row drives.
  final TrajectoryController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final strings = TrajectoryStrings.of(context);
        final enabled = controller.snapshot.records.isNotEmpty;
        final turnsCollapsed = controller.collapsedTurns.isNotEmpty;
        final callsCollapsed = controller.collapsedAssistants.isNotEmpty;
        return Semantics(
          container: true,
          label: strings.toolbarAria,
          child: Row(
            children: [
              // aria-pressed analog: IconButton(selected:) exposes toggle
              // semantics; the tooltip names the action a tap performs.
              IconButton(
                isSelected: controller.actualDuration,
                icon: const Icon(Icons.schedule),
                tooltip: controller.actualDuration
                    ? strings.toolbarUseEqualWidth
                    : strings.toolbarUseActualDuration,
                onPressed: enabled
                    ? () =>
                          controller.actualDuration = !controller.actualDuration
                    : null,
              ),
              IconButton(
                icon: Icon(
                  turnsCollapsed ? Icons.unfold_more : Icons.unfold_less,
                ),
                tooltip: turnsCollapsed
                    ? strings.toolbarExpandTurns
                    : strings.toolbarCollapseTurns,
                onPressed: enabled
                    ? (turnsCollapsed
                          ? controller.expandAllTurns
                          : controller.collapseAllTurns)
                    : null,
              ),
              IconButton(
                icon: Icon(callsCollapsed ? Icons.expand : Icons.compress),
                tooltip: callsCollapsed
                    ? strings.toolbarExpandCalls
                    : strings.toolbarCollapseCalls,
                onPressed: enabled
                    ? (callsCollapsed
                          ? controller.expandAllAssistants
                          : controller.collapseAllAssistants)
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }
}
