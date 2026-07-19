/// Apply a parsed list of [HashlineEdit]s to a text body and return the
/// post-edit text plus diagnostics. Pure function: no I/O, no mutation of
/// the input.
///
/// Ported from oh-my-pi `packages/hashline/src/apply.ts` (`applyEdits`).
/// Divergence: omp's two model-leniency repair passes —
/// `repairReplacementBoundaries` (boundary-echo / delimiter-balance repair)
/// and `repairAfterInsertLandings` (indentation-claimed landing shifts) —
/// are NOT ported; edits apply literally as authored. The deterministic core
/// semantics are identical: phantom trailing-line handling, line-bounds
/// validation, per-line buckets applied bottom-up, bof/eof insertion, and
/// first-changed-line tracking.
library;

import 'messages.dart';
import 'types.dart';

typedef _IndexedEdit = ({HashlineEdit edit, int idx});

int _trailingPhantomLine(List<String> fileLines) {
  // `split('\n')` on a newline-terminated file yields a trailing '' sentinel.
  // It is addressable for inserts (append-past-end), but it is not real
  // content. Deleting it only strips the file's final newline, so ignore
  // delete edits that land there; inclusive ranges ending at EOF then do the
  // intended thing and delete through the last concrete line.
  return fileLines.length > 1 && fileLines[fileLines.length - 1].isEmpty
      ? fileLines.length
      : 0;
}

List<HashlineEdit> _dropTrailingPhantomDeletes(
  List<HashlineEdit> edits,
  List<String> fileLines,
) {
  final phantomLine = _trailingPhantomLine(fileLines);
  if (phantomLine == 0) return edits;
  return edits
      .where(
        (edit) => edit is! HashlineDelete || edit.anchor.line != phantomLine,
      )
      .toList();
}

/// Verifies every anchored edit points at an existing line. File-version
/// binding is checked once per section via the header hash before this runs.
void _validateLineBounds(List<HashlineEdit> edits, List<String> fileLines) {
  for (final edit in edits) {
    final anchors = switch (edit) {
      HashlineDelete(:final anchor) => [anchor],
      HashlineInsert(:final cursor) => switch (cursor) {
        HashlineCursorBefore(:final anchor) => [anchor],
        HashlineCursorAfter(:final anchor) => [anchor],
        _ => const <HashlineAnchor>[],
      },
    };
    for (final anchor in anchors) {
      if (anchor.line < 1 || anchor.line > fileLines.length) {
        throw HashlineFormatException(
          'Line ${anchor.line} does not exist (file has '
          '${fileLines.length} lines)',
        );
      }
    }
  }
}

void _insertAtStart(List<String> fileLines, List<String> lines) {
  if (lines.isEmpty) return;
  if (fileLines.length == 1 && fileLines[0].isEmpty) {
    fileLines.replaceRange(0, 1, lines);
    return;
  }
  fileLines.insertAll(0, lines);
}

int? _insertAtEnd(List<String> fileLines, List<String> lines) {
  if (lines.isEmpty) return null;
  if (fileLines.length == 1 && fileLines[0].isEmpty) {
    fileLines.replaceRange(0, 1, lines);
    return 1;
  }
  final hasTrailingNewline =
      fileLines.isNotEmpty && fileLines[fileLines.length - 1].isEmpty;
  final insertIndex = hasTrailingNewline
      ? fileLines.length - 1
      : fileLines.length;
  fileLines.insertAll(insertIndex, lines);
  return insertIndex + 1;
}

Map<int, List<_IndexedEdit>> _bucketAnchorEditsByLine(
  List<_IndexedEdit> edits,
) {
  final byLine = <int, List<_IndexedEdit>>{};
  for (final entry in edits) {
    final edit = entry.edit;
    final line = switch (edit) {
      HashlineDelete(:final anchor) => anchor.line,
      HashlineInsert(:final cursor) => switch (cursor) {
        HashlineCursorBefore(:final anchor) => anchor.line,
        HashlineCursorAfter(:final anchor) => anchor.line,
        _ => 0,
      },
    };
    byLine.putIfAbsent(line, () => []).add(entry);
  }
  return byLine;
}

/// Applies [edits] to [text] and returns the post-edit result. Throws
/// [HashlineFormatException] if an anchor is out of bounds.
HashlineApplyResult applyHashlineEdits(String text, List<HashlineEdit> edits) {
  if (edits.isEmpty) {
    return HashlineApplyResult(text: text);
  }

  final fileLines = text.split('\n');
  int? firstChangedLine;
  void trackFirstChanged(int line) {
    if (firstChangedLine == null || line < firstChangedLine!) {
      firstChangedLine = line;
    }
  }

  final targetEdits = _dropTrailingPhantomDeletes(edits, fileLines);
  _validateLineBounds(targetEdits, fileLines);

  // Partition edits into bof, eof, and anchor-targeted buckets.
  final bofLines = <String>[];
  final eofLines = <String>[];
  final anchorEdits = <_IndexedEdit>[];
  for (var idx = 0; idx < targetEdits.length; idx++) {
    final edit = targetEdits[idx];
    if (edit is HashlineInsert && edit.cursor is HashlineCursorBof) {
      bofLines.add(edit.text);
    } else if (edit is HashlineInsert && edit.cursor is HashlineCursorEof) {
      eofLines.add(edit.text);
    } else {
      anchorEdits.add((edit: edit, idx: idx));
    }
  }

  // Apply per-line buckets bottom-up so earlier indices stay valid.
  final byLine = _bucketAnchorEditsByLine(anchorEdits);
  final sortedLines = byLine.keys.toList()..sort((a, b) => b.compareTo(a));
  for (final line in sortedLines) {
    final bucket = byLine[line]!;
    bucket.sort((a, b) => a.idx.compareTo(b.idx));

    final index = line - 1;
    final currentLine = index < fileLines.length ? fileLines[index] : '';
    final beforeInsertLines = <String>[];
    final afterInsertLines = <String>[];
    final replacementLines = <String>[];
    var deleteLine = false;

    for (final entry in bucket) {
      final edit = entry.edit;
      if (edit is HashlineInsert && edit.replacement) {
        replacementLines.add(edit.text);
      } else if (edit is HashlineInsert && edit.cursor is HashlineCursorAfter) {
        afterInsertLines.add(edit.text);
      } else if (edit is HashlineInsert) {
        beforeInsertLines.add(edit.text);
      } else if (edit is HashlineDelete) {
        deleteLine = true;
      }
    }
    if (beforeInsertLines.isEmpty &&
        replacementLines.isEmpty &&
        afterInsertLines.isEmpty &&
        !deleteLine) {
      continue;
    }

    final replacement = deleteLine
        ? [...beforeInsertLines, ...replacementLines, ...afterInsertLines]
        : [
            ...beforeInsertLines,
            ...replacementLines,
            currentLine,
            ...afterInsertLines,
          ];
    fileLines.replaceRange(index, index + 1, replacement);
    trackFirstChanged(line);
  }

  if (bofLines.isNotEmpty) {
    _insertAtStart(fileLines, bofLines);
    trackFirstChanged(1);
  }
  final eofChangedLine = _insertAtEnd(fileLines, eofLines);
  if (eofChangedLine != null) trackFirstChanged(eofChangedLine);

  return HashlineApplyResult(
    text: fileLines.join('\n'),
    firstChangedLine: firstChangedLine,
  );
}
