/// Archive inner-path reads for the `read` tool (omp's `#readArchive` / `#readArchiveDirectory`): candidate probing, member resolution with the root-selector fallback, entry text rendering, and directory listings. Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// read: archive inner paths (omp's #readArchive / #readArchiveDirectory)
// ---------------------------------------------------------------------------

/// Probes [rawPath] for archive targets (`archive.zip:inner/…`, also `.tar`,
/// `.tar.gz`/`.tgz`) and reads the member or listing when a candidate names
/// an existing archive file. Returns null when no candidate resolves — the
/// caller falls through to a plain file read.
Future<ToolExecutionResult?> _tryReadArchive(
  ExecutionEnv env,
  String rawPath,
  CancelToken? cancelToken,
) async {
  final candidates = parseArchivePathCandidates(rawPath);
  for (final candidate in candidates) {
    final info = await env.fileInfo(candidate.archivePath);
    if (info.isErr) continue;
    if (info.valueOrNull!.kind != FileKind.file) continue;
    return _readArchiveCandidate(env, rawPath, candidate, cancelToken);
  }
  return null;
}

/// Reads the archive named by [candidate]: resolves the member (or the
/// archive root), then renders the directory listing or the member's text.
Future<ToolExecutionResult> _readArchiveCandidate(
  ExecutionEnv env,
  String rawPath,
  ArchivePathCandidate candidate,
  CancelToken? cancelToken,
) async {
  final bytesRead = await env.readBinaryFile(candidate.archivePath);
  if (bytesRead.isErr) throw StateError('${bytesRead.errorOrNull}');
  cancelToken?.throwIfCancelled();
  final format = archiveFormatFromPath(candidate.archivePath)!;
  final archive = ArchiveReader.decode(bytesRead.valueOrNull!, format);
  cancelToken?.throwIfCancelled();

  final (:node, :archiveSubPath, :sel) = _resolveArchiveMember(
    archive,
    rawPath,
    candidate.subPath,
  );

  if (node.isDirectory) {
    if (sel is ReadSelectorLines && sel.ranges.length > 1) {
      throw StateError(
        'Multi-range line selectors are not supported for archive '
        'directory listings.',
      );
    }
    final (:offset, :limit) = _selToOffsetLimit(sel);
    return _readArchiveDirectory(archive, archiveSubPath, offset, limit);
  }

  final entryBytes = archive.readFileBytes(archiveSubPath);
  cancelToken?.throwIfCancelled();
  return _readArchiveEntryText(node, entryBytes, sel);
}

/// Resolves [subPath] against [archive] (omp's member-then-root-selector
/// fallback): `archive.zip:inner.txt:50-60` peels the selector off the
/// member path, while `archive.zip:500` / `archive.zip:raw` re-reads the
/// whole subPath as a selector on the archive root when no member matches.
/// Member names take precedence over the root-selector interpretation.
/// Throws when the member (or root) does not exist.
({ArchiveNode node, String archiveSubPath, ReadSelector sel})
_resolveArchiveMember(ArchiveReader archive, String rawPath, String subPath) {
  // `archive.zip:inner.txt:50-60`: peel the selector off the member path.
  final subSplit = splitPathAndSel(subPath);
  var sel = parseSel(subSplit.sel);
  var archiveSubPath = subSplit.path;
  var node = archive.getNode(archiveSubPath);
  if (node == null && archiveSubPath.isNotEmpty) {
    // `archive.zip:500` / `archive.zip:raw`: the whole subPath is a
    // selector on the archive root, not a member name. Member names take
    // precedence (the getNode above); fall back to root + selector (omp).
    final wholeSel = parseSel(archiveSubPath);
    if (wholeSel is! ReadSelectorNone) {
      node = archive.getNode('');
      archiveSubPath = '';
      sel = wholeSel;
    }
  }
  if (node == null) {
    throw StateError("Path '$rawPath' not found inside archive");
  }
  return (node: node, archiveSubPath: archiveSubPath, sel: sel);
}

/// Renders an archive member's text (omp's immutable display mode): archive
/// members are immutable — there is no edit path for bytes inside an
/// archive, and a hashline tag keyed to the archive file would invite (and
/// fail) edits — so the member renders without hashline anchors. Selectors
/// still apply; a binary entry yields a note instead of bytes.
ToolExecutionResult _readArchiveEntryText(
  ArchiveNode node,
  Uint8List entryBytes,
  ReadSelector sel,
) {
  final text = decodeUtf8Text(entryBytes);
  if (text == null) {
    return ToolExecutionResult.text(
      "[Cannot read binary archive entry '${node.path}' "
      '(${formatToolSize(entryBytes.length)})]',
    );
  }

  final entryLines = text.split('\n');
  final raw = isRawSelector(sel);
  if (sel is ReadSelectorLines) {
    if (sel.ranges.length > 1) {
      return ToolExecutionResult.text(
        _formatMultiRange(
          allLines: entryLines,
          ranges: sel.ranges,
          raw: raw,
          hashlineMode: false,
          entityLabel: 'archive entry',
        ).text,
      );
    }
    final range = sel.ranges.first;
    if (range.startLine > entryLines.length) {
      return ToolExecutionResult.text(
        'Line ${range.startLine} is beyond end of archive entry '
        '(${entryLines.length} lines total). Use :1 to read from the '
        'start, or :${entryLines.length} to read the last line.',
      );
    }
    return ToolExecutionResult.text(
      _selectAndTruncate(
        allLines: entryLines,
        entityLabel: 'archive entry',
        offset: range.startLine,
        limit: range.endLine == null
            ? null
            : range.endLine! - range.startLine + 1,
        raw: raw,
      ).text,
    );
  }
  return ToolExecutionResult.text(
    _selectAndTruncate(
      allLines: entryLines,
      entityLabel: 'archive entry',
      raw: raw,
    ).text,
  );
}

/// Renders an archive directory listing (omp's `#readArchiveDirectory`):
/// immediate children, directories suffixed with `/`, files with their size,
/// capped at [limit] entries (default [defaultArchiveListLimit]) and the
/// shared byte cap. A selector offset starts the listing at the Nth entry
/// (`a.zip:dir:50`).
ToolExecutionResult _readArchiveDirectory(
  ArchiveReader archive,
  String subPath,
  int? offset,
  int? limit,
) {
  final allEntries = archive.listDirectory(subPath);
  final entries = offset != null && offset > 1
      ? allEntries.skip(offset - 1)
      : allEntries;
  final effectiveLimit = limit ?? defaultArchiveListLimit;
  final results = <String>[];
  for (final entry in entries) {
    if (results.length >= effectiveLimit) break;
    if (entry.isDirectory) {
      results.add('${entry.name}/');
    } else {
      results.add(
        entry.size > 0
            ? '${entry.name} (${formatToolSize(entry.size)})'
            : entry.name,
      );
    }
  }
  final output = results.isEmpty
      ? '(empty archive directory)'
      : results.join('\n');
  // Byte truncation only; the entry count is already capped above (omp sets
  // the list-limit metadata without a text notice).
  return ToolExecutionResult.text(
    _truncateHead(output, maxLines: _unboundedMaxLines).content,
  );
}
