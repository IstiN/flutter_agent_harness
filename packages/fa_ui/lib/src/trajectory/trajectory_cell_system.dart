// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_cell.dart';

/// The session-state change ledger row: short change description plus
/// the change type as the meta line.
class TrajectoryCellSystem extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellSystem({super.key, required this.record});

  /// The projected system record.
  final TrajectorySystemRecord record;

  @override
  Widget build(BuildContext context) {
    return TrajectoryCellScaffold(
      record: record,
      title: TrajectoryRowText(text: record.text),
      meta: [record.change.name],
      error: record.errorCode != null || record.errorMessage != null,
    );
  }
}
