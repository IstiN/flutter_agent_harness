// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_cell.dart';

/// The compaction (or branch-summary) ledger row: bounded summary
/// preview, pending while the compaction is still running.
class TrajectoryCellCompacted extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellCompacted({super.key, required this.record});

  /// The projected compacted record.
  final TrajectoryCompactedRecord record;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TrajectoryKindPill.of(context, record),
        const SizedBox(width: 8),
        Expanded(child: TrajectoryRowText(text: record.text)),
        trajectoryCellStatus(
          context,
          error: record.interrupted,
          running: record.timeSeconds == null && !record.interrupted,
        ),
      ],
    );
  }
}
