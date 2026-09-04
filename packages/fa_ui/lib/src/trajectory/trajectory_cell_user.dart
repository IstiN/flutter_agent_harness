// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_cell.dart';

/// The user message ledger row: markdown-stripped single-line preview.
class TrajectoryCellUser extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellUser({super.key, required this.record});

  /// The projected user record.
  final TrajectoryUserRecord record;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TrajectoryKindPill.of(context, record),
        const SizedBox(width: 8),
        Expanded(
          child: TrajectoryRowText(
            text: record.previewMarkdown ?? trajectoryPreviewText(record.text),
          ),
        ),
      ],
    );
  }
}
