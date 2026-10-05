/// Session-ledger repair (gh-1073): rewrites a bloated session JSONL,
/// dropping or superseding the append-only `custom` ledger records that
/// grew a month-long session to 12.4 GiB — without touching the
/// conversation itself (messages, custom_message records, the tree
/// structure) — so the session resumes.
///
/// The ledger records are safe to drop BY CONSTRUCTION:
/// - `model_request_summary` / `trajectory_prompt_blob` /
///   `trajectory_manifest_blob` / `trajectory_wire_dump` — Request-tab
///   replay detail; the transcript renders without them.
/// - `shell_job_registry` / `subagent_registry` — latest-snapshot-wins
///   registries; only the newest snapshot needs to survive for resume-time
///   rehydration.
///
/// Unknown custom types and unparseable lines are KEPT (repair is
/// conservative — it deletes only what it provably understands). Pure
/// Dart over the [FileSystem] abstraction; range reads make the rewrite
/// linear-time and bounded-memory even on a multi-GiB file.
library;

import 'dart:convert';

import 'env/execution_env.dart';
import 'session_line_scanner.dart';
import 'session/session_storage.dart' show shallowCustomHeader;

/// `custom` ledger types dropped entirely: replay-only detail (the
/// Request tab), never projected into context, never read on resume.
const Set<String> repairDropCustomTypes = {
  'model_request_summary',
  'trajectory_prompt_blob',
  'trajectory_manifest_blob',
  'trajectory_wire_dump',
};

/// `custom` ledger types where the LATEST record supersedes all earlier
/// ones: registry snapshots read only through their last occurrence.
const Set<String> repairKeepLatestCustomTypes = {
  'shell_job_registry',
  'subagent_registry',
};

/// Severity of a [SessionRepairException].
enum SessionRepairErrorCode {
  /// The session file does not exist.
  notFound,

  /// The filesystem cannot stream or rename (repair needs both).
  unsupported,

  /// Any other failure.
  unknown,
}

/// Repair failure with a stable code for host surfaces.
final class SessionRepairException implements Exception {
  const SessionRepairException(this.message, {required this.code});

  final String message;
  final SessionRepairErrorCode code;

  @override
  String toString() => 'SessionRepairException(${code.name}): $message';
}

/// What one repair pass saw and changed.
final class SessionRepairReport {
  const SessionRepairReport({
    required this.path,
    required this.recordsRead,
    required this.recordsKept,
    required this.droppedByType,
    required this.keptLatestByType,
    required this.bytesBefore,
    required this.bytesAfter,
    required this.backupPath,
    required this.dryRun,
    required this.untouchedSegments,
  });

  /// The session file this pass targeted.
  final String path;

  /// Total non-blank lines below the header.
  final int recordsRead;

  /// Records kept in the rewritten file (header excluded) — counted per
  /// line, never derived from merged byte-span counts.
  final int recordsKept;

  /// Dropped records per custom type — full ledger drops AND superseded
  /// registry snapshots.
  final Map<String, int> droppedByType;

  /// Latest snapshots KEPT per superseding registry type.
  final Map<String, int> keptLatestByType;

  /// Session file size before (the backup's size after).
  final int bytesBefore;

  /// Session file size after (`bytesBefore` when [dryRun]).
  final int bytesAfter;

  /// Where the original was preserved (`.bak` suffix).
  final String backupPath;

  /// Whether this pass only counted.
  final bool dryRun;

  /// Rotated `<file>.part-NN` segments (gh-1077) found next to [path] that
  /// this pass did NOT touch — they still hold their ledger records, so
  /// `bytesBefore`/`bytesAfter` alone overstate the on-disk reduction
  /// when this is non-zero.
  final int untouchedSegments;

  /// Human-readable summary lines for a CLI report.
  List<String> summaryLines() {
    final droppedTotal = droppedByType.values.fold<int>(0, (a, b) => a + b);
    final keptLatestTotal = keptLatestByType.values.fold<int>(
      0,
      (a, b) => a + b,
    );
    return [
      '${dryRun ? 'would repair' : 'repaired'} $path: '
          '$recordsRead records read, $recordsKept kept',
      if (droppedTotal > 0)
        'dropped $droppedTotal ledger records: ${_counts(droppedByType)}',
      if (keptLatestTotal > 0)
        'kept the latest snapshot of: ${_counts(keptLatestByType)}',
      if (untouchedSegments > 0)
        '$untouchedSegments rotated segment(s) untouched — ledger '
        'records remain in ${path.split('/').last}.part-*',
      '${_bytes(bytesBefore)} → ${_bytes(bytesAfter)}'
          '${dryRun ? '' : ' · original kept at $backupPath'}',
    ];
  }

  static String _counts(Map<String, int> counts) => [
    for (final entry in counts.entries) '${entry.key}×${entry.value}',
  ].join(', ');

  static String _bytes(int bytes) {
    if (bytes >= (1 << 30)) {
      return '${(bytes / (1 << 30)).toStringAsFixed(2)} GiB';
    }
    if (bytes >= (1 << 20)) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    }
    if (bytes >= (1 << 10)) return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

/// The `customType` of a `custom` record line, decoded from its bounded
/// header (`shallowCustomHeader` — canonical writer order, payload
/// excluded). Null when the line is not a sniffable custom record — the
/// caller keeps those verbatim.
String? _sniffCustomType(String line) {
  if (!line.startsWith('{"type":"custom"')) return null;
  final header = shallowCustomHeader(line);
  if (header == null) return null;
  try {
    final decoded = jsonDecode(header);
    if (decoded is! Map<String, dynamic>) return null;
    final type = decoded['customType'];
    return type is String ? type : null;
  } on Object {
    return null;
  }
}

/// Rewrites the session file at [path] with the ledger `custom` records
/// dropped ([repairDropCustomTypes]) or superseded by their latest
/// snapshot ([repairKeepLatestCustomTypes]). Everything else — messages,
/// unknown customs, unparseable lines — is copied verbatim. The original
/// is preserved at `<path>.bak` (renamed, not copied) and the repaired
/// content takes the original's place atomically.
///
/// [dryRun] counts without touching anything. Requires a
/// [RangedReadFileSystem] (bounded streaming) and a
/// [RenamableFileSystem] (atomic swap) — anything else fails with
/// [SessionRepairErrorCode.unsupported] rather than half-applying.
Future<SessionRepairReport> repairSessionLedgers(
  FileSystem fs,
  String path, {
  bool dryRun = false,
  Set<String>? dropTypes,
  Set<String>? keepLatestTypes,
}) async {
  final drops = dropTypes ?? repairDropCustomTypes;
  final keepLatest = keepLatestTypes ?? repairKeepLatestCustomTypes;
  final Object maybeRanged = fs;
  final ranged = maybeRanged is RangedReadFileSystem ? maybeRanged : null;
  final Object maybeRenamable = fs;
  final renamable =
      maybeRenamable is RenamableFileSystem ? maybeRenamable : null;
  if (ranged == null || renamable == null) {
    throw SessionRepairException(
      'session repair needs byte-range reads and an atomic rename; this '
      'filesystem supports neither — copy the file to a local filesystem '
      'and repair it there',
      code: SessionRepairErrorCode.unsupported,
    );
  }
  final stat = await fs.fileInfo(path);
  if (stat.isErr) {
    final code = stat.errorOrNull!.code == FileErrorCode.notFound
        ? SessionRepairErrorCode.notFound
        : SessionRepairErrorCode.unknown;
    throw SessionRepairException(
      'cannot stat session file $path: ${stat.errorOrNull!.message}',
      code: code,
    );
  }
  final bytesBefore = stat.valueOrNull!.size;

  // Rotated segment siblings (gh-1077: `<file>.part-NN` holds the records
  // rotated out of the primary). Repair rewrites ONLY the primary — the
  // count goes into the report so the bytesBefore/bytesAfter line cannot
  // overstate the on-disk reduction. A listing hiccup must not fail the
  // repair: the note degrades to "parts unknown".
  final untouchedSegments = await _countPartSiblings(fs, path);

  // Pass 1: classify every line by byte span. Nothing is decoded whole —
  // a 12 GiB file scans in bounded chunks.
  final headerSpan = <(int, int)>[];
  final keptSpans = <(int, int)>[];
  final latestByType = <String, (int, int)>{};
  final droppedByType = <String, int>{};
  final keptLatestCounts = <String, int>{};
  var recordsRead = 0;
  // Records kept, counted per LINE — never derived from keptSpans.length,
  // which is the merged SPAN count (contiguous runs coalesce into one
  // span): the report must say how many records survive, or a reader
  // doing recordsRead - recordsKept infers phantom drops.
  var keptRecords = 0;
  var first = true;
  await SessionLineScanner(fs: fs, path: path).scan((line) async {
    if (first) {
      first = false;
      // Repair refuses to produce an unopenable file: line 1 must parse
      // as a session header. A torn creation-write otherwise survives
      // "repair" byte-identically broken and the next open fails the
      // same way — exactly when the user reached for repair.
      _ensureRepairableHeader(line.text, path);
      headerSpan.add((line.start, line.end));
      return;
    }
    if (line.text.trim().isEmpty) return;
    recordsRead++;
    final customType = _sniffCustomType(line.text);
    final span = (line.start, line.end);
    if (customType != null && drops.contains(customType)) {
      droppedByType[customType] = (droppedByType[customType] ?? 0) + 1;
      return;
    }
    if (customType != null && keepLatest.contains(customType)) {
      if (latestByType.containsKey(customType)) {
        droppedByType[customType] = (droppedByType[customType] ?? 0) + 1;
      } else {
        keptLatestCounts[customType] = 1;
      }
      latestByType[customType] = span;
      return;
    }
    keptRecords++;
    _appendSpan(keptSpans, span);
  }, fileSize: bytesBefore);

  // The LATEST snapshot of each keep-latest type joins the kept spans, in
  // file position order — one record each.
  keptSpans.addAll(latestByType.values);
  keptSpans.sort((a, b) => a.$1.compareTo(b.$1));
  final recordsKept = keptRecords + latestByType.length;

  if (dryRun) {
    return SessionRepairReport(
      path: path,
      recordsRead: recordsRead,
      recordsKept: recordsKept,
      droppedByType: droppedByType,
      keptLatestByType: keptLatestCounts,
      bytesBefore: bytesBefore,
      bytesAfter: bytesBefore,
      backupPath: '$path.bak',
      dryRun: true,
      untouchedSegments: untouchedSegments,
    );
  }

  // Pass 2: stream the kept spans into a temp file, then swap atomically.
  final tempPath = '$path.repairing';
  var write = await fs.writeFile(tempPath, '');
  for (final span in headerSpan.followedBy(keptSpans)) {
    final raw = await ranged.readRange(path, span.$1, span.$2);
    if (raw.isErr) {
      throw SessionRepairException(
        'read failed during repair of $path: ${raw.errorOrNull!.message}',
        code: SessionRepairErrorCode.unknown,
      );
    }
    write = await fs.appendFile(
      tempPath,
      utf8.decode(raw.valueOrNull!, allowMalformed: true),
    );
    if (write.isErr) {
      throw SessionRepairException(
        'write failed during repair of $path: ${write.errorOrNull!.message}',
        code: SessionRepairErrorCode.unknown,
      );
    }
  }
  // An existing backup is rotated to `.bak1` first: repair is exactly the
  // operation users run twice (dry-run, then real, then again after a
  // mistake) — silently replacing the previous `.bak` would destroy the
  // first repair's pristine original.
  final backupPath = '$path.bak';
  final backupExists = await fs.exists(backupPath);
  if (backupExists.isErr) {
    throw SessionRepairException(
      'cannot check for an existing backup at $backupPath: '
      '${backupExists.errorOrNull!.message}',
      code: SessionRepairErrorCode.unknown,
    );
  }
  if (backupExists.valueOrNull!) {
    final rotated = await renamable.renamePath(backupPath, '$path.bak1');
    if (rotated.isErr) {
      throw SessionRepairException(
        'cannot rotate the previous backup $backupPath to $path.bak1: '
        '${rotated.errorOrNull!.message}',
        code: SessionRepairErrorCode.unknown,
      );
    }
  }
  final backup = await renamable.renamePath(path, backupPath);
  if (backup.isErr) {
    throw SessionRepairException(
      'cannot back up $path to $backupPath: ${backup.errorOrNull!.message}',
      code: SessionRepairErrorCode.unknown,
    );
  }
  final swap = await renamable.renamePath(tempPath, path);
  if (swap.isErr) {
    // Roll the original back — never leave the session missing.
    await renamable.renamePath(backupPath, path);
    throw SessionRepairException(
      'cannot move the repaired file into place at $path: '
      '${swap.errorOrNull!.message}',
      code: SessionRepairErrorCode.unknown,
    );
  }
  final afterStat = await fs.fileInfo(path);
  return SessionRepairReport(
    path: path,
    recordsRead: recordsRead,
    recordsKept: recordsKept,
    droppedByType: droppedByType,
    keptLatestByType: keptLatestCounts,
    bytesBefore: bytesBefore,
    bytesAfter: afterStat.valueOrNull?.size ?? 0,
    backupPath: backupPath,
    dryRun: false,
    untouchedSegments: untouchedSegments,
  );
}

/// Repair refuses to produce an unopenable file: line 1 must parse as a
/// session header. A torn creation-write otherwise survives "repair"
/// byte-identically broken. Bounded sniff — a header is a small JSON
/// object; anything larger is corrupt by definition.
void _ensureRepairableHeader(String line, String path) {
  Object? decoded;
  if (line.length <= 16384) {
    try {
      decoded = jsonDecode(line);
    } on Object {
      decoded = null;
    }
  }
  if (decoded is! Map<String, dynamic> || decoded['type'] != 'session') {
    throw SessionRepairException(
      'first line of $path is not a valid session header — repair would '
      'produce an unopenable file',
      code: SessionRepairErrorCode.unknown,
    );
  }
}

/// Counts the rotated `<file>.part-NN` siblings next to [path] (gh-1077
/// segment rotation) — repair rewrites only the primary, and the report
/// must not let the bytesBefore/bytesAfter delta imply a full cleanup
/// while the parts keep their ledger records. Zero when the listing
/// fails (the note degrades silently rather than failing the repair).
Future<int> _countPartSiblings(FileSystem fs, String path) async {
  final slash = path.lastIndexOf('/');
  if (slash < 0) return 0;
  final dir = path.substring(0, slash);
  if (dir.isEmpty) return 0;
  final base = path.substring(slash + 1);
  final listed = await fs.listDir(dir);
  if (listed.isErr) return 0;
  var count = 0;
  for (final entry in listed.valueOrNull!) {
    if (entry.kind != FileKind.file) continue;
    final name = entry.name;
    if (name.startsWith('$base.part-') &&
        int.tryParse(name.substring('$base.part-'.length)) != null) {
      count++;
    }
  }
  return count;
}

void _appendSpan(List<(int, int)> spans, (int, int) span) {
  if (spans.isNotEmpty && spans.last.$2 == span.$1) {
    final (start, _) = spans.removeLast();
    spans.add((start, span.$2));
  } else {
    spans.add(span);
  }
}
