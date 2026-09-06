// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_cell.dart';
import 'trajectory_strings.dart';

/// The context-injection ledger row: markdown-stripped single-line
/// preview plus the `N chars` meta line.
class TrajectoryCellContext extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellContext({super.key, required this.record});

  /// The projected context record.
  final TrajectoryContextRecord record;

  @override
  Widget build(BuildContext context) {
    return TrajectoryCellScaffold(
      record: record,
      title: TrajectoryRowText(
        text: record.previewMarkdown ?? trajectoryPreviewText(record.text),
      ),
      meta: [
        if (record.text.isNotEmpty)
          TrajectoryStrings.of(context).unitChars(record.text.length),
      ],
    );
  }
}
