// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../chat/markdown_style.dart';
import 'trajectory_strings.dart';

/// One tab of the details sheet: stable [id] (drives tab-history restore),
/// localized [label], and the page builder.
class TrajectoryDetailsTab {
  /// Creates a tab description.
  const TrajectoryDetailsTab({
    required this.id,
    required this.label,
    required this.build,
  });

  /// Stable tab identity persisted across reopenings of a record.
  final String id;

  /// Localized tab label.
  final String label;

  /// Builds the scrollable page content.
  final WidgetBuilder build;
}

/// Tab set for [record] per selection kind: system → [System Prompt, Tools],
/// compacted → [Summary, Raw Output], user/context/message → [Summary,
/// Preview, Raw], tool/subtool → [Summary, Payload?, Result?, Schema,
/// Timing].
///
/// The Diff tab keys off a prompt pair (before vs after). The landed core
/// record that carries a pair is [TrajectoryAssistantRecord]
/// (`previousPromptDetail` + `promptDetail`); [TrajectorySystemRecord]
/// carries only its `detail` snapshot, so a system prompt renders in place
/// until the core grows a previous-prompt field.
List<TrajectoryDetailsTab> trajectoryDetailTabs(
  TrajectoryRecord record,
  TrajectorySnapshot? snapshot,
  TrajectoryStrings strings,
) {
  switch (record) {
    case TrajectorySystemRecord():
      return [
        TrajectoryDetailsTab(
          id: 'system-prompt',
          label: strings.tabSystemPrompt,
          build: (context) => record.detail == null
              ? _mutedPage(strings.recordSystemPromptMissing)
              : _markdownPage(context, record.detail!),
        ),
        TrajectoryDetailsTab(
          id: 'tools',
          label: strings.tabTools,
          build: (context) => _mutedPage(strings.recordToolsMissing),
        ),
      ];
    case TrajectoryCompactedRecord():
      return [
        _summaryTab(record, snapshot, strings),
        TrajectoryDetailsTab(
          id: 'raw',
          label: strings.tabRawOutput,
          build: (context) =>
              _monoPage(record.summary, muted: record.summary.isEmpty),
        ),
      ];
    case TrajectoryToolRecord():
      return [
        _summaryTab(record, snapshot, strings),
        if (record.argsRaw.isNotEmpty)
          TrajectoryDetailsTab(
            id: 'payload',
            label: strings.tabPayload,
            build: (context) =>
                _monoPage(_prettyJson(record.argsRaw), mono: true),
          ),
        if (record.result.isNotEmpty || record.isError)
          TrajectoryDetailsTab(
            id: 'result',
            label: strings.tabResult,
            build: (context) => record.result.isEmpty
                ? _mutedPage(strings.recordNoOutput)
                : _monoPage(
                    record.result,
                    mono: true,
                    color: record.isError
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
          ),
        TrajectoryDetailsTab(
          id: 'schema',
          label: strings.tabSchema,
          build: (context) =>
              _schemaPage(context, record.name, snapshot, strings),
        ),
        TrajectoryDetailsTab(
          id: 'timing',
          label: strings.tabTiming,
          build: (context) => _timingPage(record, strings),
        ),
      ];
    case TrajectoryAssistantRecord():
      final pair =
          record.previousPromptDetail != null && record.promptDetail != null
          ? (record.previousPromptDetail!, record.promptDetail!)
          : null;
      final preview = _previewMarkdown(record);
      return [
        _summaryTab(record, snapshot, strings),
        if (pair != null)
          TrajectoryDetailsTab(
            id: 'diff',
            label: strings.tabDiff,
            build: (context) => _diffPage(context, pair.$1, pair.$2),
          ),
        TrajectoryDetailsTab(
          id: 'preview',
          label: strings.tabPreview,
          build: (context) => preview == null || preview.isEmpty
              ? _mutedPage(strings.recordNoOutput)
              : _markdownPage(context, preview),
        ),
        TrajectoryDetailsTab(
          id: 'raw',
          label: strings.tabRaw,
          build: (context) =>
              _rawBlocksPage(context, record.sourceBlocks, strings),
        ),
        TrajectoryDetailsTab(
          id: 'timing',
          label: strings.tabTiming,
          build: (context) => _timingPage(record, strings),
        ),
      ];
    case TrajectoryUserRecord():
      return _markdownTabs(
        summary: _summaryTab(record, snapshot, strings),
        preview: record.inputDetail ?? record.previewMarkdown ?? record.text,
        blocks: record.sourceBlocks,
        strings: strings,
      );
    case TrajectoryContextRecord():
      return _markdownTabs(
        summary: _summaryTab(record, snapshot, strings),
        preview: record.previewMarkdown ?? record.text,
        blocks: const [],
        strings: strings,
      );
  }
}

/// Tab set for a captured provider request: Summary, Usage, Timing.
List<TrajectoryDetailsTab> trajectoryRequestDetailTabs(
  TrajectoryRequestNumber request,
  TrajectorySnapshot? snapshot,
  TrajectoryStrings strings,
) => [
  TrajectoryDetailsTab(
    id: 'summary',
    label: strings.tabSummary,
    build: (context) =>
        _requestSummaryPage(context, request, snapshot, strings),
  ),
  TrajectoryDetailsTab(
    id: 'usage',
    label: strings.tabUsage,
    build: (context) => _requestUsagePage(request, strings),
  ),
  TrajectoryDetailsTab(
    id: 'timing',
    label: strings.tabTiming,
    build: (context) => _requestTimingPage(request, strings),
  ),
];

/// One line of the prompt diff: [kind] with its prefixed [text].
class TrajectoryPromptDiffLine {
  /// Creates a diff line.
  const TrajectoryPromptDiffLine(this.kind, this.text);

  /// Line class driving the color.
  final TrajectoryPromptDiffLineKind kind;

  /// Prefixed line text (`+ `, `- `, context, or an ellipsis marker).
  final String text;
}

/// Diff line class.
enum TrajectoryPromptDiffLineKind { context, added, removed, ellipsis }

/// Minimal unified-style line diff: common prefix/suffix trim, the middle
/// treated as one changed block, up to 3 context lines on each side with
/// ellipsis markers where context collapsed.
// ponytail: no LCS/hunk merging — long rewrites render as one block; swap
// in a real structured-patch diff if hunks ever matter.
List<TrajectoryPromptDiffLine> trajectoryPromptDiffLines(
  String before,
  String after,
) {
  final beforeLines = before.split('\n');
  final afterLines = after.split('\n');
  final shared = math.min(beforeLines.length, afterLines.length);
  var prefix = 0;
  while (prefix < shared && beforeLines[prefix] == afterLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shared - prefix &&
      beforeLines[beforeLines.length - 1 - suffix] ==
          afterLines[afterLines.length - 1 - suffix]) {
    suffix++;
  }
  if (prefix == beforeLines.length && prefix == afterLines.length) {
    return const [];
  }
  final lines = <TrajectoryPromptDiffLine>[];
  if (prefix > 3) {
    lines.add(
      const TrajectoryPromptDiffLine(
        TrajectoryPromptDiffLineKind.ellipsis,
        '⋯',
      ),
    );
  }
  for (var i = math.max(0, prefix - 3); i < prefix; i++) {
    lines.add(
      TrajectoryPromptDiffLine(
        TrajectoryPromptDiffLineKind.context,
        beforeLines[i],
      ),
    );
  }
  for (var i = prefix; i < beforeLines.length - suffix; i++) {
    lines.add(
      TrajectoryPromptDiffLine(
        TrajectoryPromptDiffLineKind.removed,
        '- ${beforeLines[i]}',
      ),
    );
  }
  for (var i = prefix; i < afterLines.length - suffix; i++) {
    lines.add(
      TrajectoryPromptDiffLine(
        TrajectoryPromptDiffLineKind.added,
        '+ ${afterLines[i]}',
      ),
    );
  }
  if (suffix > 3) {
    lines.add(
      const TrajectoryPromptDiffLine(
        TrajectoryPromptDiffLineKind.ellipsis,
        '⋯',
      ),
    );
  }
  for (var i = 0; i < math.min(3, suffix); i++) {
    lines.add(
      TrajectoryPromptDiffLine(
        TrajectoryPromptDiffLineKind.context,
        beforeLines[beforeLines.length - suffix + i],
      ),
    );
  }
  return lines;
}

// Pages ----------------------------------------------------------------------

TrajectoryDetailsTab _summaryTab(
  TrajectoryRecord record,
  TrajectorySnapshot? snapshot,
  TrajectoryStrings strings,
) => TrajectoryDetailsTab(
  id: 'summary',
  label: strings.tabSummary,
  build: (context) => _summaryPage(context, record, snapshot, strings),
);

List<TrajectoryDetailsTab> _markdownTabs({
  required TrajectoryDetailsTab summary,
  required String preview,
  required List<TrajectorySourceBlock> blocks,
  required TrajectoryStrings strings,
}) => [
  summary,
  TrajectoryDetailsTab(
    id: 'preview',
    label: strings.tabPreview,
    build: (context) => preview.isEmpty
        ? _mutedPage(strings.recordNoContent)
        : _markdownPage(context, preview),
  ),
  TrajectoryDetailsTab(
    id: 'raw',
    label: strings.tabRaw,
    build: (context) => _rawBlocksPage(context, blocks, strings),
  ),
];

Widget _summaryPage(
  BuildContext context,
  TrajectoryRecord record,
  TrajectorySnapshot? snapshot,
  TrajectoryStrings strings,
) {
  final errorColor = Theme.of(context).colorScheme.error;
  final rows = <Widget>[
    _DetailRow(strings.detailsStatus, _statusLabel(record, strings)),
  ];
  switch (record) {
    case TrajectoryAssistantRecord():
      final provider = record.provider;
      final model = record.model;
      if (provider != null) {
        rows.add(_DetailRow(strings.detailsProvider, provider));
      }
      if (model != null) {
        rows.add(_DetailRow(strings.detailsModel, model));
      }
      rows.add(
        _DetailRow(strings.detailsSource, '${record.sourceBlocks.length}'),
      );
      rows.add(
        _DetailRow(
          strings.detailsToolCalls,
          '${_countToolCalls(record.sourceBlocks) + _countToolCalls(record.outputBlocks)}',
        ),
      );
      if (record.isError ?? false) {
        rows.add(
          _DetailRow(
            strings.detailsError,
            _errorMessage(record.errorCode, record.errorMessage, strings),
            color: errorColor,
          ),
        );
      }
      final usage = record.usage ?? _usageFromFlat(record);
      if (usage != null) {
        final reasoning = usage.reasoning;
        rows.add(
          _DetailRow(
            strings.usageOutput,
            strings.unitTokens('${usage.output}'),
          ),
        );
        if (reasoning != null) {
          rows.add(
            _DetailRow(
              strings.usageReasoning,
              strings.unitTokens('$reasoning'),
            ),
          );
          rows.add(
            _DetailRow(
              strings.usageContent,
              strings.unitTokens('${math.max(0, usage.output - reasoning)}'),
            ),
          );
        }
      }
      final request = snapshot == null
          ? null
          : _matchingRequest(snapshot, record.turn, record.step);
      if (request != null) {
        rows.add(
          _DetailRow(
            strings.detailsHierarchy,
            strings.requestLabel(request.seq),
          ),
        );
      }
    case TrajectoryToolRecord():
      if (record.isError) {
        rows.add(
          _DetailRow(strings.detailsError, record.result, color: errorColor),
        );
      }
    case TrajectorySystemRecord():
      if (record.errorCode != null || record.errorMessage != null) {
        rows.add(
          _DetailRow(
            strings.detailsError,
            _errorMessage(record.errorCode, record.errorMessage, strings),
            color: errorColor,
          ),
        );
      }
    case TrajectoryCompactedRecord() ||
        TrajectoryUserRecord() ||
        TrajectoryContextRecord():
      break;
  }
  return _listPage(rows);
}

Widget _requestSummaryPage(
  BuildContext context,
  TrajectoryRequestNumber request,
  TrajectorySnapshot? snapshot,
  TrajectoryStrings strings,
) {
  final rows = <Widget>[
    _DetailRow(
      strings.detailsStatus,
      _requestStatusLabel(request.status, strings),
    ),
    _DetailRow(strings.detailsProvider, request.provider),
    _DetailRow(strings.detailsModel, request.model),
  ];
  final assistant = snapshot == null
      ? null
      : _assistantOfRequest(snapshot, request);
  if (assistant != null) {
    rows.add(
      _DetailRow(
        strings.detailsToolCalls,
        '${_countToolCalls(assistant.sourceBlocks) + _countToolCalls(assistant.outputBlocks)}',
      ),
    );
    if (assistant.isError ?? false) {
      rows.add(
        _DetailRow(
          strings.detailsError,
          _errorMessage(assistant.errorCode, assistant.errorMessage, strings),
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
  return _listPage(rows);
}

Widget _requestUsagePage(
  TrajectoryRequestNumber request,
  TrajectoryStrings strings,
) {
  return _listPage([
    Text(strings.usageThisRequest, style: _headingStyle),
    ..._usageRows(request.usage, strings),
    const SizedBox(height: 16),
    Text(strings.usageSessionCumulative, style: _headingStyle),
    ..._usageRows(request.cumulativeUsage, strings),
  ]);
}

Widget _requestTimingPage(
  TrajectoryRequestNumber request,
  TrajectoryStrings strings,
) {
  final started = request.startedAt;
  final completed = request.completedAt;
  final seconds = started == null || completed == null
      ? null
      : math.max(0, completed.difference(started).inMilliseconds) / 1000;
  return _listPage([
    _DetailRow(strings.timingStarted, _timestampLabel(started)),
    _DetailRow(strings.timingDuration, formatElapsedSeconds(seconds)),
    _DetailRow(
      strings.timingSource,
      completed == null
          ? strings.timingSessionTimestampsRunning
          : strings.timingSessionTimestamps,
    ),
  ]);
}

Widget _timingPage(TrajectoryRecord record, TrajectoryStrings strings) {
  if (record is TrajectoryAssistantRecord) {
    return _listPage(_assistantTimingRows(record, strings));
  }
  final started = switch (record) {
    TrajectoryToolRecord(:final startedAt) => startedAt,
    TrajectoryCompactedRecord(:final startedAt) => startedAt,
    TrajectoryUserRecord(:final startedAt) => startedAt,
    TrajectorySystemRecord(:final time) => time,
    _ => null,
  };
  final seconds = _durationOf(record);
  return _listPage([
    _DetailRow(strings.timingStarted, _timestampLabel(started)),
    _DetailRow(
      strings.timingDuration,
      formatElapsedSeconds(
        seconds == null ? null : seconds.inMilliseconds / 1000,
      ),
    ),
    _DetailRow(
      strings.timingSource,
      seconds == null
          ? strings.timingNotAvailable
          : strings.timingSessionTimestamps,
    ),
  ]);
}

List<Widget> _assistantTimingRows(
  TrajectoryAssistantRecord record,
  TrajectoryStrings strings,
) {
  final start = record.stepStartTime;
  final firstToken = record.firstTokenTime;
  final completed = record.completedTime;
  String gap(DateTime? later, DateTime? earlier, {String? pendingLabel}) {
    if (pendingLabel != null && completed == null) return pendingLabel;
    if (later == null || earlier == null) return strings.timingNotAvailable;
    return formatDurationMillis(
      math.max(0, later.difference(earlier).inMilliseconds),
    );
  }

  final tokens = record.outputTokens ?? record.usage?.output;
  var throughput = strings.timingNotAvailable;
  if (tokens != null && firstToken != null && completed != null) {
    final generationSeconds =
        completed.difference(firstToken).inMilliseconds / 1000;
    throughput = generationSeconds <= 0
        ? strings.timingDurationTooShort
        : strings.unitTokensPerSecond(
            (tokens / generationSeconds).toStringAsFixed(1),
          );
  }
  return [
    _DetailRow(strings.timingStarted, _timestampLabel(start)),
    _DetailRow(
      strings.timingTotalDuration,
      gap(completed, start, pendingLabel: strings.statusPending),
    ),
    _DetailRow(strings.timingTtft, gap(firstToken, start)),
    _DetailRow(
      strings.timingGeneration,
      gap(completed, firstToken, pendingLabel: strings.statusPending),
    ),
    _DetailRow(strings.timingThroughput, throughput),
  ];
}

List<Widget> _usageRows(Usage? usage, TrajectoryStrings strings) {
  if (usage == null) return [_MutedText(strings.usageNotReported)];
  final reasoning = usage.reasoning;
  return [
    _DetailRow(
      strings.usageInput,
      strings.unitTokens('${usage.input + usage.cacheRead + usage.cacheWrite}'),
    ),
    _DetailRow(
      strings.usageCached,
      strings.unitTokens('${usage.cacheRead}'),
      indent: true,
    ),
    _DetailRow(
      strings.usageCacheCreated,
      strings.unitTokens('${usage.cacheWrite}'),
      indent: true,
    ),
    _DetailRow(
      strings.usageOther,
      strings.unitTokens('${usage.input}'),
      indent: true,
    ),
    _DetailRow(strings.usageOutput, strings.unitTokens('${usage.output}')),
    if (reasoning != null) ...[
      _DetailRow(
        strings.usageReasoning,
        strings.unitTokens('$reasoning'),
        indent: true,
      ),
      _DetailRow(
        strings.usageContent,
        strings.unitTokens('${math.max(0, usage.output - reasoning)}'),
        indent: true,
      ),
    ],
  ];
}

Widget _schemaPage(
  BuildContext context,
  String toolName,
  TrajectorySnapshot? snapshot,
  TrajectoryStrings strings,
) {
  final raw = snapshot?.callSchemas[toolName];
  Object? decoded;
  try {
    decoded = raw == null ? null : jsonDecode(raw);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! Map) return _mutedPage(strings.recordSchemaUnavailable);
  final name = decoded['name'];
  final description = decoded['description'];
  final parameters = decoded['parameters'];
  return _listPage([
    if (name is String)
      Text(name, style: Theme.of(context).textTheme.titleMedium),
    if (description is String && description.isNotEmpty)
      Padding(padding: const EdgeInsets.only(top: 8), child: Text(description)),
    Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(strings.recordParameters, style: _headingStyle),
    ),
    SelectableText(
      parameters == null
          ? '{}'
          : const JsonEncoder.withIndent('  ').convert(parameters),
      style: _monoStyle(context),
    ),
  ]);
}

Widget _rawBlocksPage(
  BuildContext context,
  List<TrajectorySourceBlock> blocks,
  TrajectoryStrings strings,
) {
  if (blocks.isEmpty) return _mutedPage(strings.recordNoContent);
  final dim = _monoStyle(
    context,
  )?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
  return _listPage([
    for (var i = 0; i < blocks.length; i++)
      if (blocks[i].type == 'toolCall')
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Text('Block #${i + 1} toolCall', style: dim),
              const SizedBox(width: 8),
              Chip(label: Text(blocks[i].toolName ?? '')),
            ],
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            'Block #${i + 1} ${blocks[i].type}',
            style: _monoStyle(context),
          ),
        ),
  ]);
}

Widget _diffPage(BuildContext context, String before, String after) {
  final lines = trajectoryPromptDiffLines(before, after);
  if (lines.isEmpty) return _mutedPage('—');
  return _listPage([
    for (final line in lines)
      Text(
        line.text,
        style: _monoStyle(context)?.copyWith(
          color: switch (line.kind) {
            TrajectoryPromptDiffLineKind.added => Colors.green,
            TrajectoryPromptDiffLineKind.removed => Colors.red,
            TrajectoryPromptDiffLineKind.ellipsis => Theme.of(
              context,
            ).colorScheme.onSurfaceVariant,
            TrajectoryPromptDiffLineKind.context => null,
          },
        ),
      ),
  ]);
}

// Small building blocks --------------------------------------------------------

const _headingStyle = TextStyle(fontWeight: FontWeight.w600, fontSize: 13);

Widget _listPage(List<Widget> children) =>
    ListView(padding: const EdgeInsets.all(16), children: children);

Widget _markdownPage(BuildContext context, String data) => ListView(
  padding: const EdgeInsets.all(16),
  children: [
    MarkdownBody(
      data: data,
      styleSheet: fahMarkdownStyleSheet(Theme.of(context)),
    ),
  ],
);

Widget _monoPage(
  String text, {
  bool mono = false,
  bool muted = false,
  Color? color,
}) => ListView(
  padding: const EdgeInsets.all(16),
  children: [
    SelectableText(
      text,
      style: TextStyle(
        fontFamily: mono ? 'monospace' : null,
        color: color ?? (muted ? Colors.grey : null),
      ),
    ),
  ],
);

Widget _mutedPage(String text) => _listPage([_MutedText(text)]);

class _MutedText extends StatelessWidget {
  const _MutedText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Label/value row shared by every page.
class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value, {this.color, this.indent = false});

  final String label;
  final String value;
  final Color? color;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: indent ? 132 : 120,
            child: Text(
              indent ? '  $label' : label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle? _monoStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');

// Pure helpers -----------------------------------------------------------------

String _statusLabel(TrajectoryRecord record, TrajectoryStrings strings) =>
    switch (_statusOf(record)) {
      _RecordStatus.failed => strings.statusFailed,
      _RecordStatus.pending => strings.statusPending,
      _RecordStatus.completed => strings.statusCompleted,
    };

enum _RecordStatus { failed, pending, completed }

_RecordStatus _statusOf(TrajectoryRecord record) => switch (record) {
  TrajectoryAssistantRecord(
    :final isError,
    :final completedTime,
    :final stepStartTime,
  ) =>
    isError ?? false
        ? _RecordStatus.failed
        : completedTime == null && stepStartTime != null
        ? _RecordStatus.pending
        : _RecordStatus.completed,
  TrajectoryToolRecord(:final isError, :final result) =>
    isError
        ? _RecordStatus.failed
        : result.isEmpty
        ? _RecordStatus.pending
        : _RecordStatus.completed,
  TrajectoryCompactedRecord(:final interrupted, :final timeSeconds) =>
    interrupted
        ? _RecordStatus.failed
        : timeSeconds == null
        ? _RecordStatus.pending
        : _RecordStatus.completed,
  TrajectorySystemRecord(:final errorCode, :final errorMessage) =>
    errorCode != null || errorMessage != null
        ? _RecordStatus.failed
        : _RecordStatus.completed,
  _ => _RecordStatus.completed,
};

String _requestStatusLabel(
  TrajectoryRequestStatus status,
  TrajectoryStrings strings,
) => switch (status) {
  TrajectoryRequestStatus.running => strings.statusPending,
  TrajectoryRequestStatus.completed => strings.statusCompleted,
  TrajectoryRequestStatus.failed => strings.statusFailed,
};

String _errorMessage(String? code, String? message, TrajectoryStrings strings) {
  if (code == 'AUTH') return strings.detailsFailureAuth;
  if (message != null && message.isNotEmpty) {
    return code == null ? message : '$code: $message';
  }
  return code ?? '—';
}

String _timestampLabel(DateTime? time) {
  if (time == null) return '—';
  final local = time.toLocal();
  String pad(int value, [int width = 2]) =>
      value.toString().padLeft(width, '0');
  return '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}.'
      '${pad(local.millisecond, 3)}';
}

String _prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } on FormatException {
    return raw;
  }
}

int _countToolCalls(List<TrajectorySourceBlock> blocks) => [
  for (final block in blocks)
    if (block.type == 'toolCall') block,
].length;

Usage? _usageFromFlat(TrajectoryAssistantRecord record) {
  if (record.inputTokens == null &&
      record.outputTokens == null &&
      record.cacheReadTokens == null &&
      record.cacheWriteTokens == null) {
    return null;
  }
  return Usage(
    input: record.inputTokens ?? 0,
    output: record.outputTokens ?? 0,
    cacheRead: record.cacheReadTokens ?? 0,
    cacheWrite: record.cacheWriteTokens ?? 0,
    reasoning: record.reasoningTokens,
    totalTokens: 0,
    cost: const UsageCost(),
  );
}

Duration? _durationOf(TrajectoryRecord record) => switch (record) {
  TrajectoryToolRecord(:final timeSeconds) => timeSeconds,
  TrajectoryCompactedRecord(:final timeSeconds) => timeSeconds,
  TrajectoryAssistantRecord(:final timeSeconds) => timeSeconds,
  _ => null,
};

/// Markdown shown in the Preview tab, or null when there is nothing.
String? _previewMarkdown(TrajectoryRecord record) => switch (record) {
  TrajectoryUserRecord(
    :final inputDetail,
    :final previewMarkdown,
    :final text,
  ) =>
    inputDetail ?? previewMarkdown ?? (text.isEmpty ? null : text),
  TrajectoryContextRecord(:final previewMarkdown, :final text) =>
    previewMarkdown ?? (text.isEmpty ? null : text),
  TrajectoryAssistantRecord(
    :final outputDetail,
    :final thinkingDetail,
    :final displayText,
  ) =>
    outputDetail ??
        thinkingDetail ??
        (displayText.isEmpty ? null : displayText),
  TrajectoryCompactedRecord(:final summary) => summary,
  _ => null,
};

TrajectoryRequestNumber? _matchingRequest(
  TrajectorySnapshot snapshot,
  int turn,
  int step,
) {
  for (final request in snapshot.requests) {
    if (request.purpose == TrajectoryRequestPurpose.assistant &&
        request.turn == turn &&
        request.step == step) {
      return request;
    }
  }
  return null;
}

TrajectoryAssistantRecord? _assistantOfRequest(
  TrajectorySnapshot snapshot,
  TrajectoryRequestNumber request,
) {
  for (final record in snapshot.records) {
    if (record is TrajectoryAssistantRecord &&
        !record.requestOnly &&
        record.turn == request.turn &&
        record.step == request.step) {
      return record;
    }
  }
  return null;
}
