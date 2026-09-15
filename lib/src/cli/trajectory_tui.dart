/// Plain-text trajectory surfaces shared by the REPL `/trajectory` family
/// and the headless `fa trajectory` subcommand: the capped-per-session TUI
/// fallback, the cumulative cost table, the per-record inspect view, the
/// `--json` line encoder, the live-tail renderer, and the session-store
/// lookup both entries use.
///
/// Pure Dart (no `dart:io`): the session store abstracts the filesystem
/// behind [JsonlSessionRepo], so every function here is testable without a
/// real terminal.
library;

import 'dart:convert';

import '../session/session_record.dart';
import '../session/session_repo.dart';
import '../session/session_tree.dart';
import '../trajectory/event_projection.dart';
import '../trajectory/formatters.dart';
import '../trajectory/trajectory_blobs.dart';
import '../trajectory/trajectory_record.dart';
import '../trajectory/trajectory_snapshot.dart';
import '../trajectory/trajectory_snapshot_builder.dart';

/// How often the live tail re-reads the session for appended records.
const trajectoryPollInterval = Duration(milliseconds: 500);

/// The per-view row cap from the issue's TUI fallback spec.
const trajectoryMaxLines = 200;

/// Projects finalized session records (the active branch) into a snapshot.
TrajectorySnapshot trajectorySnapshotOf(List<SessionRecord> records) {
  // One snapshot for the whole backfill (issue #262): per-append
  // materialization is O(n²) over a large session and nobody renders the
  // intermediates.
  return TrajectorySnapshotBuilder().appendAll(records);
}

/// The snapshot as it stood at trajectory record [at]: records are appended
/// until the projected row count reaches [at]. Null when the session never
/// reaches [at] rows.
TrajectorySnapshot? trajectorySnapshotAt(List<SessionRecord> records, int at) {
  if (at < 1) return null;
  final builder = TrajectorySnapshotBuilder();
  var snapshot = TrajectorySnapshot.empty;
  for (final record in records) {
    snapshot = builder.append(record);
    if (snapshot.records.length >= at) return snapshot;
  }
  return null;
}

/// Resolves the trajectory session to read: an exact id match wins, then a
/// session-name match (the `/session` lookup rule), else the most recent
/// session in the store when [sessionId] is omitted. Null when nothing
/// matches.
Future<Session?> resolveTrajectorySession(
  JsonlSessionRepo repo,
  String? sessionId,
) async {
  final sessions = await repo.list();
  if (sessions.isEmpty) return null;
  final wanted = sessionId?.trim();
  if (wanted == null || wanted.isEmpty) {
    return repo.open(sessions.first);
  }
  for (final metadata in sessions) {
    if (metadata.id == wanted) return repo.open(metadata);
  }
  for (final metadata in sessions) {
    final name = await repo.sessionNameQuick(metadata);
    if (name != null && name.trim() == wanted) return repo.open(metadata);
  }
  return null;
}

/// Incremental tail renderer: feed it the session's records on every poll
/// and it renders only the suffix appended since the last call. One builder
/// stays alive across calls, so projection costs O(new records), not O(n).
final class TrajectoryTailer {
  /// Creates a tailer rendering rows at [width] columns.
  TrajectoryTailer({this.width = 80});

  /// Row width in columns.
  final int width;

  final TrajectorySnapshotBuilder _builder = TrajectorySnapshotBuilder();
  int _seen = 0;
  int _rendered = 0;

  /// Renders the records appended since the previous call (nothing while
  /// the record list has not grown).
  List<String> tail(List<SessionRecord> records) {
    if (records.length <= _seen) return const [];
    final fresh = records.sublist(_seen);
    _seen = records.length;
    final lines = <String>[];
    for (final record in fresh) {
      final snapshot = _builder.append(record);
      while (_rendered < snapshot.records.length) {
        lines.add(_trajectoryLine(snapshot.records[_rendered], width));
        _rendered++;
      }
    }
    return lines;
  }
}

/// The TUI fallback rows: one line per record,
/// `#N KIND text… (duration, tokens)`, whitespace-flattened and truncated
/// to [width] with `…`. When the snapshot exceeds [maxLines] (`<= 0` keeps
/// everything) only the last [maxLines] rows survive, prefixed by one
/// `…` notice naming the hidden count. Empty snapshot → `['no records']`.
List<String> trajectoryLines(
  TrajectorySnapshot snapshot, {
  int width = 80,
  int maxLines = trajectoryMaxLines,
}) {
  if (snapshot.records.isEmpty) return const ['no records'];
  final lines = [
    for (final record in snapshot.records) _trajectoryLine(record, width),
  ];
  if (maxLines <= 0 || lines.length <= maxLines) return lines;
  return [
    '… ${lines.length - maxLines} earlier records hidden',
    ...lines.sublist(lines.length - maxLines),
  ];
}

String _trajectoryLine(TrajectoryRecord record, int width) {
  final facts = _rowFacts(record);
  final prefix = '#${record.index} ${trajectoryKindLabel(record.kind)}';
  final suffixParts = <String>[
    if (facts.durationMillis != null)
      '${formatDurationMillis(facts.durationMillis)} ms',
    if (facts.tokens != null) '${formatTokens(facts.tokens)} tok',
  ];
  final suffix = suffixParts.isEmpty ? '' : ' (${suffixParts.join(', ')})';
  final text = facts.text.replaceAll(_whitespace, ' ').trim();
  final budget = (width - prefix.length - suffix.length - 1).clamp(0, width);
  final shown = text.isEmpty
      ? '—'
      : text.length > budget
      ? '${text.substring(0, (budget - 1).clamp(0, text.length))}…'
      : text;
  return '$prefix $shown$suffix';
}

final RegExp _whitespace = RegExp(r'\s+');

/// The uppercase row label for a record kind (the ledger's kind tags).
String trajectoryKindLabel(TrajectoryCellKind kind) => switch (kind) {
  TrajectoryCellKind.system => 'SYSTEM',
  TrajectoryCellKind.user => 'USER',
  TrajectoryCellKind.context => 'CONTEXT',
  TrajectoryCellKind.compacted => 'COMPACTED',
  TrajectoryCellKind.message => 'ASSISTANT',
  TrajectoryCellKind.tool => 'TOOL',
  TrajectoryCellKind.subtool => 'SUBTOOL',
};

/// The per-row display facts: text, own duration, token total.
({String text, int? durationMillis, int? tokens}) _rowFacts(
  TrajectoryRecord record,
) {
  return switch (record) {
    final TrajectoryAssistantRecord r => (
      text: r.outputDetail ?? r.displayText,
      durationMillis: r.timeSeconds?.inMilliseconds,
      tokens: r.usage?.totalTokens ?? r.outputTokens,
    ),
    final TrajectoryToolRecord r => (
      text: r.result.isEmpty
          ? '${r.name} ${r.argsRaw}'.trim()
          : '${r.name} ${r.argsRaw} → ${r.result}',
      durationMillis: r.timeSeconds?.inMilliseconds,
      tokens: null,
    ),
    final TrajectoryUserRecord r => (
      text: r.text,
      durationMillis: null,
      tokens: null,
    ),
    final TrajectoryContextRecord r => (
      text: r.text,
      durationMillis: null,
      tokens: null,
    ),
    final TrajectoryCompactedRecord r => (
      text: r.text,
      durationMillis: r.timeSeconds?.inMilliseconds,
      tokens: null,
    ),
    final TrajectorySystemRecord r => (
      text: r.text,
      durationMillis: null,
      tokens: null,
    ),
  };
}

/// The cumulative usage/cost table from the snapshot's captured requests:
/// one row per request, then the session cumulative line. The cost column
/// appears only when some request carried a non-zero cost.
List<String> trajectoryCostLines(TrajectorySnapshot snapshot) {
  final requests = snapshot.requests;
  if (requests.isEmpty) return const ['no requests'];
  final showCost = requests.any((r) => (r.usage?.cost.total ?? 0) != 0);
  final rows = <List<String>>[
    ['#', 'turn/step', 'model', 'in', 'out', 'total', if (showCost) 'cost'],
    for (final request in requests)
      () {
        final usage = request.usage;
        return <String>[
          '${request.seq}',
          '${request.turn}/${request.step}',
          request.model.isEmpty ? '—' : request.model,
          usage == null ? '—' : formatTokens(usage.input),
          usage == null ? '—' : formatTokens(usage.output),
          usage == null ? '—' : formatTokens(usage.totalTokens),
          if (showCost)
            usage == null ? '—' : '\$${usage.cost.total.toStringAsFixed(4)}',
        ];
      }(),
  ];
  final widths = <int>[
    for (var column = 0; column < rows.first.length; column++)
      rows.fold<int>(
        0,
        (wide, row) => row[column].length > wide ? row[column].length : wide,
      ),
  ];
  final lines = <String>[
    for (final row in rows)
      [
        for (var column = 0; column < row.length; column++)
          column >= 3
              ? row[column].padLeft(widths[column])
              : row[column].padRight(widths[column]),
      ].join('  '),
  ];
  final cumulative = requests.last.cumulativeUsage;
  if (cumulative == null) return lines;
  final totals =
      'in ${formatTokens(cumulative.input)}, out '
      '${formatTokens(cumulative.output)}, tokens '
      '${formatTokens(cumulative.totalTokens)}';
  return [
    ...lines,
    'session cumulative: $totals'
        '${showCost ? ', cost \$${cumulative.cost.total.toStringAsFixed(4)}' : ''}',
  ];
}

/// The plain-text error for an out-of-range record index.
String trajectoryRangeError(int index, int count) =>
    'trajectory: record out of range: $index (1..$count)';

/// The full-detail plain-text view of record [index] (1-based), or null
/// when the index is out of range ([trajectoryRangeError] renders the
/// message the caller owes the user).
List<String>? trajectoryInspectLines(TrajectorySnapshot snapshot, int index) {
  if (index < 1 || index > snapshot.records.length) return null;
  final record = snapshot.records[index - 1];
  final lines = <String>[
    '#${record.index} ${trajectoryKindLabel(record.kind)}',
  ];
  switch (record) {
    case final TrajectorySystemRecord r:
      _inspectSystem(lines, r, snapshot.blobs);
    case final TrajectoryAssistantRecord r:
      _inspectAssistant(lines, r, snapshot.blobs);
    case final TrajectoryToolRecord r:
      _inspectTool(lines, r);
    case final TrajectoryUserRecord r:
      _inspectUser(lines, r);
    case final TrajectoryContextRecord r:
      _inspectContext(lines, r);
    case final TrajectoryCompactedRecord r:
      _inspectCompacted(lines, r);
  }
  return lines;
}

/// Appends a `label: value` section unless [value] is null.
void _inspectSection(List<String> lines, String label, Object? value) {
  if (value == null) return;
  lines.add('$label: $value');
}

/// Appends the `duration` section for a record's optional wall time.
void _inspectDuration(List<String> lines, Duration? timeSeconds) {
  if (timeSeconds == null) return;
  _inspectSection(
    lines,
    'duration',
    '${formatDurationMillis(timeSeconds.inMilliseconds)} ms',
  );
}

void _inspectSystem(
  List<String> lines,
  TrajectorySystemRecord r,
  TrajectoryBlobTable blobs,
) {
  _inspectSection(lines, 'change', r.change.name);
  _inspectSection(lines, 'text', r.text);
  _inspectSection(lines, 'time', r.time?.toIso8601String());
  _inspectSection(lines, 'detail', r.detail);
  _inspectSection(lines, 'error', r.errorMessage);
  _inspectPromptSection(
    lines,
    r.systemPromptHash,
    blobs,
    previous: r.previousSystemPromptHash,
  );
  _inspectManifestSection(
    lines,
    r.toolManifestHash,
    blobs,
    previous: r.previousToolManifestHash,
  );
  _inspectSection(lines, 'tools', r.activeToolNames?.join(', '));
}

void _inspectAssistant(
  List<String> lines,
  TrajectoryAssistantRecord r,
  TrajectoryBlobTable blobs,
) {
  lines[0] += ' · turn ${r.turn} · step ${r.step}';
  _inspectSection(
    lines,
    'model',
    r.provider == null && r.model == null
        ? null
        : '${r.provider ?? '—'}/${r.model ?? '—'}',
  );
  _inspectSection(lines, 'status', r.isError == true ? 'failed' : 'completed');
  _inspectSection(lines, 'started', r.stepStartTime?.toIso8601String());
  _inspectSection(lines, 'first token', r.firstTokenTime?.toIso8601String());
  _inspectSection(lines, 'completed', r.completedTime?.toIso8601String());
  _inspectDuration(lines, r.timeSeconds);
  _inspectAssistantUsage(lines, r);
  _inspectRequestBlobs(lines, r, blobs);
  _inspectSection(lines, 'input', r.inputDetail);
  _inspectSection(lines, 'output', r.outputDetail);
  _inspectSection(lines, 'thinking', r.thinkingDetail);
  if (r.isError == true) _inspectSection(lines, 'error', r.errorMessage);
}

/// The request-blob pointers for an assistant row (issue #385 AC9): the
/// prompt/manifest/wire-dump hashes the request references, with the
/// resolved sizes when the blob table holds them (E6: absent hashes print
/// as pointers only — never as fake content).
void _inspectRequestBlobs(
  List<String> lines,
  TrajectoryAssistantRecord r,
  TrajectoryBlobTable blobs,
) {
  final detail = r.requestDetail;
  if (detail == null) return;
  _inspectPromptSection(lines, detail.systemPromptHash, blobs, previous: null);
  final manifestHash = detail.toolManifestHash;
  if (manifestHash != null) {
    final blob = blobs.toolManifests[manifestHash];
    _inspectSection(
      lines,
      'manifest',
      blob == null
          ? manifestHash
          : '$manifestHash · ${blob.tools.length} tools',
    );
  }
  final wireHash = detail.wireDumpHash;
  if (wireHash != null) {
    final dump = blobs.wireDumps[wireHash];
    _inspectSection(
      lines,
      'wire dump',
      dump == null
          ? wireHash
          : '$wireHash · ${dump.payload.length} chars${dump.truncated ? ' · truncated' : ''}',
    );
  }
}

/// The system-prompt blob section for a system row (issue #385 AC9):
/// the full prompt text, or the unified diff against the previous version
/// when the row records one — the CLI mirror of the UI's System-prompt
/// tab. Hash-only when the blob is absent (E6).
void _inspectPromptSection(
  List<String> lines,
  String? promptHash,
  TrajectoryBlobTable blobs, {
  String? previous,
}) {
  if (promptHash == null) return;
  final blob = blobs.systemPrompts[promptHash];
  if (blob == null) {
    _inspectSection(lines, 'system prompt', promptHash);
    return;
  }
  lines.add('system prompt: $promptHash · ${blob.text.length} chars');
  final previousBlob = previous == null ? null : blobs.systemPrompts[previous];
  if (previousBlob != null) {
    lines.add('diff vs $previous:');
    for (final line in trajectoryPromptDiff(previousBlob.text, blob.text)) {
      final sign = switch (line.kind) {
        'added' => '+',
        'removed' => '-',
        'ellipsis' => '…',
        _ => ' ',
      };
      lines.add('  $sign${line.text}');
    }
    return;
  }
  for (final line in blob.text.split('\n')) {
    lines.add('  $line');
  }
}

/// The tools-manifest section for a `toolsChange` system row (issue #385
/// AC9/AC3): added/removed/modified tool names against the previous
/// manifest, then the full name/description/schema list — the CLI mirror
/// of the UI's Tools tab.
void _inspectManifestSection(
  List<String> lines,
  String? manifestHash,
  TrajectoryBlobTable blobs, {
  String? previous,
}) {
  if (manifestHash == null) return;
  final blob = blobs.toolManifests[manifestHash];
  if (blob == null) {
    _inspectSection(lines, 'tool manifest', manifestHash);
    return;
  }
  final previousBlob = previous == null ? null : blobs.toolManifests[previous];
  lines.add('tool manifest: $manifestHash · ${blob.tools.length} tools');
  if (previousBlob != null) {
    final diff = trajectoryToolManifestDiff(previousBlob, blob);
    if (diff.added.isNotEmpty) {
      lines.add('  + ${diff.added.join(', ')}');
    }
    if (diff.removed.isNotEmpty) {
      lines.add('  - ${diff.removed.join(', ')}');
    }
    if (diff.modified.isNotEmpty) {
      lines.add('  ~ ${diff.modified.join(', ')}');
    }
  }
  _inspectManifestTools(lines, blob.tools);
}

/// The name/description/schema listing under a manifest section; schemas
/// over 200 chars collapse to a size marker (E3).
void _inspectManifestTools(
  List<String> lines,
  List<TrajectoryToolManifestEntry> tools,
) {
  for (final tool in tools) {
    lines.add('  ${tool.name}: ${tool.description}');
    if (tool.schemaJson.length <= 200) {
      lines.add('    ${tool.schemaJson}');
    } else {
      lines.add('    [schema ${tool.schemaJson.length} chars]');
    }
  }
}

/// The `/trajectory inspect <n>` report (issue #385 AC9): the row's
/// detail lines plus, for compacted rows carrying a hidden range, the
/// lazily resolved drill-in previews. [resolveHidden] serves the range
/// on demand — null (no session) renders the header only; an empty list
/// renders the honest "not captured" marker (E6). Pure apart from the
/// resolver callback — the CLI mirror and tests share it.
Future<List<String>> trajectoryInspectReport(
  TrajectorySnapshot snapshot,
  String arg, {
  Future<List<TrajectoryHiddenRecordPreview>?> Function(
    TrajectoryCompactedRecord record,
  )?
  resolveHidden,
}) async {
  if (snapshot.records.isEmpty) return const ['no records'];
  final index = int.tryParse(arg);
  if (index == null) return const ['usage: /trajectory inspect <n>'];
  final lines = trajectoryInspectLines(snapshot, index);
  if (lines == null) {
    return [trajectoryRangeError(index, snapshot.records.length)];
  }
  if (snapshot.records[index - 1] case final TrajectoryCompactedRecord record
      when (record.hiddenRecordIds ?? const <String>[]).isNotEmpty) {
    final ids = record.hiddenRecordIds ?? const <String>[];
    lines.add('hidden range: ${ids.length} covered records');
    final previews = resolveHidden == null ? null : await resolveHidden(record);
    if (previews == null) {
      return lines; // No session to serve the range from: header only.
    }
    if (previews.isEmpty) {
      lines.add('  [hidden: not captured for this session]');
    } else {
      for (final preview in previews) {
        final time = preview.timestamp == null
            ? ''
            : ' · ${preview.timestamp!.toIso8601String()}';
        lines.add('  [${preview.type}] ${preview.preview}$time');
      }
    }
  }
  return lines;
}

/// The `tokens`/`cost` sections: per-bucket counts preferring the captured
/// usage over the record's flat fields, and the cost when non-zero.
void _inspectAssistantUsage(List<String> lines, TrajectoryAssistantRecord r) {
  final input = r.usage?.input ?? r.inputTokens;
  final output = r.usage?.output ?? r.outputTokens;
  final reasoning = r.usage?.reasoning ?? r.reasoningTokens;
  final cacheRead = r.usage?.cacheRead ?? r.cacheReadTokens;
  final cacheWrite = r.usage?.cacheWrite ?? r.cacheWriteTokens;
  final total = r.usage?.totalTokens;
  if (input != null || output != null || total != null) {
    _inspectSection(
      lines,
      'tokens',
      [
        if (input != null) 'input $input',
        if (output != null) 'output $output',
        if (reasoning != null) 'reasoning $reasoning',
        if (cacheRead != null) 'cache read $cacheRead',
        if (cacheWrite != null) 'cache write $cacheWrite',
        if (total != null) 'total $total',
      ].join(', '),
    );
  }
  if ((r.usage?.cost.total ?? 0) != 0) {
    _inspectSection(
      lines,
      'cost',
      '\$${r.usage!.cost.total.toStringAsFixed(4)}',
    );
  }
}

void _inspectTool(List<String> lines, TrajectoryToolRecord r) {
  lines[0] += ' · ${r.name}';
  _inspectSection(lines, 'call', r.callId);
  _inspectSection(lines, 'parent call', r.parentCallId);
  _inspectSection(
    lines,
    'status',
    r.result.isEmpty ? 'running' : (r.isError ? 'failed' : 'completed'),
  );
  _inspectSection(lines, 'started', r.startedAt?.toIso8601String());
  _inspectDuration(lines, r.timeSeconds);
  _inspectSection(lines, 'args', r.argsRaw);
  if (r.result.isNotEmpty) _inspectSection(lines, 'result', r.result);
}

void _inspectUser(List<String> lines, TrajectoryUserRecord r) {
  _inspectSection(lines, 'text', r.text);
  _inspectSection(lines, 'opens turn', r.opensTurn ? 'yes' : 'no');
  _inspectSection(lines, 'started', r.startedAt?.toIso8601String());
  _inspectSection(lines, 'input', r.inputDetail);
}

void _inspectContext(List<String> lines, TrajectoryContextRecord r) {
  _inspectSection(lines, 'text', r.text);
}

void _inspectCompacted(List<String> lines, TrajectoryCompactedRecord r) {
  _inspectSection(lines, 'summary', r.summary);
  _inspectSection(lines, 'kept from', r.firstKeptEntryId);
  _inspectSection(lines, 'started', r.startedAt?.toIso8601String());
  _inspectDuration(lines, r.timeSeconds);
  if (r.interrupted) _inspectSection(lines, 'interrupted', 'yes');
}

/// The compact per-record JSON line (`index`/`kind`/`text`/`timeSeconds`/
/// `tokens`) printed one per record by `fa trajectory view --json`.
String trajectoryJsonLine(TrajectoryRecord record) {
  final facts = _rowFacts(record);
  return jsonEncode(<String, Object?>{
    'index': record.index,
    'kind': record.kind.name,
    'text': facts.text.replaceAll(_whitespace, ' ').trim(),
    'timeSeconds': facts.durationMillis == null
        ? null
        : facts.durationMillis! / 1000.0,
    'tokens': facts.tokens,
  });
}
