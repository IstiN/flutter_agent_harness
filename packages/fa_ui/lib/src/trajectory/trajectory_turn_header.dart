// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_strings.dart';

/// The "Turn N" (or "Between turns" for standalone compaction sections)
/// section header above each turn's groups.
class TrajectoryTurnHeader extends StatelessWidget {
  /// Creates the header.
  const TrajectoryTurnHeader({super.key, required this.turn});

  /// The section's turn model.
  final TrajectoryTurnModel turn;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    final label = turn.turn != null
        ? strings.turnLabel(turn.turn!)
        : strings.sectionBetweenTurns;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: colors.indigo,
        ),
      ),
    );
  }
}
