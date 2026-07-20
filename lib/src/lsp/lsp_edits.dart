/// Applying LSP workspace edits to the workspace through the
/// [ExecutionEnv] (a reduced port of oh-my-pi
/// `packages/coding-agent/src/lsp/edits.ts`).
///
/// Text edits apply bottom-to-top so line/character indices stay valid;
/// overlapping ranges are rejected. Application is all-or-nothing across
/// files (the hashline patcher's atomicity rule): every file's edits are
/// overlap-validated, version-guarded, and applied in memory BEFORE any
/// write hits the env, so a conflict leaves the workspace untouched.
///
/// Reductions from omp: resource operations (`create`/`rename`/`delete`
/// document changes) are not applied — the Dart analysis server's rename
/// answers carry text edits only (barrel files, imports).
library;

import '../env/execution_env.dart';
import 'lsp_types.dart';

int _comparePosition(LspPosition a, LspPosition b) =>
    a.line == b.line ? a.character - b.character : a.line - b.line;

bool _positionsEqual(LspPosition a, LspPosition b) =>
    a.line == b.line && a.character == b.character;

bool _isEmptyRange(LspRange range) => _positionsEqual(range.start, range.end);

bool _rangesEqual(LspRange a, LspRange b) =>
    _positionsEqual(a.start, b.start) && _positionsEqual(a.end, b.end);

/// Sorts [edits] bottom-to-top for in-place application and rejects
/// overlaps (omp's `sortAndValidateTextEdits`).
///
/// Equal start positions tiebreak by original array index descending so
/// that, applied bottom-up, inserts at the same position land in array
/// order (per the LSP spec the array order defines the result order).
/// Byte-identical non-empty range edits are idempotent, so duplicate server
/// output is collapsed before overlap validation. Throws [StateError] on
/// overlap.
List<LspTextEdit> sortAndValidateTextEdits(List<LspTextEdit> edits) {
  final indexed = <(LspTextEdit, int)>[
    for (var i = 0; i < edits.length; i++) (edits[i], i),
  ];
  indexed.sort((a, b) {
    final startA = a.$1.range.start;
    final startB = b.$1.range.start;
    if (startA.line != startB.line) return startB.line - startA.line;
    if (startA.character != startB.character) {
      return startB.character - startA.character;
    }
    return b.$2 - a.$2;
  });
  final unique = <LspTextEdit>[];
  for (final (edit, _) in indexed) {
    final prev = unique.isEmpty ? null : unique.last;
    if (prev != null &&
        !_isEmptyRange(edit.range) &&
        _rangesEqual(prev.range, edit.range) &&
        prev.newText == edit.newText) {
      continue;
    }
    unique.add(edit);
  }

  // In reverse-sorted order, each edit's start must be >= the next edit's
  // end, or the edits would clobber each other once applied bottom-up.
  for (var i = 0; i < unique.length - 1; i++) {
    final later = unique[i].range;
    final earlier = unique[i + 1].range;
    if (_comparePosition(earlier.end, later.start) > 0) {
      throw StateError(
        'overlapping LSP edits: ${earlier.format()} conflicts with '
        '${later.format()}; LSP produced inconsistent edits',
      );
    }
  }
  return unique;
}

/// Applies [edits] to [content] in-memory, bottom-to-top (omp's
/// `applyTextEditsToString`). Call [sortAndValidateTextEdits] first (this
/// function re-sorts defensively).
String applyTextEditsToString(String content, List<LspTextEdit> edits) {
  final lines = content.split('\n');
  final sorted = sortAndValidateTextEdits(edits);
  for (final edit in sorted) {
    final start = edit.range.start;
    final end = edit.range.end;
    if (start.line >= lines.length || end.line >= lines.length) {
      throw StateError(
        'LSP edit range ${edit.range.format()} is out of bounds for a '
        '${lines.length}-line file',
      );
    }
    if (start.line == end.line) {
      final line = lines[start.line];
      lines[start.line] =
          line.substring(0, start.character) +
          edit.newText +
          line.substring(end.character);
    } else {
      final startLine = lines[start.line];
      final endLine = lines[end.line];
      final merged =
          startLine.substring(0, start.character) +
          edit.newText +
          endLine.substring(end.character);
      lines.replaceRange(start.line, end.line + 1, merged.split('\n'));
    }
  }
  return lines.join('\n');
}

/// One applied change, for the tool's report (omp's applied-change lines).
final class LspAppliedChange {
  /// Creates an [LspAppliedChange].
  const LspAppliedChange({required this.path, required this.editCount});

  /// The file that was written.
  final String path;

  /// How many text edits were applied to it.
  final int editCount;

  /// omp's `Applied N edit(s) to <path>` line (path relative to [cwd]).
  String format(String cwd) =>
      'Applied $editCount edit(s) to ${formatPathRelativeToCwd(path, cwd)}';
}

/// Applies [edit] through [env] and returns the per-file changes.
///
/// Atomicity: edits for EVERY file are validated (overlap + bounds via a
/// dry-run on the current content) and the version guard is checked before
/// the first write; a failure leaves the workspace untouched.
///
/// Version guard: when the server's `documentChanges` advertised a
/// non-null `textDocument.version` for a URI and [openFileVersions] tracks
/// that URI at a different version, the edit is stale (the document moved
/// since the server computed it) and application is rejected up front.
Future<List<LspAppliedChange>> applyWorkspaceEdit(
  ExecutionEnv env,
  LspWorkspaceEdit edit, {
  Map<String, int> openFileVersions = const {},
}) async {
  // Version guard (up front, before any read or write).
  for (final entry in edit.documentVersions.entries) {
    final serverVersion = entry.value;
    if (serverVersion == null) continue;
    final tracked = openFileVersions[entry.key];
    if (tracked != null && tracked != serverVersion) {
      throw StateError(
        'stale LSP edit for ${formatPathRelativeToCwd(uriToFile(entry.key), env.cwd)}: '
        'server computed it at document version $serverVersion but the '
        'document is now at version $tracked; re-run the request',
      );
    }
  }

  // Phase 1: validate and compute new contents without writing anything.
  final planned = <String, String>{};
  final counts = <String, int>{};
  for (final entry in edit.textEdits.entries) {
    final edits = entry.value;
    if (edits.isEmpty) continue;
    final path = uriToFile(entry.key);
    final read = await env.readTextFile(path);
    if (read.isErr) {
      throw StateError('cannot apply LSP edits: ${read.errorOrNull}');
    }
    planned[path] = applyTextEditsToString(read.valueOrNull!, edits);
    counts[path] = edits.length;
  }

  // Phase 2: write.
  final applied = <LspAppliedChange>[];
  for (final entry in planned.entries) {
    final write = await env.writeFile(entry.key, entry.value);
    if (write.isErr) {
      throw StateError('cannot apply LSP edits: ${write.errorOrNull}');
    }
    applied.add(
      LspAppliedChange(path: entry.key, editCount: counts[entry.key]!),
    );
  }
  return applied;
}
