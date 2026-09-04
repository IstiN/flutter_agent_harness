/// Incremental full-text index for the trajectory ledger.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-search-index.ts`. The index reparses a record's sources only
/// when that record's source signature changes, evicts records that
/// disappeared from the latest layout, and answers multi-token AND
/// substring queries with stable record ids.
library;

import 'dart:async';
import 'dart:convert';

import 'trajectory_layout.dart';
import 'trajectory_preview.dart';
import 'trajectory_record.dart';

/// Minimum gap between throttled index flushes, mirroring the TS
/// `SEARCH_INDEX_THROTTLE_MS`.
const int searchIndexThrottleMs = 3000;

final class _SearchEntry {
  const _SearchEntry(this.sources, this.text);

  /// Source signature of the indexed record; equal signatures reuse the
  /// previous entry instead of re-rendering its searchable text.
  final List<String> sources;

  /// Lowercased searchable text: sources plus the markdown previews.
  final String text;
}

String _searchableJson(Object? value) {
  if (value == null) return '';
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return '';
  }
}

bool _sameSources(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

String _turnLabel(TrajectoryTurnModel turn) =>
    turn.turn == null ? 'between turns' : 'turn ${turn.turn}';
String _markdownPreview(TrajectoryRecord record) {
  final (String? previewMarkdown, String text) = switch (record) {
    TrajectoryUserRecord(:final previewMarkdown, :final text) => (
      previewMarkdown,
      text,
    ),
    TrajectoryContextRecord(:final previewMarkdown, :final text) => (
      previewMarkdown,
      text,
    ),
    _ => (null, ''),
  };
  if (previewMarkdown == null) return '';
  final preview = trajectoryPreviewText(previewMarkdown);
  if (text.isEmpty) return preview;
  return preview.isEmpty ? text : '$text · $preview';
}

String _resultPreview(TrajectoryRecord record) => switch (record) {
  TrajectoryToolRecord(:final result, :final resultPreviewMarkdown) =>
    resultPreviewMarkdown == null
        ? result
        : trajectoryPreviewText(resultPreviewMarkdown),
  _ => '',
};

/// Session-view-local index that reparses Markdown only when one record's
/// sources change.
class TrajectorySearchIndex {
  final Map<String, _SearchEntry> _entries = {};
  List<List<TrajectoryTurnModel>>? _layouts;

  /// Incrementally synchronizes one or more current trajectory layout
  /// slices.
  ///
  /// [layouts] are the finalized and optional streaming layouts from the
  /// same view. Returns whether the indexed layout version changed.
  bool update(List<List<TrajectoryTurnModel>> layouts) {
    if (identical(layouts, _layouts)) return false;
    _layouts = layouts;
    final seen = <String>{};
    for (final turns in layouts) {
      for (final turn in turns) {
        for (final group in turn.groups) {
          for (final record in group.cells) {
            if (record is TrajectoryAssistantRecord && record.requestOnly) {
              continue;
            }
            final sources = _recordSources(turn, group, record);
            final previous = _entries[record.recordId];
            _entries[record.recordId] =
                previous != null && _sameSources(previous.sources, sources)
                ? previous
                : _SearchEntry(
                    sources,
                    [
                      ...sources,
                      _markdownPreview(record),
                      _resultPreview(record),
                    ].join('\n').toLowerCase(),
                  );
            seen.add(record.recordId);
          }
        }
      }
    }
    _entries.removeWhere((id, _) => !seen.contains(id));
    return true;
  }

  /// Matches a whitespace-separated case-insensitive query against the
  /// latest committed index version.
  ///
  /// Returns the matching stable record ids, or null without a query.
  Set<String>? search(String query) {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return null;
    return {
      for (final entry in _entries.entries)
        if (terms.every(entry.value.text.contains)) entry.key,
    };
  }

  List<String> _recordSources(
    TrajectoryTurnModel turn,
    TrajectoryGroupModel group,
    TrajectoryRecord record,
  ) {
    return [
      _turnLabel(turn),
      group.kind.name,
      record.kind.name,
      if (record.kind == TrajectoryCellKind.message) 'assistant',
      ...switch (record) {
        TrajectoryAssistantRecord(
          :final displayText,
          :final inputDetail,
          :final outputDetail,
          :final thinkingDetail,
          :final schemaDetail,
          :final promptDetail,
          :final previousPromptDetail,
          :final usage,
        ) =>
          [
            displayText,
            inputDetail ?? '',
            outputDetail ?? '',
            thinkingDetail ?? '',
            schemaDetail ?? '',
            promptDetail ?? '',
            previousPromptDetail ?? '',
            _searchableJson(usage),
          ],
        TrajectoryToolRecord(
          :final name,
          :final argsRaw,
          :final result,
          :final resultPreviewMarkdown,
          :final callId,
        ) =>
          [name, argsRaw, result, resultPreviewMarkdown ?? '', callId],
        TrajectoryUserRecord(
          :final text,
          :final previewMarkdown,
          :final inputDetail,
        ) =>
          [text, previewMarkdown ?? '', inputDetail ?? ''],
        TrajectoryContextRecord(:final text, :final previewMarkdown) => [
          text,
          previewMarkdown ?? '',
        ],
        TrajectoryCompactedRecord(:final text, :final summary) => [
          text,
          summary,
        ],
        TrajectorySystemRecord(:final text, :final detail) => [
          text,
          detail ?? '',
        ],
      },
      ...switch (record) {
        TrajectoryAssistantRecord(
          :final sourceBlocks,
          :final outputBlocks,
          :final partialBlocks,
        ) =>
          [
            for (final block in [...sourceBlocks, ...outputBlocks]) ...[
              block.type,
              block.content,
              block.callId ?? '',
              block.toolName ?? '',
              block.attachmentName ?? '',
            ],
            for (final block in partialBlocks) ...[block.type, block.content],
          ],
        TrajectoryUserRecord(:final sourceBlocks) => [
          for (final block in sourceBlocks) ...[
            block.type,
            block.content,
            block.callId ?? '',
            block.toolName ?? '',
            block.attachmentName ?? '',
          ],
        ],
        _ => const <String>[],
      },
    ];
  }
}

/// Trailing-throttle wrapper around [TrajectorySearchIndex]: the first
/// update after an idle gap is immediate, later updates coalesce into a
/// single trailing flush that always applies the latest layouts.
class ThrottledTrajectorySearchIndex {
  /// Creates a wrapper flushing at most once per [throttle] window
  /// (defaults to [searchIndexThrottleMs]).
  ThrottledTrajectorySearchIndex({Duration? throttle})
    : throttle =
          throttle ?? const Duration(milliseconds: searchIndexThrottleMs);

  /// Minimum gap between flushes.
  final Duration throttle;

  final TrajectorySearchIndex _index = TrajectorySearchIndex();
  Timer? _timer;
  List<List<TrajectoryTurnModel>>? _pending;

  /// Registers [layouts] as the latest index input; flushes immediately
  /// when no throttle window is open, else parks them for the trailing
  /// flush. Returns whether the indexed version changed.
  bool update(List<List<TrajectoryTurnModel>> layouts) {
    _pending = layouts;
    if (_timer != null) return false;
    return _flush();
  }

  /// Matches [query] against the last flushed index version.
  Set<String>? search(String query) => _index.search(query);

  /// Cancels any pending trailing flush.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  bool _flush() {
    final layouts = _pending;
    _pending = null;
    final changed = _index.update(layouts!);
    _timer = Timer(throttle, () {
      _timer = null;
      if (_pending != null) _flush();
    });
    return changed;
  }
}
