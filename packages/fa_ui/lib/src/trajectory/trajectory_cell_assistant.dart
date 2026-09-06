// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../theme/app_theme.dart';
import 'trajectory_cell.dart';
import 'trajectory_strings.dart';

/// The assistant (`message`) ledger row: output or thinking preview with
/// an explicit `empty response` state (never a bare em dash), the inline
/// error message on failure, and the labeled `step N · duration · tokens`
/// meta line.
class TrajectoryCellAssistant extends StatelessWidget {
  /// Creates the cell.
  const TrajectoryCellAssistant({super.key, required this.record});

  /// The projected assistant record.
  final TrajectoryAssistantRecord record;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    final error = record.isError ?? false;
    final display = _displayText(record);
    final message = record.errorMessage;
    final title = switch (record) {
      _ when display.isNotEmpty => TrajectoryRowText(text: display),
      _ when error && message != null && message.isNotEmpty =>
        TrajectoryRowText(
          text: message,
          style: TextStyle(fontSize: 13, color: colors.error),
        ),
      _ when record.requestOnly => Text(
        '${strings.recordNoContent}\n',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: colors.dim,
        ),
      ),
      _ => Text(
        '${strings.detailsEmptyResponse}\n',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: colors.dim,
        ),
      ),
    };
    return TrajectoryCellScaffold(
      record: record,
      title: title,
      meta: [
        strings.metaStep(record.step),
        if (record.timeSeconds case final duration?)
          trajectoryMetaDuration(duration),
        if (_tokenCount(record) case final tokens when tokens > 0)
          strings.metaTokens(trajectoryThousands(tokens)),
        if (error &&
            message != null &&
            message.isNotEmpty &&
            message != display)
          message,
      ],
      error: error,
    );
  }
}

String _displayText(TrajectoryAssistantRecord record) {
  final source = record.outputDetail ?? record.thinkingDetail ?? '';
  if (source.isEmpty) return record.displayText;
  return trajectoryPreviewText(source);
}

/// Total tokens for the meta line: the provider-reported total, else the
/// recorded input/output sums; null when nothing was reported.
int _tokenCount(TrajectoryAssistantRecord record) {
  final total = record.usage?.totalTokens;
  if (total != null && total > 0) return total;
  final input = record.inputTokens ?? 0;
  final output = record.outputTokens ?? 0;
  return input + output;
}
