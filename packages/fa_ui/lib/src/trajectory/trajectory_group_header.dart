// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_strings.dart';

/// The "Message" / "Step N" / "Compaction N" group header with the
/// group's wall-span description (e.g. `1.5 s bash×6`).
class TrajectoryGroupHeader extends StatelessWidget {
  /// Creates the header.
  const TrajectoryGroupHeader({super.key, required this.group});

  /// The group the following cells belong to.
  final TrajectoryGroupModel group;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    final label = switch (group.kind) {
      TrajectoryGroupKind.message => strings.groupMessage,
      TrajectoryGroupKind.step => strings.groupStep(group.stepNumber ?? 0),
      TrajectoryGroupKind.compaction => strings.groupCompaction(
        group.stepNumber ?? 0,
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 4, 12, 1),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.dim,
            ),
          ),
          if (group.description != null) ...[
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                group.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.dim),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
