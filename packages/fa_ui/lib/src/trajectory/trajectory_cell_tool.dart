// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_cell.dart';

/// The tool (or nested subtool) ledger row: mono `name · args → result`
/// summary line (result red on error) and the `duration · name ✓` meta
/// line once the call settles.
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
    final settled = record.timeSeconds != null || record.result.isNotEmpty;
    return TrajectoryCellScaffold(
      record: record,
      title: Tooltip(
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
              const TextSpan(text: '\n'),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      meta: [
        if (record.timeSeconds case final duration?)
          trajectoryMetaDuration(duration),
        if (settled && !error) '${record.name} ✓',
      ],
      error: error,
      running: record.timeSeconds == null && !error && result.isEmpty,
    );
  }

  String _tooltipText(String resultPreview) =>
      '${record.name} · ${record.argsRaw} → $resultPreview';
}
