// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_cell.dart';

/// The session-state change ledger row: short change description.
class TrajectoryCellSystem extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellSystem({super.key, required this.record});

  /// The projected system record.
  final TrajectorySystemRecord record;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TrajectoryKindPill.of(context, record),
        const SizedBox(width: 8),
        Expanded(child: TrajectoryRowText(text: record.text)),
        trajectoryCellStatus(
          context,
          error: record.errorMessage != null,
          running: false,
        ),
      ],
    );
  }
}
