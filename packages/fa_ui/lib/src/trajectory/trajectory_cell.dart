// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_cell_assistant.dart';
import 'trajectory_cell_compacted.dart';
import 'trajectory_cell_context.dart';
import 'trajectory_cell_system.dart';
import 'trajectory_cell_tool.dart';
import 'trajectory_cell_user.dart';
import 'trajectory_strings.dart';

/// Builds the ledger row content for one projected record.
///
/// Exhaustive switch over the sealed [TrajectoryRecord] hierarchy; every
/// kind renders as one single-line row: kind pill, display text, and a
/// trailing status label while the row runs or failed.
Widget buildTrajectoryCell(BuildContext context, TrajectoryRecord record) =>
    switch (record) {
      TrajectoryAssistantRecord() => TrajectoryCellAssistant(record: record),
      TrajectoryToolRecord() => TrajectoryCellTool(record: record),
      TrajectoryUserRecord() => TrajectoryCellUser(record: record),
      TrajectoryContextRecord() => TrajectoryCellContext(record: record),
      TrajectoryCompactedRecord() => TrajectoryCellCompacted(record: record),
      TrajectorySystemRecord() => TrajectoryCellSystem(record: record),
    };

/// The colored kind tag pill opening every ledger row.
class TrajectoryKindPill extends StatelessWidget {
  /// Creates a pill.
  const TrajectoryKindPill({
    super.key,
    required this.label,
    required this.tint,
  });

  /// Resolves the pill for [record]: uppercase kind label plus the kind's
  /// palette tint (subtool uses a dimmer variant of the tool warn tint).
  factory TrajectoryKindPill.of(BuildContext context, TrajectoryRecord record) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    return switch (record.kind) {
      TrajectoryCellKind.system => TrajectoryKindPill(
        label: strings.kindSystem,
        tint: colors.dim,
      ),
      TrajectoryCellKind.user => TrajectoryKindPill(
        label: strings.kindUser,
        tint: colors.indigo,
      ),
      TrajectoryCellKind.context => TrajectoryKindPill(
        label: strings.kindContext,
        tint: colors.teal,
      ),
      TrajectoryCellKind.compacted => TrajectoryKindPill(
        label: strings.kindCompacted,
        tint: colors.dim,
      ),
      TrajectoryCellKind.message => TrajectoryKindPill(
        label: strings.kindAssistant,
        tint: colors.indigo,
      ),
      TrajectoryCellKind.tool => TrajectoryKindPill(
        label: strings.kindTool,
        tint: colors.pending,
      ),
      TrajectoryCellKind.subtool => TrajectoryKindPill(
        label: strings.kindSubtool,
        tint: colors.pending.withValues(alpha: 0.6),
      ),
    };
  }

  /// The short kind label.
  final String label;

  /// The kind's palette tint (pill background wash and label color).
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: tint,
        ),
      ),
    );
  }
}

/// The trailing row status label: [TrajectoryStrings.statusFailed] on
/// error, [TrajectoryStrings.statusPending] while running, blank space
/// when the row is complete.
Widget trajectoryCellStatus(
  BuildContext context, {
  required bool error,
  required bool running,
}) {
  if (!error && !running) return const SizedBox.shrink();
  final colors = FahColors.of(context);
  final strings = TrajectoryStrings.of(context);
  return Text(
    error ? strings.statusFailed : strings.statusPending,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: error ? colors.error : colors.pending,
    ),
  );
}

/// One single-line, ellipsized row text with the full text as a tooltip.
///
/// Rows show plain-text previews (the details rendering is a later
/// phase); empty text falls back to a dimmed em dash.
class TrajectoryRowText extends StatelessWidget {
  /// Creates the row text.
  const TrajectoryRowText({super.key, required this.text, this.style});

  /// The full display text.
  final String text;

  /// Base style for the visible line.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final effective = text.isEmpty ? '—' : text;
    final resolved = (style ?? const TextStyle(fontSize: 13)).copyWith(
      color: text.isEmpty ? colors.dim : null,
    );
    final body = Text(
      effective,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: resolved,
    );
    if (text.isEmpty) return body;
    return Tooltip(message: text, child: body);
  }
}
