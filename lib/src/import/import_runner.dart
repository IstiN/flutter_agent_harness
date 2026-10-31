/// The import orchestrator (issue #1562): discovery → selection →
/// idempotent write. The ONLY writer in the feature: sessions land through
/// `JsonlSessionRepo.create` + `Session.append*` (under the per-path write
/// chain), foreign stores are only ever read, and the dedupe marker rides
/// the FA session header metadata (GOAL F12).
library;

import 'dart:convert';

import '../env/execution_env.dart';
import '../exceptions.dart';
import '../session/session_record.dart';
import '../session/session_repo.dart';
import '../session/session_storage.dart';
import 'claude_adapter.dart';
import 'foreign_session.dart';
import 'harness_adapter.dart';
import 'import_mapper.dart';
import 'omp_adapter.dart';

/// The adapter for [harness], or null when the harness is not implemented
/// yet (kimi/opencode pending their format spikes, GOAL AC7/K1).
HarnessAdapter? adapterFor(String harness) => switch (harness) {
  'omp' => OmpAdapter(),
  'claude' => ClaudeAdapter(),
  _ => null,
};

/// `--all` or `--session=<id|prefix>`.
class ImportSelector {
  const ImportSelector.all() : id = null;
  const ImportSelector.one(this.id);

  /// The foreign session id or unambiguous prefix; null = all.
  final String? id;

  /// Whether every discovered session is targeted.
  bool get isAll => id == null;
}

/// One import run's output: the printed lines and the process exit code
/// (GOAL exit table: 0 ok/already-imported, 2 store absent, 3 nothing
/// imported/unresolved/ambiguous).
final class ImportResult {
  const ImportResult({required this.exitCode, required this.lines});
  final int exitCode;
  final List<String> lines;
}

/// Imports the selected foreign sessions into the FA store.
///
/// Zero provider/model/key wiring — imported content cannot trigger a
/// model call during import (GOAL F8): every collaborator here is the
/// session repo, the adapter, and an output sink.
Future<ImportResult> runImport({
  required HarnessAdapter adapter,
  required FileSystem fs,
  required JsonlSessionRepo repo,
  required String cwd,
  required ImportSelector selector,
  required ImportLimits limits,
  required String homeDir,
  required String tempDir,
  void Function(String line)? onLine,
}) async {
  final lines = <String>[];
  void emit(String line) {
    lines.add(line);
    onLine?.call(line);
  }

  // Exit 2: the harness store itself is absent.
  final List<ForeignSessionSummary> summaries;
  try {
    summaries = await adapter.discover(
      fs: fs,
      cwd: cwd,
      homeDir: homeDir,
      tempDir: tempDir,
      limits: limits,
    );
  } on ForeignStoreAbsent catch (error) {
    emit('import: no ${adapter.id} store at ${error.root}');
    return ImportResult(exitCode: 2, lines: lines);
  }
  if (summaries.isEmpty) {
    emit('import: no ${adapter.id} sessions found for $cwd');
    return ImportResult(exitCode: 3, lines: lines);
  }

  final targeted = _resolveSelector(summaries, selector);
  if (targeted.isEmpty) {
    emit('import: no session matches "${selector.id}"');
    return ImportResult(exitCode: 3, lines: lines);
  }
  // Exact-id/prefix selectors must be unambiguous (GOAL F13). --all is
  // the explicit "every discovered session" request (AC2) — never
  // ambiguous, no matter how many sessions the store holds.
  if (!selector.isAll && targeted.length > 1) {
    emit(
      'import: "${selector.id}" is ambiguous — '
      '${targeted.map((s) => s.sourceId).join(', ')}',
    );
    return ImportResult(exitCode: 3, lines: lines);
  }

  final markers = await _importMarkers(repo, cwd);
  final batchSeen = <String>{};
  var imported = 0;
  var alreadyImported = 0;
  for (final summary in targeted) {
    final (one, already) = await _importSummary(
      adapter: adapter,
      fs: fs,
      repo: repo,
      cwd: cwd,
      summary: summary,
      limits: limits,
      homeDir: homeDir,
      batchSeen: batchSeen,
      markers: markers,
      emit: emit,
    );
    imported += one;
    alreadyImported += already;
  }

  if (imported == 0 && alreadyImported == targeted.length) {
    return ImportResult(exitCode: 0, lines: lines);
  }
  if (imported == 0) {
    return ImportResult(exitCode: 3, lines: lines);
  }
  return ImportResult(exitCode: 0, lines: lines);
}

/// Imports one targeted session, emitting the skip/import lines. Returns
/// `(imported, alreadyImported)` tallies for the batch roll-up: two store
/// files can carry the same header id (GOAL E9b) — the first occurrence
/// imports once, the rest count like the E6 skip case. An existing
/// incomplete FA file (kill mid-import) is replaced on retry (GOAL E14);
/// foreign sources stay untouched.
Future<(int, int)> _importSummary({
  required HarnessAdapter adapter,
  required FileSystem fs,
  required JsonlSessionRepo repo,
  required String cwd,
  required ForeignSessionSummary summary,
  required ImportLimits limits,
  required String homeDir,
  required Set<String> batchSeen,
  required Map<String, SessionMetadata> markers,
  required void Function(String line) emit,
}) async {
  if (!batchSeen.add(summary.sourceId)) {
    emit('skipped ${summary.sourceId} (duplicate in store)');
    return (0, 1);
  }
  final existing = markers[summary.sourceId];
  if (existing != null) {
    if (await _isComplete(repo, existing, adapter.id)) {
      emit('skipped ${summary.sourceId} (already imported)');
      return (0, 1);
    }
    await repo.delete(existing, actor: 'import');
  }
  try {
    final faId = await _importOne(
      adapter: adapter,
      fs: fs,
      repo: repo,
      cwd: cwd,
      summary: summary,
      limits: limits,
      homeDir: homeDir,
    );
    emit(faId.$2);
    return (1, 0);
  } on ForeignFileError catch (error) {
    emit('warning: skipped ${summary.sourceId}: ${error.message}');
  } on SessionException catch (error) {
    emit('warning: skipped ${summary.sourceId}: ${error.message}');
  }
  return (0, 0);
}

/// Exact id, else unambiguous prefix (GOAL F13). Empty = no match;
/// length > 1 = ambiguous (caller exits 3 listing the matches).
List<ForeignSessionSummary> _resolveSelector(
  List<ForeignSessionSummary> summaries,
  ImportSelector selector,
) {
  if (selector.isAll) return summaries;
  final wanted = selector.id!.trim();
  final exact = summaries.where((s) => s.sourceId == wanted).toList();
  if (exact.isNotEmpty) return exact;
  return summaries.where((s) => s.sourceId.startsWith(wanted)).toList();
}

/// sourceId → FA metadata for same-folder sessions already carrying the
/// import marker (GOAL F12).
Future<Map<String, SessionMetadata>> _importMarkers(
  JsonlSessionRepo repo,
  String cwd,
) async {
  final markers = <String, SessionMetadata>{};
  for (final metadata in await repo.list(cwd: cwd)) {
    final marker = metadata.metadata?['importedFrom'];
    if (marker is! Map<String, dynamic>) continue;
    final sourceId = marker['sourceId'];
    if (sourceId is String && sourceId.isNotEmpty) {
      markers[sourceId] = metadata;
    }
  }
  return markers;
}

/// The completion bit: the runner appends `import.<harness>.complete` as
/// the FINAL record; its absence marks a kill-mid-import file (GOAL E14).
Future<bool> _isComplete(
  JsonlSessionRepo repo,
  SessionMetadata metadata,
  String harness,
) async {
  try {
    final session = await repo.open(metadata);
    for (final record in await session.getEntries()) {
      if (record is CustomRecord &&
          record.customType == 'import.$harness.complete') {
        return true;
      }
    }
    return false;
  } on SessionException {
    return false;
  }
}

/// Parses, maps, and writes ONE session. Returns the FA id and the
/// summary line (ids and counts only — never file content, GOAL AC11).
Future<(String, String)> _importOne({
  required HarnessAdapter adapter,
  required FileSystem fs,
  required JsonlSessionRepo repo,
  required String cwd,
  required ForeignSessionSummary summary,
  required ImportLimits limits,
  required String homeDir,
}) async {
  final parse = await adapter.read(
    fs: fs,
    summary: summary,
    homeDir: homeDir,
    limits: limits,
  );
  final mapped = mapForeignSession(parse, adapter.id);
  final session = await repo.create(
    JsonlSessionCreateOptions(
      cwd: cwd,
      metadata: {
        'importedFrom': {
          'harness': adapter.id,
          'sourcePath': summary.sourcePath,
          'sourceId': summary.sourceId,
          'recordCount': mapped.items.length,
        },
      },
    ),
  );
  for (final item in mapped.items) {
    switch (item.planned) {
      case PlannedName(:final name):
        await session.appendSessionName(name);
      case PlannedMessage(:final message):
        await session.appendMessage(message);
      case PlannedModelChange(:final provider, :final modelId):
        await session.appendModelChange(provider: provider, modelId: modelId);
      case PlannedThinkingLevel(:final level):
        await session.appendThinkingLevelChange(level);
      case PlannedCompaction(summary: final compactionSummary):
        await session.appendCompaction(
          summary: compactionSummary,
          firstKeptEntryId: '',
          tokensBefore: 0,
        );
      case PlannedCustom(:final customType, :final data):
        await session.appendCustomEntry(customType: customType, data: data);
      case PlannedCustomMessage(
        :final customType,
        :final content,
        :final display,
        :final details,
      ):
        await session.appendCustomMessageEntry(
          customType: customType,
          content: content,
          display: display,
          details: details,
        );
    }
  }
  await session.appendCustomEntry(
    customType: 'import.${adapter.id}.complete',
    data: {'recordCount': mapped.items.length},
  );
  final metadata = await session.getMetadata();
  final details = <String>[
    if (mapped.skippedBlocks > 0) 'skipped-blocks ${mapped.skippedBlocks}',
    for (final entry in mapped.droppedFields.entries)
      '${entry.key}=${entry.value}',
  ];
  final line =
      'imported ${summary.sourceId} → ${metadata.id} '
      '(${mapped.items.length} records, skipped ${mapped.skippedRecords})'
      '${details.isEmpty ? '' : ' [${details.join(', ')}]'}';
  return (metadata.id, line);
}

/// Fills a discovery summary's previews and bounded search text (the
/// `/import` picker's rows + keyword index, GOAL F10/F11) by streaming the
/// file read-only. Records are parsed once and discarded.
Future<ForeignSessionSummary> describeForeignSession({
  required HarnessAdapter adapter,
  required FileSystem fs,
  required ForeignSessionSummary summary,
  required ImportLimits limits,
  required String homeDir,
}) async {
  final parse = await adapter.read(
    fs: fs,
    summary: summary,
    homeDir: homeDir,
    limits: limits,
  );
  String? first;
  String? last;
  final search = StringBuffer();
  void note(List<ForeignContent> contents) {
    final text = foreignContentText(contents);
    if (text.isEmpty) return;
    first ??= previewLine(text);
    last = previewLine(text);
    if (search.length < limits.searchIndexBytes) {
      search
        ..write(' ')
        ..write(
          text.length > limits.searchIndexBytes
              ? text.substring(0, limits.searchIndexBytes)
              : text,
        );
    }
  }

  for (final record in parse.records) {
    if (record is ForeignMessage) note(record.contents);
  }
  var searchText = search.toString();
  // The cap is named bytes — clip on the UTF-8 boundary (a UTF-16
  // .length cap overruns it ~2x for CJK-heavy sessions).
  final encodedIndex = utf8.encode(searchText);
  if (encodedIndex.length > limits.searchIndexBytes) {
    searchText = utf8.decode(
      encodedIndex.sublist(0, limits.searchIndexBytes),
      allowMalformed: true,
    );
  }
  return ForeignSessionSummary(
    harness: summary.harness,
    sourceId: summary.sourceId,
    sourcePath: summary.sourcePath,
    sizeBytes: summary.sizeBytes,
    headerCwd: summary.headerCwd,
    title: summary.title,
    titleSource: summary.titleSource,
    firstPreview: first ?? '-',
    lastPreview: last ?? '-',
    searchText: searchText,
    mtimeMs: summary.mtimeMs,
  );
}
