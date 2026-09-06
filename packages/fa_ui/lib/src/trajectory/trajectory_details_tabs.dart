// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../chat/markdown_style.dart';
import 'trajectory_strings.dart';

/// Content length above which a details page collapses behind a size label
/// and an expander instead of building the full widget tree (E7:
/// multi-hundred-KiB system prompts and payloads).
const int _hugeTextChars = 256 * 1024;

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

/// Tab set for [record] per selection kind — tabs without data are absent,
/// never rendered empty:
///
/// - system → [System Prompt, Tools] (both keep explicit empty statements)
/// - compacted → [Summary, Raw Output] (Raw Output hidden when no summary)
/// - tool/subtool → [Summary, Payload?, Result, Schema?, Timing?]; Result
///   stays visible while the call runs with an in-progress state
/// - message → [Summary, Request?, Diff?, Preview, Raw, Timing?]; Request
///   appears when the record carries a [TrajectoryRequestDetail], Preview
///   keeps an explicit empty-response state
/// - user/context → [Summary, Preview?, Raw]
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
          build: (context) => _TabPage(
            strings: strings,
            copyText: record.detail,
            child: record.detail == null
                ? _mutedPage(strings.recordSystemPromptMissing)
                : _bounded(
                    context,
                    record.detail!,
                    (context, text) => _markdownPage(context, text),
                  ),
          ),
        ),
        TrajectoryDetailsTab(
          id: 'tools',
          label: strings.tabTools,
          build: (context) => _TabPage(
            strings: strings,
            child: _mutedPage(strings.recordToolsMissing),
          ),
        ),
      ];
    case TrajectoryCompactedRecord():
      return [
        _summaryTab(record, snapshot, strings),
        if (record.summary.isNotEmpty)
          TrajectoryDetailsTab(
            id: 'raw',
            label: strings.tabRawOutput,
            build: (context) => _TabPage(
              strings: strings,
              copyText: record.summary,
              child: _bounded(context, record.summary, _textPage),
            ),
          ),
      ];
    case TrajectoryToolRecord():
      return [
        _summaryTab(record, snapshot, strings),
        if (record.argsRaw.isNotEmpty)
          TrajectoryDetailsTab(
            id: 'payload',
            label: strings.tabPayload,
            build: (context) => _TabPage(
              strings: strings,
              copyText: record.argsRaw,
              child: _bounded(context, _prettyJson(record.argsRaw), _jsonPage),
            ),
          ),
        TrajectoryDetailsTab(
          id: 'result',
          label: strings.tabResult,
          build: (context) => _resultPage(context, record, strings),
        ),
        if (_hasSchema(record, snapshot))
          TrajectoryDetailsTab(
            id: 'schema',
            label: strings.tabSchema,
            build: (context) =>
                _schemaPage(context, record.name, snapshot, strings),
          ),
        if (_hasTiming(record))
          TrajectoryDetailsTab(
            id: 'timing',
            label: strings.tabTiming,
            build: (context) =>
                _TabPage(strings: strings, child: _timingPage(record, strings)),
          ),
      ];
    case TrajectoryAssistantRecord():
      final request = record.requestDetail;
      final pair =
          record.previousPromptDetail != null && record.promptDetail != null
          ? (record.previousPromptDetail!, record.promptDetail!)
          : null;
      final preview = _previewMarkdown(record);
      return [
        _summaryTab(record, snapshot, strings),
        if (request != null)
          TrajectoryDetailsTab(
            id: 'request',
            label: strings.tabRequest,
            build: (context) => _requestPage(context, request, strings),
          ),
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
              ? _TabPage(
                  strings: strings,
                  child: _emptyResponsePage(record, strings),
                )
              : _TabPage(
                  strings: strings,
                  copyText: preview,
                  child: _bounded(context, preview, _markdownPage),
                ),
        ),
        TrajectoryDetailsTab(
          id: 'raw',
          label: strings.tabRaw,
          build: (context) {
            final json = const JsonEncoder.withIndent(
              '  ',
            ).convert(_recordJsonMap(record));
            return _TabPage(
              strings: strings,
              copyText: json,
              child: _bounded(context, json, _jsonPage),
            );
          },
        ),
        if (_hasTiming(record))
          TrajectoryDetailsTab(
            id: 'timing',
            label: strings.tabTiming,
            build: (context) =>
                _TabPage(strings: strings, child: _timingPage(record, strings)),
          ),
      ];
    case TrajectoryUserRecord():
    case TrajectoryContextRecord():
      final preview = _previewMarkdown(record) ?? '';
      return [
        _summaryTab(record, snapshot, strings),
        if (preview.isNotEmpty)
          TrajectoryDetailsTab(
            id: 'preview',
            label: strings.tabPreview,
            build: (context) => _TabPage(
              strings: strings,
              copyText: preview,
              child: _bounded(context, preview, _markdownPage),
            ),
          ),
        TrajectoryDetailsTab(
          id: 'raw',
          label: strings.tabRaw,
          build: (context) {
            final json = const JsonEncoder.withIndent(
              '  ',
            ).convert(_recordJsonMap(record));
            return _TabPage(
              strings: strings,
              copyText: json,
              child: _bounded(context, json, _jsonPage),
            );
          },
        ),
      ];
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
  build: (context) => _TabPage(
    strings: strings,
    child: _summaryPage(context, record, snapshot, strings),
  ),
);

/// What the model was sent this step: counts, sizes, tool inventory, and
/// the per-message list with bounded previews.
Widget _requestPage(
  BuildContext context,
  TrajectoryRequestDetail detail,
  TrajectoryStrings strings,
) {
  final dim = _monoStyle(
    context,
  )?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
  return _TabPage(
    strings: strings,
    copyText: _requestSummaryText(detail, strings),
    child: _listPage([
      _DetailRow(strings.requestMessages, '${detail.messageCount}'),
      if (detail.systemPromptChars > 0)
        _DetailRow(
          strings.requestSystemPrompt,
          strings.unitChars(detail.systemPromptChars),
        ),
      if (detail.toolCount > 0) ...[
        _DetailRow(strings.tabTools, '${detail.toolCount}'),
        if (detail.toolNames.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 120, bottom: 4),
            child: Text(
              detail.toolNames.join(', '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
      const SizedBox(height: 12),
      if (detail.messages.isNotEmpty)
        Text(strings.requestMessages, style: _headingStyle),
      for (final message in detail.messages) ...[
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${message.role} · ${strings.unitChars(message.chars)}',
            style: dim,
          ),
        ),
        Text(
          message.preview,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ]),
  );
}

/// Compact multi-line summary of the outbound request for the clipboard.
String _requestSummaryText(
  TrajectoryRequestDetail detail,
  TrajectoryStrings strings,
) => [
  '${strings.requestMessages}: ${detail.messageCount}',
  '${strings.requestSystemPrompt}: ${strings.unitChars(detail.systemPromptChars)}',
  '${strings.tabTools}: ${detail.toolCount}'
      '${detail.toolNames.isEmpty ? '' : ' (${detail.toolNames.join(', ')})'}',
  for (final message in detail.messages)
    '${message.role} · ${strings.unitChars(message.chars)}: '
        '${message.preview.replaceAll('\n', ' ')}',
].join('\n');

/// Empty assistant response: an explicit statement plus the stop reason
/// derived from the recorded blocks — never a bare placeholder.
Widget _emptyResponsePage(
  TrajectoryAssistantRecord record,
  TrajectoryStrings strings,
) {
  final stoppedForTool = [
    ...record.sourceBlocks,
    ...record.outputBlocks,
  ].any((block) => block.type == 'toolCall');
  return _listPage([
    Text(strings.detailsEmptyResponse, style: _headingStyle),
    _DetailRow(
      strings.detailsStopReason,
      stoppedForTool
          ? strings.stopReasonToolUse
          : strings.stopReasonNotRecorded,
    ),
  ]);
}

Widget _resultPage(
  BuildContext context,
  TrajectoryToolRecord record,
  TrajectoryStrings strings,
) {
  final running = record.result.isEmpty && !record.isError;
  return _TabPage(
    strings: strings,
    copyText: record.result.isEmpty ? null : record.result,
    child: running
        ? _mutedPage(strings.recordResultPending)
        : record.result.isEmpty
        ? _mutedPage(strings.recordNoOutput)
        : _bounded(
            context,
            record.result,
            (context, text) => _textPage(
              context,
              text,
              color: record.isError
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
  );
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
  if (decoded is! Map)
    return _TabPage(
      strings: strings,
      child: _mutedPage(strings.recordSchemaUnavailable),
    );
  final name = decoded['name'];
  final description = decoded['description'];
  final parameters = decoded['parameters'];
  return _TabPage(
    strings: strings,
    copyText: raw,
    child: _listPage([
      if (name is String)
        Text(name, style: Theme.of(context).textTheme.titleMedium),
      if (description is String && description.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(description),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(strings.recordParameters, style: _headingStyle),
      ),
      _jsonText(
        context,
        parameters == null
            ? '{}'
            : const JsonEncoder.withIndent('  ').convert(parameters),
      ),
    ]),
  );
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

// Small building blocks -------------------------------------------------------

const _headingStyle = TextStyle(fontWeight: FontWeight.w600, fontSize: 13);

/// Page scaffold shared by every tab: content wrapped in a [SelectionArea]
/// (every page is selectable) plus a copy button when [copyText] is
/// non-empty.
class _TabPage extends StatelessWidget {
  const _TabPage({required this.strings, this.copyText, required this.child});

  final TrajectoryStrings strings;
  final String? copyText;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final copy = copyText;
    return Column(
      children: [
        if (copy != null && copy.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: Semantics(
              label: strings.detailsCopy,
              button: true,
              child: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: strings.detailsCopy,
                onPressed: () => Clipboard.setData(ClipboardData(text: copy)),
              ),
            ),
          ),
        Expanded(child: SelectionArea(child: child)),
      ],
    );
  }
}

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

/// Plain (optionally monospace, colored) text page; selection comes from
/// the surrounding [SelectionArea].
Widget _textPage(
  BuildContext context,
  String text, {
  bool mono = false,
  Color? color,
}) => ListView(
  padding: const EdgeInsets.all(16),
  children: [
    Text(
      text,
      style: TextStyle(fontFamily: mono ? 'monospace' : null, color: color),
    ),
  ],
);

/// Pretty-printed JSON with lightweight span coloring.
Widget _jsonPage(BuildContext context, String text) => ListView(
  padding: const EdgeInsets.all(16),
  children: [_jsonText(context, text)],
);

Widget _jsonText(BuildContext context, String text) => Text.rich(
  TextSpan(style: _monoStyle(context), children: _jsonSpans(context, text)),
);

Widget _mutedPage(String text) => _listPage([_MutedText(text)]);

/// Builds the full page for [text], or — when the text exceeds
/// [_hugeTextChars] — a collapsed region with a size label; the full
/// content builds lazily only after expanding.
Widget _bounded(
  BuildContext context,
  String text,
  Widget Function(BuildContext, String) buildFull,
) {
  if (text.length <= _hugeTextChars) return buildFull(context, text);
  return _CollapsedContent(
    text: text,
    full: (context) => buildFull(context, text),
  );
}

class _CollapsedContent extends StatefulWidget {
  const _CollapsedContent({required this.text, required this.full});

  final String text;
  final WidgetBuilder full;

  @override
  State<_CollapsedContent> createState() => _CollapsedContentState();
}

class _CollapsedContentState extends State<_CollapsedContent> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (_expanded) return widget.full(context);
    final strings = TrajectoryStrings.of(context);
    return _listPage([
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _expanded = true),
          icon: const Icon(Icons.expand_more),
          label: Text(
            strings.detailsShowContent(_formatSize(widget.text.length)),
          ),
        ),
      ),
    ]);
  }
}

/// Size label for collapsed content (chars ≈ bytes; a display hint only).
String _formatSize(int chars) => '${(chars / 1024).toStringAsFixed(1)} KiB';

/// Lightweight JSON tokenizer coloring keys, strings, numbers, and
/// literals with pure [TextStyle] spans — no syntax package.
final RegExp _jsonToken = RegExp(
  r'"(?:[^"\\]|\\.)*"(\s*:)?'
  r'|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'
  r'|\b(?:true|false|null)\b',
);

List<TextSpan> _jsonSpans(BuildContext context, String text) {
  final colors = Theme.of(context).colorScheme;
  final spans = <TextSpan>[];
  var cursor = 0;
  for (final match in _jsonToken.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    final token = match[0]!;
    final color = match[1] != null
        ? colors.primary
        : token.startsWith('"')
        ? colors.tertiary
        : token == 'true' || token == 'false' || token == 'null'
        ? colors.error
        : colors.secondary;
    spans.add(
      TextSpan(
        text: token,
        style: TextStyle(color: color),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}

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

/// Whether the record carries any wall-clock timestamp; the Timing tab is
/// hidden otherwise instead of rendering a wall of dashes.
bool _hasTiming(TrajectoryRecord record) => switch (record) {
  TrajectoryToolRecord(:final startedAt, :final timeSeconds) =>
    startedAt != null || timeSeconds != null,
  TrajectoryCompactedRecord(:final startedAt, :final timeSeconds) =>
    startedAt != null || timeSeconds != null,
  TrajectoryAssistantRecord(
    :final stepStartTime,
    :final firstTokenTime,
    :final completedTime,
    :final timeSeconds,
  ) =>
    stepStartTime != null ||
        firstTokenTime != null ||
        completedTime != null ||
        timeSeconds != null,
  _ => false,
};

/// The Schema tab appears only when the snapshot actually captured the
/// call's schema.
bool _hasSchema(TrajectoryToolRecord record, TrajectorySnapshot? snapshot) =>
    snapshot?.callSchemas.containsKey(record.name) ?? false;

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

/// Raw view of a record: the full ledger fields as a JSON map, pretty-printed
/// for the Raw tab and its clipboard payload.
Map<String, dynamic> _recordJsonMap(TrajectoryRecord record) {
  final json = <String, dynamic>{
    'index': record.index,
    'recordId': record.recordId,
    'kind': record.kind.name,
  };
  switch (record) {
    case TrajectoryAssistantRecord():
      json.addAll({
        'messageId': record.messageId,
        'turn': record.turn,
        'step': record.step,
        if (record.provider != null) 'provider': record.provider,
        if (record.model != null) 'model': record.model,
        if (record.usage != null) 'usage': record.usage!.toJson(),
        if (record.inputTokens != null) 'inputTokens': record.inputTokens,
        if (record.cacheReadTokens != null)
          'cacheReadTokens': record.cacheReadTokens,
        if (record.cacheWriteTokens != null)
          'cacheWriteTokens': record.cacheWriteTokens,
        if (record.outputTokens != null) 'outputTokens': record.outputTokens,
        if (record.reasoningTokens != null)
          'reasoningTokens': record.reasoningTokens,
        if (record.stepStartTime != null)
          'stepStartTime': record.stepStartTime!.toIso8601String(),
        if (record.firstTokenTime != null)
          'firstTokenTime': record.firstTokenTime!.toIso8601String(),
        if (record.completedTime != null)
          'completedTime': record.completedTime!.toIso8601String(),
        'sourceBlocks': _blocksJson(record.sourceBlocks),
        'outputBlocks': _blocksJson(record.outputBlocks),
        if (record.thinkingDetail != null)
          'thinkingDetail': record.thinkingDetail,
        if (record.inputDetail != null) 'inputDetail': record.inputDetail,
        if (record.outputDetail != null) 'outputDetail': record.outputDetail,
        if (record.promptDetail != null) 'promptDetail': record.promptDetail,
        if (record.previousPromptDetail != null)
          'previousPromptDetail': record.previousPromptDetail,
        if (record.timeSeconds != null)
          'timeSeconds': record.timeSeconds!.inMilliseconds,
        if (record.isError != null) 'isError': record.isError,
        if (record.errorCode != null) 'errorCode': record.errorCode,
        if (record.errorMessage != null) 'errorMessage': record.errorMessage,
        if (record.requestOnly) 'requestOnly': record.requestOnly,
        if (record.displayText.isNotEmpty) 'displayText': record.displayText,
        if (record.requestDetail != null)
          'requestDetail': record.requestDetail!.toJson(),
      });
    case TrajectoryToolRecord():
      json.addAll({
        'callId': record.callId,
        if (record.parentCallId != null) 'parentCallId': record.parentCallId,
        'name': record.name,
        'argsRaw': record.argsRaw,
        'result': record.result,
        if (record.resultPreviewMarkdown != null)
          'resultPreviewMarkdown': record.resultPreviewMarkdown,
        'isError': record.isError,
        if (record.timeSeconds != null)
          'timeSeconds': record.timeSeconds!.inMilliseconds,
        if (record.startedAt != null)
          'startedAt': record.startedAt!.toIso8601String(),
      });
    case TrajectoryUserRecord():
      json.addAll({
        'text': record.text,
        'sourceBlocks': _blocksJson(record.sourceBlocks),
        'opensTurn': record.opensTurn,
        if (record.inputDetail != null) 'inputDetail': record.inputDetail,
        if (record.startedAt != null)
          'startedAt': record.startedAt!.toIso8601String(),
        if (record.sourceSeq != null) 'sourceSeq': record.sourceSeq,
      });
    case TrajectoryContextRecord():
      json.addAll({
        'text': record.text,
        if (record.startedAt != null)
          'startedAt': record.startedAt!.toIso8601String(),
        if (record.sourceSeq != null) 'sourceSeq': record.sourceSeq,
      });
    case TrajectoryCompactedRecord():
      json.addAll({
        'text': record.text,
        'summary': record.summary,
        if (record.firstKeptEntryId != null)
          'firstKeptEntryId': record.firstKeptEntryId,
        if (record.timeSeconds != null)
          'timeSeconds': record.timeSeconds!.inMilliseconds,
        if (record.startedAt != null)
          'startedAt': record.startedAt!.toIso8601String(),
        'interrupted': record.interrupted,
      });
    case TrajectorySystemRecord():
      json.addAll({
        'text': record.text,
        'change': record.change.name,
        if (record.detail != null) 'detail': record.detail,
        if (record.time != null) 'time': record.time!.toIso8601String(),
        if (record.errorCode != null) 'errorCode': record.errorCode,
        if (record.errorMessage != null) 'errorMessage': record.errorMessage,
      });
  }
  return json;
}

List<Map<String, dynamic>> _blocksJson(List<TrajectorySourceBlock> blocks) => [
  for (final block in blocks)
    {
      'type': block.type,
      'content': block.content,
      if (block.attachmentName != null) 'attachmentName': block.attachmentName,
      if (block.callId != null) 'callId': block.callId,
      if (block.toolName != null) 'toolName': block.toolName,
    },
];

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
