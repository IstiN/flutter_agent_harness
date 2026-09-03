// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_cell.dart';

/// The tool (or nested subtool) ledger row: mono tool name, dimmed
/// arguments after the first ` · ` separator, and an inline result
/// preview that turns red on error.
class TrajectoryCellTool extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellTool({super.key, required this.record});

  /// The projected tool record.
  final TrajectoryToolRecord record;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final mono = const TextStyle(fontSize: 12, fontFamily: 'monospace');
    final result = record.result.isEmpty
        ? ''
        : trajectoryPreviewText(record.resultPreviewMarkdown ?? record.result);
    final error = record.isError;
    return Row(
      children: [
        TrajectoryKindPill.of(context, record),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: record.result.isEmpty ? record.name : _tooltipText(result),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: record.name, style: mono),
                  if (record.argsRaw.isNotEmpty)
                    TextSpan(
                      text: ' · ${record.argsRaw}',
                      style: mono.copyWith(color: colors.dim),
                    ),
                  if (result.isNotEmpty)
                    TextSpan(
                      text: ' → $result',
                      style: TextStyle(
                        fontSize: 13,
                        color: error ? colors.error : colors.dim,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        trajectoryCellStatus(
          context,
          error: error,
          running: record.timeSeconds == null && !error,
        ),
      ],
    );
  }

  String _tooltipText(String resultPreview) =>
      '${record.name} · ${record.argsRaw} → $resultPreview';
}
