// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_cell.dart';

/// The assistant (`message`) ledger row: output or thinking preview, with
/// the core-provided fallback label when the step has no visible content.
class TrajectoryCellAssistant extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellAssistant({super.key, required this.record});

  /// The projected assistant record.
  final TrajectoryAssistantRecord record;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TrajectoryKindPill.of(context, record),
        const SizedBox(width: 8),
        Expanded(child: TrajectoryRowText(text: _displayText(record))),
        trajectoryCellStatus(
          context,
          error: record.isError ?? false,
          running: false,
        ),
      ],
    );
  }
}

String _displayText(TrajectoryAssistantRecord record) {
  final source = record.outputDetail ?? record.thinkingDetail ?? '';
  if (source.isEmpty) return record.displayText;
  return trajectoryPreviewText(source);
}
