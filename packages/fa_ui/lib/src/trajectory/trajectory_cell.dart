// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// kind renders as a two-line row: kind pill + summary title with an
/// inline status badge, then the labeled meta line below. The table
/// wraps this with the chevron, copy affordance, and expanded body.
Widget buildTrajectoryCell(BuildContext context, TrajectoryRecord record) =>
    switch (record) {
      TrajectoryAssistantRecord() => TrajectoryCellAssistant(record: record),
      TrajectoryToolRecord() => TrajectoryCellTool(record: record),
      TrajectoryUserRecord() => TrajectoryCellUser(record: record),
      TrajectoryContextRecord() => TrajectoryCellContext(record: record),
      TrajectoryCompactedRecord() => TrajectoryCellCompacted(record: record),
      TrajectorySystemRecord() => TrajectoryCellSystem(record: record),
    };

/// Whether [record] has full content beyond its summary line, i.e. the
/// row's chevron and expanded body are worth offering.
bool trajectoryRowExpandable(TrajectoryRecord record) => switch (record) {
  TrajectoryUserRecord(:final text) => text.isNotEmpty,
  TrajectoryAssistantRecord(
    :final thinkingDetail,
    :final outputDetail,
    :final displayText,
  ) =>
    (thinkingDetail?.isNotEmpty ?? false) ||
        (outputDetail?.isNotEmpty ?? false) ||
        displayText.isNotEmpty,
  TrajectoryToolRecord(:final argsRaw, :final result) =>
    argsRaw.isNotEmpty || result.isNotEmpty,
  TrajectoryContextRecord(:final text) => text.isNotEmpty,
  TrajectoryCompactedRecord(:final summary, :final text) =>
    summary.isNotEmpty || text.isNotEmpty,
  TrajectorySystemRecord(:final detail, :final text) =>
    detail?.isNotEmpty ?? text.isNotEmpty,
};

/// The full content of [record] for the expanded row body: the complete
/// user text, the assistant thinking + output, the tool's pretty-printed
/// arguments and full result, or the section text.
String trajectoryExpandedText(TrajectoryRecord record) => switch (record) {
  TrajectoryUserRecord(:final text) => text,
  TrajectoryAssistantRecord() => _assistantExpandedText(record),
  TrajectoryToolRecord() => _toolExpandedText(record),
  TrajectoryContextRecord(:final text) => text,
  TrajectoryCompactedRecord(:final summary, :final text) =>
    summary.isEmpty ? text : summary,
  TrajectorySystemRecord(:final detail, :final text) =>
    detail == null || detail.isEmpty ? text : detail,
};

String _assistantExpandedText(TrajectoryAssistantRecord record) {
  final sections = [
    for (final detail in [record.thinkingDetail, record.outputDetail])
      if (detail != null && detail.isNotEmpty) detail,
  ];
  return sections.isEmpty ? record.displayText : sections.join('\n\n');
}

String _toolExpandedText(TrajectoryToolRecord record) => [
  if (record.argsRaw.isNotEmpty)
    '${record.name}(${_prettyJson(record.argsRaw)})',
  if (record.result.isNotEmpty) record.result,
].join('\n\n');

/// Pretty-prints [raw] JSON; returns it verbatim when it does not parse.
String _prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } on FormatException {
    return raw;
  }
}

/// The full record as a JSON-encodable map, for the per-row copy
/// affordance. The core model classes carry no per-record `toJson`, so
/// this composes the fields per kind.
Map<String, Object?> trajectoryRecordJson(TrajectoryRecord record) {
  String? at(DateTime? time) => time?.toIso8601String();
  return {
    'kind': record.kind.name,
    'index': record.index,
    'recordId': record.recordId,
    ...switch (record) {
      TrajectoryAssistantRecord(
        :final messageId,
        :final turn,
        :final step,
        :final provider,
        :final model,
        :final usage,
        :final thinkingDetail,
        :final outputDetail,
        :final timeSeconds,
        :final isError,
        :final errorCode,
        :final errorMessage,
        :final requestOnly,
        :final displayText,
        :final requestDetail,
      ) =>
        {
          'messageId': messageId,
          'turn': turn,
          'step': step,
          'provider': provider,
          'model': model,
          'usage': usage?.toJson(),
          'thinkingDetail': thinkingDetail,
          'outputDetail': outputDetail,
          'timeSeconds': timeSeconds?.inMilliseconds,
          'isError': isError,
          'errorCode': errorCode,
          'errorMessage': errorMessage,
          'requestOnly': requestOnly,
          'displayText': displayText,
          'requestDetail': requestDetail?.toJson(),
        },
      TrajectoryToolRecord(
        :final callId,
        :final parentCallId,
        :final name,
        :final argsRaw,
        :final result,
        :final isError,
        :final timeSeconds,
        :final startedAt,
      ) =>
        {
          'callId': callId,
          'parentCallId': parentCallId,
          'name': name,
          'argsRaw': argsRaw,
          'result': result,
          'isError': isError,
          'timeSeconds': timeSeconds?.inMilliseconds,
          'startedAt': at(startedAt),
        },
      TrajectoryUserRecord(
        :final text,
        :final previewMarkdown,
        :final opensTurn,
        :final inputDetail,
        :final startedAt,
      ) =>
        {
          'text': text,
          'previewMarkdown': previewMarkdown,
          'opensTurn': opensTurn,
          'inputDetail': inputDetail,
          'startedAt': at(startedAt),
        },
      TrajectoryContextRecord(
        :final text,
        :final previewMarkdown,
        :final startedAt,
      ) =>
        {
          'text': text,
          'previewMarkdown': previewMarkdown,
          'startedAt': at(startedAt),
        },
      TrajectoryCompactedRecord(
        :final text,
        :final summary,
        :final firstKeptEntryId,
        :final timeSeconds,
        :final interrupted,
      ) =>
        {
          'text': text,
          'summary': summary,
          'firstKeptEntryId': firstKeptEntryId,
          'timeSeconds': timeSeconds?.inMilliseconds,
          'interrupted': interrupted,
        },
      TrajectorySystemRecord(
        :final text,
        :final change,
        :final detail,
        :final time,
        :final errorCode,
        :final errorMessage,
      ) =>
        {
          'text': text,
          'change': change.name,
          'detail': detail,
          'time': at(time),
          'errorCode': errorCode,
          'errorMessage': errorMessage,
        },
    },
  };
}

/// Copies [record]'s full JSON to the clipboard (per-row copy affordance).
void copyTrajectoryRecord(TrajectoryRecord record) {
  Clipboard.setData(
    ClipboardData(
      text: const JsonEncoder.withIndent(
        '  ',
      ).convert(trajectoryRecordJson(record)),
    ),
  );
}

/// Comma-grouped integer label, locale-free (same convention as the core
/// formatters): `1024` → `1,024`.
String trajectoryThousands(int value) =>
    '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Compact row-meta duration label: `150ms`, `2.0s`, `12s`.
String trajectoryMetaDuration(Duration duration) {
  final ms = duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  final seconds = ms / 1000;
  return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)}s';
}

/// Byte-size label for oversized expanded bodies: `512 B`, `63.0 KiB`,
/// `1.2 MiB`.
String trajectoryByteLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

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

/// The inline row status label beside the title: [TrajectoryStrings.statusFailed]
/// on error, [TrajectoryStrings.statusPending] while running, nothing
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
      // The trailing newline terminates the row's selectable paragraph so
      // copying a selection across rows keeps line breaks (E10);
      // `maxLines: 1` clips it from the layout.
      '$effective\n',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: resolved,
    );
    if (text.isEmpty) return body;
    return Tooltip(message: text, child: body);
  }
}

/// The shared two-line ledger cell skeleton: the kind pill + summary
/// title with the inline status badge on the first line, the labeled
/// meta segments (`step 2 · 1.5s · 1,024 tok`) on the second.
class TrajectoryCellScaffold extends StatelessWidget {
  /// Creates the cell scaffold.
  const TrajectoryCellScaffold({
    super.key,
    required this.record,
    required this.title,
    this.meta = const [],
    this.error = false,
    this.running = false,
  });

  /// The projected record (drives the kind pill).
  final TrajectoryRecord record;

  /// The single-line, ellipsized summary title.
  final Widget title;

  /// Labeled meta segments joined with ` · ` on the second line.
  final List<String> meta;

  /// Whether the row failed (inline badge + error styling).
  final bool error;

  /// Whether the row is still running (inline pending badge).
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            TrajectoryKindPill.of(context, record),
            const SizedBox(width: 8),
            Flexible(child: title),
            if (error || running) ...[
              const SizedBox(width: 6),
              trajectoryCellStatus(context, error: error, running: running),
            ],
          ],
        ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${meta.join(' · ')}\n',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: FahColors.of(context).dim),
            ),
          ),
      ],
    );
  }
}

/// Character bound above which an expanded body renders as a bounded
/// preview plus a `show content (size)` expander instead of the full
/// text (huge results are never built eagerly).
const int _bigBodyChars = 64 * 1024;

/// Preview length shown before the expander is used.
const int _bodyPreviewChars = 16 * 1024;

/// The bounded mono region under an expanded row: the full record text,
/// soft-wrapped so long unbroken strings and RTL text never overflow,
/// vertically scrollable, capped at ~40% of the viewport height. Bodies
/// beyond [_bigBodyChars] collapse to a preview with a byte-size
/// `show content` expander until used.
class TrajectoryExpandedBody extends StatefulWidget {
  /// Creates the expanded body.
  const TrajectoryExpandedBody({super.key, required this.record});

  /// The projected record whose full content renders.
  final TrajectoryRecord record;

  @override
  State<TrajectoryExpandedBody> createState() => _TrajectoryExpandedBodyState();
}

class _TrajectoryExpandedBodyState extends State<TrajectoryExpandedBody> {
  var _showAll = false;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final strings = TrajectoryStrings.of(context);
    final full = trajectoryExpandedText(widget.record);
    if (full.isEmpty) return const SizedBox.shrink();
    final truncated = !_showAll && full.length > _bigBodyChars;
    final text = truncated ? full.substring(0, _bodyPreviewChars) : full;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.4,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: colors.mono(fontSize: 12)),
            if (truncated)
              TextButton.icon(
                onPressed: () => setState(() => _showAll = true),
                icon: const Icon(Icons.unfold_more, size: 14),
                label: Text(
                  strings.detailsShowContent(
                    trajectoryByteLabel(utf8.encode(full).length),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
