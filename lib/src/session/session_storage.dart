/// Session storage: the append-only JSONL file backing a session tree,
/// behind the [FileSystem] abstraction.
///
/// Ported from pi-mono `packages/agent/src/harness/session/jsonl-storage.ts`
/// (`JsonlSessionStorage`, `loadJsonlSessionMetadata`). The storage keeps an
/// in-memory index of records loaded from the file; every mutation appends
/// one JSON line first and only then updates the index, so the file is
/// always the source of truth.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../env/execution_env.dart';
import '../env/session_parse_executor.dart';
import '../exceptions.dart';
import '../session_io_retry.dart';
import 'session_record.dart';
import 'uuid.dart';

/// Metadata describing a stored session.
///
/// Ported from pi's `SessionMetadata` / `JsonlSessionMetadata`.
final class SessionMetadata {
  /// Creates [SessionMetadata].
  const SessionMetadata({
    required this.id,
    required this.createdAt,
    required this.cwd,
    required this.path,
    this.lastUpdatedAt,
    this.parentSessionPath,
    this.metadata,
    this.sizeBytes,
  });

  /// Unique session id.
  final String id;

  /// When the session was created (from the header).
  final DateTime createdAt;

  /// Working directory the session belongs to.
  final String cwd;

  /// Path of the JSONL file in the environment's filesystem.
  final String path;

  /// When the session file was last modified, if known.
  ///
  /// Populated from the filesystem when sessions are listed; it lets the UI
  /// sort and display by latest activity rather than creation time.
  final DateTime? lastUpdatedAt;

  /// Path of the session this one was forked from, if any.
  final String? parentSessionPath;

  /// Free-form application metadata from the header.
  final Map<String, dynamic>? metadata;

  /// Size of the session file in bytes, when known from the filesystem.
  ///
  /// Lets hosts skip or refuse to load pathological sessions (hundreds of
  /// MB) without reading them — loading one monopolizes the Dart heap and
  /// sends the VM into a permanent GC storm.
  final int? sizeBytes;
}

/// The storage contract behind a [Session] tree.
///
/// Ported from pi's `SessionStorage` interface. All operations are async so
/// implementations can hit a real filesystem; failures surface as
/// [SessionException].
abstract interface class SessionStorage {
  /// Returns the session metadata (from the file header).
  Future<SessionMetadata> getMetadata();

  /// Returns the id of the active leaf record, or `null` at the tree root.
  Future<String?> getLeafId();

  /// Persists a leaf record that moves the active leaf to [leafId].
  Future<void> setLeafId(String? leafId);

  /// Generates a record id that is unique within this storage.
  Future<String> createEntryId();

  /// Appends [record] to the file and the in-memory index.
  Future<void> appendEntry(SessionRecord record);

  /// Looks up a record by id.
  Future<SessionRecord?> getEntry(String id);

  /// Returns all records of the given [type], in file order.
  Future<List<SessionRecord>> findEntries(String type);

  /// Returns the current label attached to the record [id], if any.
  Future<String?> getLabel(String id);

  /// Walks from [leafId] to the tree root, returning records root-first.
  Future<List<SessionRecord>> getPathToRoot(String? leafId);

  /// Returns all records in file order.
  Future<List<SessionRecord>> getEntries();
}

/// A [SessionStorage] whose header is parsed at construction and exposed
/// synchronously — prompt-cache affinity and the session-scoped
/// `.tools/<id>.yaml` path read it without an async hop.
abstract interface class SessionHeaderCache {
  /// The header metadata (parsed at open/creation).
  SessionMetadata get cachedMetadata;
}

String? leafIdAfterSessionRecord(SessionRecord record) {
  return record is LeafRecord ? record.targetId : record.id;
}

void updateSessionLabelCache(
  Map<String, String> labelsById,
  SessionRecord record,
) {
  if (record is! LabelRecord) return;
  final label = record.label?.trim();
  if (label != null && label.isNotEmpty) {
    labelsById[record.targetId] = label;
  } else {
    labelsById.remove(record.targetId);
  }
}

String generateSessionEntryId(Map<String, SessionRecord> byId) {
  for (var i = 0; i < 100; i++) {
    // The uuidv7 prefix is timestamp-derived and nearly constant between
    // calls, so short ids must come from the random tail.
    final id = uuidv7().substring(uuidv7().length - 8);
    if (!byId.containsKey(id)) return id;
  }
  return uuidv7();
}

/// One write-chain per session file path, shared by every
/// [JsonlSessionStorage] instance in this isolate: concurrent mutations of
/// the SAME file (message persistence vs subagent-registry snapshots vs an
/// open-time heal rewrite) queue here instead of racing their byte ranges
/// into the middle of each other's records. Cross-process safety comes from
/// single-shot whole-line appends (`appendFile` with one complete JSON line)
/// plus this quarantine-on-open heal for anything that slipped through.
final Map<String, Future<void>> _sessionFileOps = <String, Future<void>>{};

/// Runs [op] after every previously queued operation on [filePath]
/// completes. Never lets one failure poison the chain for later callers.
Future<T> withSessionFileLock<T>(String filePath, Future<T> Function() op) {
  final result = (_sessionFileOps[filePath] ?? Future<void>.value()).then(
    (_) => op(),
  );
  _sessionFileOps[filePath] = result.then<void>((_) {}, onError: (Object _) {});
  return result;
}

Never _invalidSession(String filePath, String message, [Object? cause]) {
  throw SessionException(
    'Invalid JSONL session file $filePath: $message',
    code: SessionErrorCode.invalidSession,
    cause: cause,
  );
}

Never _invalidEntry(
  String filePath,
  int lineNumber,
  String message, [
  Object? cause,
]) {
  throw SessionException(
    'Invalid JSONL session file $filePath: line $lineNumber $message',
    code: SessionErrorCode.invalidEntry,
    cause: cause,
  );
}

T _fsOrThrow<T>(Result<T, FileError> result, String message) {
  if (result.isErr) {
    final error = result.errorOrNull!;
    throw SessionException(
      '$message: ${error.message}',
      code: error.code == FileErrorCode.notFound
          ? SessionErrorCode.notFound
          : SessionErrorCode.storage,
      cause: error,
    );
  }
  return result.valueOrNull as T;
}

/// Parses the header line of a session file into its [SessionHeader].
///
/// Public for the windowed reader (`session_chunk_reader.dart`), which
/// parses only the lines it reads. Throws [SessionException] on a bad line.
SessionHeader parseSessionHeaderLine(String line, String filePath) {
  Object? parsed;
  try {
    parsed = jsonDecode(line);
  } on Object catch (error) {
    _invalidSession(
      filePath,
      'first line is not a valid session header',
      error,
    );
  }
  if (parsed is! Map<String, dynamic>) {
    _invalidSession(filePath, 'first line is not a valid session header');
  }
  try {
    return SessionHeader.fromJson(parsed);
  } on FormatException catch (error) {
    _invalidSession(filePath, error.message, error);
  }
}

/// Header-only decode for giant `custom` records (issue #503 round 3b).
///
/// The resume boundary walk crosses hundreds of `model_request_summary`
/// ledger payloads (~0.75 MB each) that count ZERO context tokens; a full
/// jsonDecode + isolate transfer per record dominated the walk. The
/// canonical writer order is `type,id,parentId,timestamp,customType,data`,
/// so when the line is huge and starts as a `custom` record we decode only
/// the prefix up to `,"data":` and stub `data` to null. Any deviation —
/// foreign field order, missing data key, malformed prefix — falls back
/// (returns null) so the caller does a full decode. `custom_message`
/// records project into context and are NEVER shallow-parsed (their type
/// string differs, so the prefix test already excludes them).
SessionRecord? parseShallowCustomRecord(String line) {
  if (line.length < shallowCustomRecordThreshold) return null;
  if (!line.startsWith('{"type":"custom"')) return null;
  final header = shallowCustomHeader(line);
  if (header == null) return null;
  try {
    final decoded = jsonDecode(header);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['type'] != 'custom') return null;
    if (decoded['id'] is! String) return null;
    if (decoded['timestamp'] is! String) return null;
    if (decoded['customType'] is! String) return null;
    return CustomRecord(
      id: decoded['id'] as String,
      parentId: decoded['parentId'] as String?,
      timestamp: DateTime.parse(decoded['timestamp'] as String),
      customType: decoded['customType'] as String,
      data: null,
    );
  } on Object {
    return null; // malformed prefix — the caller falls back to full decode
  }
}

/// Size gate for the shallow custom path (64 KiB) — smaller lines decode
/// whole, the header extraction is not worth it.
const shallowCustomRecordThreshold = 64 << 10;

/// Extracts the JSON header (everything up to `,"data":`) of a giant
/// `custom` record line as a parseable JSON object with `data` omitted —
/// or null when the line does not match the canonical writer order
/// (`customType` must precede `data`). Pre-truncating with this BEFORE the
/// batch parse keeps the ~0.75 MB payloads out of the isolate transfer
/// entirely (issue #503 round 3b): the truncated header decodes as a
/// [CustomRecord] with `data: null` through the normal path.
String? shallowCustomHeader(String line) {
  final dataIndex = line.indexOf(',"data":');
  if (dataIndex < 0) return null;
  // Canonical writer order has customType before data; a foreign order
  // (data first) must keep the full line so no field is lost.
  if (!line.substring(0, dataIndex).contains(',"customType":')) return null;
  return '${line.substring(0, dataIndex)}}';
}

/// Parses one JSONL entry line into its [SessionRecord].
///
/// Public for the windowed reader (`session_chunk_reader.dart`). Throws
/// [SessionException] on a torn or foreign line — windowed callers treat
/// that as "skip this line", never as a fatal open failure.
SessionRecord parseSessionEntryLine(
  String line,
  String filePath,
  int lineNumber,
) {
  Object? parsed;
  try {
    parsed = jsonDecode(line);
  } on Object catch (error) {
    _invalidEntry(filePath, lineNumber, 'is not valid JSON', error);
  }
  if (parsed is! Map<String, dynamic>) {
    _invalidEntry(filePath, lineNumber, 'is not a valid session entry');
  }
  try {
    return SessionRecord.fromJson(parsed);
  } on FormatException catch (error) {
    _invalidEntry(filePath, lineNumber, error.message, error);
  }
}

SessionMetadata headerToSessionMetadata(
  SessionHeader header,
  String path, {
  DateTime? lastUpdatedAt,
  int? sizeBytes,
}) {
  return SessionMetadata(
    id: header.id,
    createdAt: header.timestamp,
    cwd: header.cwd,
    path: path,
    lastUpdatedAt: lastUpdatedAt,
    parentSessionPath: header.parentSessionPath,
    metadata: header.metadata,
    sizeBytes: sizeBytes,
  );
}

/// Reads just the header of a session file and returns its metadata.
///
/// [lastUpdatedAt] is populated from the filesystem entry when sessions are
/// listed so callers can sort by latest activity without a separate stat.
///
/// Ported from pi's `loadJsonlSessionMetadata`.
Future<SessionMetadata> loadJsonlSessionMetadata(
  FileSystem fs,
  String filePath, {
  DateTime? lastUpdatedAt,
  int? sizeBytes,
}) async {
  final lines = _fsOrThrow(
    await fs.readTextLines(filePath, maxLines: 1),
    'Failed to read session header $filePath',
  );
  final line = lines.firstOrNull;
  if (line != null && line.trim().isNotEmpty) {
    return headerToSessionMetadata(
      parseSessionHeaderLine(line, filePath),
      filePath,
      lastUpdatedAt: lastUpdatedAt,
      sizeBytes: sizeBytes,
    );
  }
  _invalidSession(filePath, 'missing session header');
}

/// Session segment rotation thresholds (fa dev-leg gh-1077, 2026-09-30):
/// the factory persists session traces into git, and one unbounded JSONL
/// grew to 192.95 MB — GitHub rejected the whole push (GH001: file limit
/// 100 MB) AFTER the agent had finished. The active segment rotates to a
/// `<path>.part-NN` sibling at [kSessionSegmentRotateBytes]; the hard cap
/// [kSessionSegmentHardCapBytes] drops the OLDEST records of the active
/// segment (with a warning) instead of ever failing the append. Both sit
/// well under the remote 100 MB file limit.
const int kSessionSegmentRotateBytes = 80 << 20;
const int kSessionSegmentHardCapBytes = 95 << 20;

/// Suffix of the rotated segment siblings: `<primary>.part-0001`, …
const String kSessionPartSuffix = '.part-';

String sessionPartPath(String filePath, int seq) =>
    '$filePath$kSessionPartSuffix${seq.toString().padLeft(4, '0')}';

int? _parseSessionPartSeq(String name, String baseName) {
  final prefix = '$baseName$kSessionPartSuffix';
  if (!name.startsWith(prefix)) return null;
  return int.tryParse(name.substring(prefix.length));
}

/// Both separators, aligned with `_sessionIdFromPath` in
/// `session_repo.dart`: on Windows-style paths a `/`-only split never
/// finds the basename and the part listing silently goes blind.
final _sessionPathSeparators = RegExp(r'[/\\]');

String? _sessionDirOf(String filePath) {
  final i = filePath.lastIndexOf(_sessionPathSeparators);
  return i < 0 ? null : filePath.substring(0, i);
}

String _sessionBaseName(String filePath) {
  final i = filePath.lastIndexOf(_sessionPathSeparators);
  return i < 0 ? filePath : filePath.substring(i + 1);
}

/// The directory prefix of [filePath] INCLUDING its trailing separator
/// (the separator style of the path itself), '' for bare filenames.
String _sessionDirPrefix(String filePath) {
  final i = filePath.lastIndexOf(_sessionPathSeparators);
  return i < 0 ? '' : filePath.substring(0, i + 1);
}

/// All segment paths of a (possibly rotated) session in chain order:
/// the `.part-NN` siblings, oldest first, then the primary. A listing
/// failure degrades to just the primary — raw-scan consumers
/// (`readCustomRecordsOfType`, `sessionNameQuick`) must never fail a
/// boot because housekeeping metadata could not be read.
Future<List<String>> listSessionSegmentPaths(
  FileSystem fs,
  String primaryPath,
) async {
  final listed = await JsonlSessionStorage._listSessionParts(fs, primaryPath);
  return [...?listed?.parts, primaryPath];
}

/// Append-only JSONL session storage on top of a [FileSystem].
///
/// Ported from pi's `JsonlSessionStorage`.
final class JsonlSessionStorage implements SessionStorage, SessionHeaderCache {
  /// Warning sink for segment-rotation events (hard-cap truncations,
  /// rotation fallbacks). Silent by default — the CLI wires
  /// `stderr.writeln` at startup. Never throws.
  static void Function(String message)? onRotationWarning;

  JsonlSessionStorage._(
    this._fs,
    this._filePath,
    SessionHeader header,
    List<SessionRecord> entries,
    String? leafId, {
    int quarantined = 0,
    int healedLeafEntries = 0,
    this._ioRetry = const SessionIoRetryConfig(),
    String? headerLine,
    int nextPartSeq = 1,
    int? rotateBytes,
    int? hardCapBytes,
    this._rotationSuspended = false,
  }) : _metadata = headerToSessionMetadata(header, _filePath),
       _partSeq = nextPartSeq,
       _rotateBytes = rotateBytes ?? kSessionSegmentRotateBytes,
       _hardCapBytes = hardCapBytes ?? kSessionSegmentHardCapBytes,
       _entries = entries,
       _byId = {for (final entry in entries) entry.id: entry},
       _currentLeafId = leafId,
       _quarantinedEntries = quarantined {
    _headerLine = headerLine;
    _header = header;
    // Assigned in the body: the lint prefers an initializing formal, which
    // a private named parameter cannot be.
    _healedLeafEntries = healedLeafEntries;
    for (final entry in entries) {
      updateSessionLabelCache(_labelsById, entry);
    }
  }

  final FileSystem _fs;
  final String _filePath;
  final SessionMetadata _metadata;

  /// Transient-ENOENT retry wiring (issue #427) for this storage's
  /// appends; the static [open]/[create] calls take their own config.
  final SessionIoRetryConfig _ioRetry;
  final List<SessionRecord> _entries;
  final Map<String, SessionRecord> _byId;
  final Map<String, String> _labelsById = {};
  String? _currentLeafId;

  /// How many malformed lines the last [open] quarantined into the
  /// `<file>.corrupt` sidecar (0 for freshly created storages).
  final int _quarantinedEntries;
  int get quarantinedEntries => _quarantinedEntries;

  /// Raw JSON of the session header line — the seed of every rotated
  /// segment. `null` only when the open path did not retain it; rotation
  /// re-reads it from disk once, lazily.
  String? _headerLine;

  /// The parsed session header — kept so [withRotationLimits] can rebuild
  /// an equivalent storage.
  SessionHeader? _header;

  /// Rotation sequence: continues after the `.part-NN` segments observed
  /// at open.
  int _partSeq = 0;

  /// Active-segment thresholds — see [kSessionSegmentRotateBytes].
  final int _rotateBytes;
  final int _hardCapBytes;

  /// True when the part listing failed at open: rotation stays
  /// suspended (fail closed — a blind sequence could overwrite an
  /// existing part); the plain append + hard cap still run.
  final bool _rotationSuspended;

  /// Whether the last [open] healed a dangling tracked leaf to the newest
  /// surviving record (quarantine had dropped the leaf's record — issue
  /// #858; surfaced like [quarantinedEntries] instead of failing the
  /// resume silently).
  // Set once by [JsonlSessionStorage._] from the open-time heal; mutable
  // only because a private named initializing formal is not expressible.
  int _healedLeafEntries = 0;
  int get healedLeafEntries => _healedLeafEntries;

  /// Milliseconds the last [open] spent inside the file lock (read +
  /// parse + rebuild); the wrapper logs `lock_wait = total - inner`.
  int _openInnerMs = 0;

  /// The header metadata, available synchronously (it is parsed at
  /// construction). Backs [Session.cachedId].
  @override
  SessionMetadata get cachedMetadata => _metadata;

  /// Test/host hook: the same session state with different rotation
  /// limits (the shipped defaults ride the top-level constants).
  @visibleForTesting
  JsonlSessionStorage withRotationLimits({
    int? rotateBytes,
    int? hardCapBytes,
  }) {
    return JsonlSessionStorage._(
      _fs,
      _filePath,
      _header!,
      [..._entries],
      _currentLeafId,
      quarantined: _quarantinedEntries,
      ioRetry: _ioRetry,
      headerLine: _headerLine,
      nextPartSeq: _partSeq,
      rotateBytes: rotateBytes,
      hardCapBytes: hardCapBytes,
      rotationSuspended: _rotationSuspended,
    );
  }

  /// Opens an existing session file.
  ///
  /// Malformed lines — a torn crash-write at ANY position (torn last line,
  /// or a hole mid-file left by racing writers) — never fail the open: they
  /// are quarantined verbatim into a `<file>.corrupt` sidecar and dropped,
  /// and the main file is rewritten from the surviving records so every
  /// later open/append sees whole JSONL. The number of quarantined lines is
  /// reported through [quarantinedEntries].
  static Future<JsonlSessionStorage> open(
    FileSystem fs,
    String filePath, {
    SessionParseExecutor? parseExecutor,
    SessionIoRetryConfig ioRetry = const SessionIoRetryConfig(),
    SessionTimingLogger? timingLog,
  }) async {
    final sw = Stopwatch()..start();
    final storage = await withSessionFileLock(
      filePath,
      () => _openLocked(fs, filePath, parseExecutor, ioRetry, timingLog),
    );
    timingLog?.call(
      'resume_timing open file=${filePath.split('/').last} '
      'mode=full lock_wait_ms=${sw.elapsedMilliseconds - storage._openInnerMs} '
      'total_ms=${sw.elapsedMilliseconds}',
    );
    return storage;
  }

  static Future<JsonlSessionStorage> _openLocked(
    FileSystem fs,
    String filePath,
    SessionParseExecutor? parseExecutor,
    SessionIoRetryConfig ioRetry,
    SessionTimingLogger? timingLog,
  ) async {
    final totalSw = Stopwatch()..start();
    var phaseSw = Stopwatch()..start();
    // Segment rotation (fa gh-1077): `<path>.part-NN` siblings hold older
    // segments, the primary holds a header copy + the active tail. They
    // are loaded in order — a resumed session must see the whole record
    // chain (parents of recent records live in older segments).
    // A null listing (listDir failed) fails CLOSED: rotation stays
    // suspended for this storage so a blind sequence can never
    // overwrite an existing part.
    final listed = await _listSessionParts(fs, filePath);
    final parts = listed?.parts ?? const <String>[];
    if (parts.isNotEmpty) {
      await _healPrimarySegmentLocked(fs, filePath, parts.last, ioRetry);
    }
    final segmentPaths = [...parts, filePath];
    var primaryBytes = 0;
    var readMs = 0;
    var splitMs = 0;
    var parseMs = 0;
    var rewriteMs = 0;
    SessionHeader? header;
    String? headerLine;
    final entries = <SessionRecord>[];
    final seenRecordIds = <String>{};
    var quarantined = 0;
    for (final segmentPath in segmentPaths) {
      final content = _fsOrThrow(
        // Issue #427: the whole-file read behind an open can momentarily
        // fail with a not-found-shaped error on some hosts; a short capped
        // retry rides it out before the open gives up with a named error.
        await retryTransientSessionFileIo(
          () => fs.readTextFile(segmentPath),
          op: 'open',
          path: segmentPath,
          config: ioRetry,
        ),
        'Failed to read session $segmentPath',
      );
      if (segmentPath == filePath) primaryBytes = content.length;
      readMs += phaseSw.elapsedMilliseconds;
      phaseSw
        ..reset()
        ..start();
      final allLines = [
        for (final line in content.split('\n'))
          if (line.trim().isNotEmpty) line,
      ];
      if (allLines.isEmpty) {
        _invalidSession(segmentPath, 'missing session header');
      }
      final segmentHeader = parseSessionHeaderLine(allLines.first, segmentPath);
      // Every segment carries a copy of the same header; the primary's
      // is the one the storage exposes. Rotation seeds all segments from
      // the same header line, so today they are identical — pin the
      // primary's explicitly so a drifted archived header can never win
      // (the loop visits the oldest segment first).
      if (segmentPath == filePath) {
        header = segmentHeader;
        headerLine = allLines.first;
      }
      header ??= segmentHeader;
      headerLine ??= allLines.first;
      splitMs += phaseSw.elapsedMilliseconds;
      phaseSw
        ..reset()
        ..start();
      // The body (everything below the header) parses in bounded batches
      // through [parseSessionLines] — inside a background isolate when a
      // [SessionParseExecutor] is injected, inline-batched otherwise
      // (issue #199). Torn lines come back as null slots and keep the exact
      // quarantine flow below.
      final parsed = await parseSessionLines(
        allLines.sublist(1),
        filePath: segmentPath,
        firstLineNumber: 2,
        executor: parseExecutor,
      );
      parseMs += phaseSw.elapsedMilliseconds;
      phaseSw
        ..reset()
        ..start();
      final load = await _collectSegmentRecords(
        fs,
        segmentPath,
        allLines,
        parsed,
        entries,
        seenRecordIds,
      );
      quarantined += load.torn;
      rewriteMs += load.rewriteMs;
    }
    if (header == null) _invalidSession(filePath, 'missing session header');
    final (:leafId, healed: healedLeafEntries) = _resolveTrackedLeaf(entries);
    phaseSw
      ..reset()
      ..start();
    final storage = JsonlSessionStorage._(
      fs,
      filePath,
      header,
      entries,
      leafId,
      quarantined: quarantined,
      healedLeafEntries: healedLeafEntries,
      ioRetry: ioRetry,
      headerLine: headerLine,
      nextPartSeq: (listed?.maxSeq ?? 0) + 1,
      rotationSuspended: listed == null,
    );
    final buildMs = phaseSw.elapsedMilliseconds;
    storage._openInnerMs = totalSw.elapsedMilliseconds;
    timingLog?.call(
      'resume_timing open-detail file=${filePath.split('/').last} mode=full '
      'segments=${segmentPaths.length} bytes=$primaryBytes read_ms=$readMs '
      'split_ms=$splitMs '
      'parse_ms=$parseMs records=${entries.length} torn=$quarantined '
      'rewrite_ms=$rewriteMs build_ms=$buildMs '
      'inner_ms=${storage._openInnerMs}',
    );
    return storage;
  }

  /// Computes the tracked leaf of [entries] and heals a dangling one: a
  /// quarantined record can leave the tracked leaf unresolved — either a
  /// torn leaf record itself or a LeafRecord whose target dropped
  /// (issue #858). The heal retargets the leaf to the newest surviving
  /// record so the resume walk never starts from an id the tree cannot
  /// resolve; the healed count is surfaced through
  /// [JsonlSessionStorage.healedLeafEntries] the same way quarantine
  /// reports through [JsonlSessionStorage.quarantinedEntries].
  static ({String? leafId, int healed}) _resolveTrackedLeaf(
    List<SessionRecord> entries,
  ) {
    String? leafId;
    for (final entry in entries) {
      leafId = leafIdAfterSessionRecord(entry);
    }
    var healed = 0;
    if (leafId != null && !entries.any((entry) => entry.id == leafId)) {
      leafId = entries.isEmpty ? null : entries.last.id;
      healed = leafId == null ? 0 : 1;
    }
    return (leafId: leafId, healed: healed);
  }

  /// Collects one segment's parsed records into [entries], skipping torn
  /// lines (quarantined to the `.corrupt` sidecar) and record-id repeats
  /// (a failed-rotation restore can leave a part behind that is an exact
  /// copy of the primary: ids are storage-unique, so a repeat is always
  /// that leftover — keep the first copy, scrub the rest). When anything
  /// was dropped the segment file is rewritten from the surviving lines
  /// so the NEXT open is clean. Returns the torn/duplicate counts and
  /// the time spent in the heal rewrite.
  static Future<({int torn, int duplicates, int rewriteMs})>
  _collectSegmentRecords(
    FileSystem fs,
    String segmentPath,
    List<String> allLines,
    List<SessionRecord?> parsed,
    List<SessionRecord> entries,
    Set<String> seenRecordIds,
  ) async {
    final sw = Stopwatch()..start();
    final goodLines = <String>[allLines.first];
    final tornLines = <String>[];
    var duplicates = 0;
    for (var i = 0; i < parsed.length; i++) {
      final entry = parsed[i];
      if (entry == null) {
        // A malformed line is a torn write: drop the record, keep the raw
        // bytes for the sidecar below. Never fatal.
        tornLines.add(allLines[i + 1]);
        continue;
      }
      if (!seenRecordIds.add(entry.id)) {
        duplicates++;
        continue;
      }
      entries.add(entry);
      goodLines.add(allLines[i + 1]);
    }
    if (duplicates > 0) {
      JsonlSessionStorage.onRotationWarning?.call(
        'session open: dropped $duplicates duplicated record(s) '
        'from ${segmentPath.split('/').last} (a failed-rotation restore '
        'left a segment copy behind)',
      );
    }
    var rewriteMs = 0;
    if (tornLines.isNotEmpty || duplicates > 0) {
      // Forensics sidecar first; read-only storage skips both writes and
      // still loads fine with the torn records simply absent from memory.
      try {
        if (tornLines.isNotEmpty) {
          await fs.appendFile(
            '$segmentPath.corrupt',
            '${tornLines.join('\n')}\n',
          );
        }
        await fs.writeFile(segmentPath, '${goodLines.join('\n')}\n');
        rewriteMs = sw.elapsedMilliseconds;
      } on Object {
        // Read-only storage: the in-memory state is still consistent.
      }
    }
    return (
      torn: tornLines.length,
      duplicates: duplicates,
      rewriteMs: rewriteMs,
    );
  }

  /// Crash/cross-process heal for the rotation window (fa gh-1077
  /// review): rotation spans `rename(primary → part)` + `seed(primary)`
  /// and no per-isolate lock makes that atomic. When the primary is
  /// missing (crash between the two ops) or header-less (a racing
  /// appendFile in another process recreated it), the classic open
  /// would be FATAL even though every record still sits in the parts.
  /// Reseed/prefix the header from the newest part — best effort; a
  /// failed heal falls through to the classic open error below.
  static Future<void> _healPrimarySegmentLocked(
    FileSystem fs,
    String filePath,
    String newestPart,
    SessionIoRetryConfig ioRetry,
  ) async {
    final partHeader = await _segmentHeaderLine(fs, newestPart);
    if (partHeader == null) return;
    String? content;
    try {
      final read = await retryTransientSessionFileIo(
        () => fs.readTextFile(filePath),
        op: 'open',
        path: filePath,
        config: ioRetry,
      );
      content = read.valueOrNull;
    } on Object {
      content = null;
    }
    final fileName = filePath.split(_sessionPathSeparators).last;
    final partName = newestPart.split(_sessionPathSeparators).last;
    try {
      if (content == null) {
        // Crash between the rename and the seed: reseed the primary.
        final seeded = await fs.writeFile(filePath, '$partHeader\n');
        if (seeded.isOk) {
          JsonlSessionStorage.onRotationWarning?.call(
            'session rotation heal: reseeded the missing primary '
            '$fileName from $partName',
          );
        }
        return;
      }
      if (_primaryHeaderValid(content, filePath)) return;
      // A racing append recreated the primary without a header: prefix
      // the header, keep whatever records it already holds.
      final healed = await fs.writeFile(filePath, '$partHeader\n$content');
      if (healed.isOk) {
        JsonlSessionStorage.onRotationWarning?.call(
          'session rotation heal: restored the header of '
          '$fileName from $partName',
        );
      }
    } on Object {
      // Best effort: the open loop reports any remaining damage.
    }
  }

  /// The first non-empty line of a segment file — null when the file
  /// cannot be read, holds none, or the line does not parse as a session
  /// header. Never throws: the heal is best effort, and it must only ever
  /// propagate a header that parses (a corrupted segment first line must
  /// degrade to the classic open error, not become a poison writer).
  static Future<String?> _segmentHeaderLine(FileSystem fs, String path) async {
    try {
      final lines = await fs.readTextLines(path, maxLines: 1);
      final line = lines.valueOrNull?.firstOrNull;
      if (line == null || line.trim().isEmpty) return null;
      return _primaryHeaderValid(line, path) ? line : null;
    } on Object {
      return null;
    }
  }

  /// Whether [content] starts with a valid session header line.
  static bool _primaryHeaderValid(String content, String filePath) {
    final firstLine = content
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return false;
    try {
      parseSessionHeaderLine(firstLine, filePath);
      return true;
    } on Object {
      return false;
    }
  }

  /// Creates a new session file with just the header line.
  static Future<JsonlSessionStorage> create(
    FileSystem fs,
    String filePath, {
    required String cwd,
    required String sessionId,
    String? parentSessionPath,
    Map<String, dynamic>? metadata,
    SessionIoRetryConfig ioRetry = const SessionIoRetryConfig(),
  }) async {
    final header = SessionHeader(
      id: sessionId,
      timestamp: DateTime.now(),
      cwd: cwd,
      parentSessionPath: parentSessionPath,
      metadata: metadata,
    );
    await withSessionFileLock(filePath, () async {
      _fsOrThrow(
        await retryTransientSessionFileIo(
          () => fs.writeFile(filePath, '${jsonEncode(header.toJson())}\n'),
          op: 'create',
          path: filePath,
          config: ioRetry,
        ),
        'Failed to create session $filePath',
      );
    });
    return JsonlSessionStorage._(
      fs,
      filePath,
      header,
      [],
      null,
      ioRetry: ioRetry,
      headerLine: jsonEncode(header.toJson()),
    );
  }

  @override
  Future<SessionMetadata> getMetadata() async => _metadata;

  @override
  Future<String?> getLeafId() async {
    // The tracked leaf is healed at load (issue #858) and every append
    // sets a just-written id, so a persisted dangle is unreachable; the
    // alarm below can only fire on a caller-mutated id (issue #1114).
    final leafId = _currentLeafId;
    if (leafId != null && !_byId.containsKey(leafId)) {
      throw SessionException(
        'Entry $leafId not found',
        code: SessionErrorCode.invalidSession,
      );
    }
    return leafId;
  }

  @override
  Future<void> setLeafId(String? leafId) async {
    if (leafId != null && !_byId.containsKey(leafId)) {
      throw SessionException(
        'Entry $leafId not found',
        code: SessionErrorCode.notFound,
      );
    }
    final record = LeafRecord(
      id: generateSessionEntryId(_byId),
      parentId: _currentLeafId,
      timestamp: DateTime.now(),
      targetId: leafId,
    );
    await appendEntry(record);
  }

  @override
  Future<String> createEntryId() async => generateSessionEntryId(_byId);

  @override
  Future<void> appendEntry(SessionRecord record) async {
    // Serialize with every other writer of this file (other appends, an
    // open-time heal rewrite, creation) so concurrent persistence bursts —
    // message records landing while subagent-registry snapshots flush —
    // can never interleave their byte ranges mid-record.
    // Encode once: the same line feeds the rotation size math and the
    // append itself (records reach ~0.75 MB — two serializations per
    // append, inside the file lock, was measurable).
    final line = jsonEncode(record.toJson());
    await withSessionFileLock(_filePath, () async {
      // Segment rotation + hard cap ride the same lock as the append so a
      // concurrent reader never sees a segment mid-rotation. UTF-8 bytes,
      // not UTF-16 code units: the caps guard an on-disk byte limit.
      await _rotateIfNeededLocked(utf8.encode(line).length + 1);
      // Issue #427: a transient ENOENT on the record append (the
      // submit-death path) rides a short capped retry instead of losing
      // the record; exhaustion still fails as a named SessionException.
      _fsOrThrow(
        await retryTransientSessionFileIo(
          () => _fs.appendFile(_filePath, '$line\n'),
          op: 'append',
          path: _filePath,
          config: _ioRetry,
        ),
        'Failed to append session entry ${record.id}',
      );
    });
    _entries.add(record);
    _byId[record.id] = record;
    updateSessionLabelCache(_labelsById, record);
    _currentLeafId = leafIdAfterSessionRecord(record);
  }

  /// Rotates the active segment when it has grown past the rotate
  /// threshold, then enforces the hard cap by dropping the OLDEST records
  /// of the active segment. Best effort in both directions: any failure
  /// falls through to the plain (unbounded) append — persistence must
  /// never fail because housekeeping could not run. [incomingBytes] is
  /// the encoded UTF-8 size of the record about to be appended.
  Future<void> _rotateIfNeededLocked(int incomingBytes) async {
    if (!await _recoverHeaderLineLocked()) return;
    final size = await _sessionFileSize();
    if (size == null) return;
    var active = size;
    if (active >= _rotateBytes && !_rotationSuspended) {
      active = await _rotateSegmentLocked(size);
    }
    if (active + incomingBytes > _hardCapBytes) {
      await _truncateOldestLocked(incomingBytes);
    }
  }

  /// Rotation needs a header line to seed the next segment; when the
  /// storage did not retain one, recover it from disk once. False when
  /// it cannot be recovered — the caller keeps the plain append path.
  Future<bool> _recoverHeaderLineLocked() async {
    if (_headerLine != null) return true;
    final line = await _segmentHeaderLine(_fs, _filePath);
    if (line == null) return false;
    _headerLine = line;
    return true;
  }

  /// Renames the primary to the next `.part-NN` sibling and seeds a fresh
  /// primary with just the header. Returns the new (header-only) size, or
  /// [preCallSize] when the rotation could not complete — the caller then
  /// still applies the hard cap to the un-rotated segment.
  Future<int> _rotateSegmentLocked(int preCallSize) async {
    final partPath = sessionPartPath(_filePath, _nextPartSeq());
    var renamed = false;
    if (_fs is RenamableFileSystem) {
      final result = await (_fs as RenamableFileSystem).renamePath(
        _filePath,
        partPath,
      );
      renamed = result.isOk;
    }
    if (!renamed) {
      // No atomic-rename capability (or the rename failed): copy the
      // segment out, then truncate the primary in place.
      try {
        final content = await _fs.readTextFile(_filePath);
        if (content.isErr) return preCallSize;
        final written = await _fs.writeFile(partPath, content.valueOrNull!);
        if (written.isErr) return preCallSize;
      } on Object {
        return preCallSize;
      }
    }
    // gh-1077 review: a rotated session is a new on-disk format for
    // pre-rotation builds (they read only the primary and crash on the
    // severed parent chain or silently miss archived records). Stamp the
    // rotated-format version into the header line — it rides verbatim
    // into every segment from here on, so an older binary fails at
    // header parse with a clear "unsupported session version".
    final rotatedLine = _rotatedHeaderLine(_headerLine!);
    if (rotatedLine != null) {
      _headerLine = rotatedLine;
      await _markSegmentRotatedLocked(partPath, rotatedLine);
    }
    final seeded = await retryTransientSessionFileIo(
      () => _fs.writeFile(_filePath, '${_headerLine!}\n'),
      op: 'rotate',
      path: _filePath,
      config: _ioRetry,
    );
    if (seeded.isErr) {
      // The primary must exist (appendFile alone would recreate it without
      // a header and the next open would fail). Restore it from the part.
      try {
        final content = await _fs.readTextFile(partPath);
        if (content.isOk) {
          final restored = await _fs.writeFile(_filePath, content.valueOrNull!);
          if (restored.isOk) {
            // The part is now an exact copy of the restored primary.
            // Deleting it would route around the session-deletion gate
            // (AC3: session_repo is the only remove site); instead the
            // open path dedupes repeated record ids across segments, so
            // the leftover copy is harmless — and self-scrubbing: the
            // open rewrite drops the duplicated lines.
            onRotationWarning?.call(
              'session rotation: could not seed a fresh primary '
              '($_filePath) — restored the pre-rotation segment',
            );
            return preCallSize;
          }
        }
      } on Object {
        // fall through to the warning below
      }
      onRotationWarning?.call(
        'session rotation: primary $_filePath missing a header — the next '
        'open heals it from the newest part (gh-1077)',
      );
      return preCallSize;
    }
    onRotationWarning?.call(
      'session rotation: ${_filePath.split('/').last} -> '
      '${partPath.split('/').last}',
    );
    return utf8.encode(_headerLine!).length + 1;
  }

  /// The header line stamped with [SessionHeader.rotatedVersion]. Null
  /// when the line does not decode — rotation then keeps the unmarked
  /// header (best effort; the format is otherwise unchanged).
  static String? _rotatedHeaderLine(String headerLine) {
    try {
      final json = jsonDecode(headerLine);
      if (json is! Map<String, dynamic>) return null;
      json['version'] = SessionHeader.rotatedVersion;
      return jsonEncode(json);
    } on Object {
      return null;
    }
  }

  /// Stamps the just-archived segment's header copy with the rotated
  /// marker too: the heal seeds future primaries from part headers, so
  /// the marker must ride along. Best effort — a failed stamp leaves a
  /// version-3 part header, which a later heal simply propagates.
  Future<void> _markSegmentRotatedLocked(
    String partPath,
    String rotatedLine,
  ) async {
    try {
      final content = await _fs.readTextFile(partPath);
      if (content.isErr) return;
      final lines = content.valueOrNull!.split('\n');
      if (lines.isEmpty) return;
      lines[0] = rotatedLine;
      await _fs.writeFile(partPath, lines.join('\n'));
    } on Object {
      // Best effort — see the docstring.
    }
  }

  /// Drops the oldest records of the ACTIVE segment (never the header,
  /// never the newest record) until the segment plus the incoming record
  /// fits the hard cap. Rewrites the file in place; a no-op on any error.
  /// The in-memory index is pruned in step with the rewrite — a stale
  /// index masked the severed parent chain until the next open.
  Future<void> _truncateOldestLocked(int incomingBytes) async {
    try {
      final read = await _fs.readTextFile(_filePath);
      if (read.isErr) return;
      final lines = [
        for (final line in read.valueOrNull!.split('\n'))
          if (line.trim().isNotEmpty) line,
      ];
      // header + at most one record — nothing safe to drop.
      if (lines.length <= 2) return;
      final budget = _hardCapBytes - incomingBytes;
      var kept = _lineBytes(lines.first) + _lineBytes(lines.last);
      var keepFrom = lines.length - 1;
      for (var i = lines.length - 2; i >= 1; i--) {
        final lineSize = _lineBytes(lines[i]);
        if (kept + lineSize > budget) break;
        kept += lineSize;
        keepFrom = i;
      }
      final dropped = keepFrom - 1;
      if (dropped <= 0) return;
      final written = await _fs.writeFile(
        _filePath,
        '${[lines.first, ...lines.sublist(keepFrom)].join('\n')}\n',
      );
      if (written.isOk) {
        _pruneDroppedRecords(lines.sublist(1, keepFrom));
        onRotationWarning?.call(
          'session hard cap $_hardCapBytes: dropped $dropped oldest '
          'record(s) from ${_filePath.split('/').last} to fit the '
          'incoming one',
        );
      }
    } on Object {
      // Best effort: never fail the append because of the cap.
    }
  }

  /// On-disk size of one JSONL line (UTF-8 bytes + the newline) — the
  /// caps guard an on-disk byte limit, so UTF-16 code units (up to 3x
  /// smaller for CJK/emoji) would undercount.
  static int _lineBytes(String line) => utf8.encode(line).length + 1;

  /// The record ids encoded in [droppedLines]; a torn line contributes
  /// nothing (it left nothing in the index either).
  static Set<String> _droppedRecordIds(List<String> droppedLines) {
    final ids = <String>{};
    for (final line in droppedLines) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map && decoded['id'] is String) {
          ids.add(decoded['id'] as String);
        }
      } on Object {
        // Not a whole JSON line — nothing indexed under it.
      }
    }
    return ids;
  }

  /// Keeps the in-memory index in step with a hard-cap truncation: the
  /// dropped records leave `_entries`/`_byId` (and the label cache) so
  /// the resident storage and a reopened one agree. A dropped leaf
  /// pointer is recomputed by replaying the surviving records, exactly
  /// like the open path does.
  void _pruneDroppedRecords(List<String> droppedLines) {
    final droppedIds = _droppedRecordIds(droppedLines);
    if (droppedIds.isEmpty) return;
    _entries.removeWhere((entry) => droppedIds.contains(entry.id));
    for (final id in droppedIds) {
      _byId.remove(id);
    }
    _labelsById.clear();
    for (final entry in _entries) {
      updateSessionLabelCache(_labelsById, entry);
    }
    final leaf = _currentLeafId;
    if (leaf != null && !_byId.containsKey(leaf)) {
      String? recomputed;
      for (final entry in _entries) {
        recomputed = leafIdAfterSessionRecord(entry);
      }
      _currentLeafId = recomputed;
    }
  }

  /// Size of the active segment in bytes; null when the backend cannot
  /// stat (rotation degrades to the plain append).
  Future<int?> _sessionFileSize() async {
    try {
      final info = await _fs.fileInfo(_filePath);
      return info.valueOrNull?.size;
    } on Object {
      return null;
    }
  }

  int _nextPartSeq() {
    var seq = _partSeq;
    _partSeq = seq + 1;
    return seq;
  }

  /// Lists the `<primary>.part-NN` siblings in rotation order, plus the
  /// highest sequence number seen. Returns null when the listing itself
  /// failed — callers must FAIL CLOSED (an invisible existing part plus
  /// a reset sequence would retarget `.part-0001`, and rename overwrites).
  static Future<({List<String> parts, int maxSeq})?> _listSessionParts(
    FileSystem fs,
    String filePath,
  ) async {
    final dir = _sessionDirOf(filePath);
    final baseName = _sessionBaseName(filePath);
    try {
      final listing = await fs.listDir(dir ?? '.');
      final files = listing.valueOrNull;
      if (files == null) return null;
      final seqs = <int>[];
      for (final file in files) {
        final seq = _parseSessionPartSeq(file.name, baseName);
        if (seq != null) seqs.add(seq);
      }
      seqs.sort();
      final prefix = _sessionDirPrefix(filePath);
      return (
        parts: [
          for (final seq in seqs) '$prefix${sessionPartPath(baseName, seq)}',
        ],
        maxSeq: seqs.isEmpty ? 0 : seqs.last,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<SessionRecord?> getEntry(String id) async => _byId[id];

  @override
  Future<List<SessionRecord>> findEntries(String type) async {
    return [
      for (final entry in _entries)
        if (entry.type == type) entry,
    ];
  }

  @override
  Future<String?> getLabel(String id) async => _labelsById[id];

  @override
  Future<List<SessionRecord>> getPathToRoot(String? leafId) async {
    if (leafId == null) return [];
    final path = <SessionRecord>[];
    // A dangling leaf is healed at load (issue #858), so an unknown id
    // here is a caller bug (issue #1114): fail loudly.
    var current = _byId[leafId];
    if (current == null) {
      throw SessionException(
        'Entry $leafId not found',
        code: SessionErrorCode.notFound,
      );
    }
    while (current != null) {
      path.add(current);
      // An adversarial file can carry a parentId cycle (a→b→a); a
      // legitimate root path can never exceed the record count, so stop
      // there instead of spinning (issue #858 round-1 review).
      if (path.length > _entries.length) break;
      final parentId = current.parentId;
      if (parentId == null) break;
      final parent = _byId[parentId];
      if (parent == null) {
        // A missing parent is a hole, not a fatal corruption: hard-cap
        // truncation (#1114) drops the oldest records by design, and a
        // quarantined/torn mid-file line can take a parent with it
        // (#858). Stop the walk and return the partial path — what
        // WindowedSessionStorage already does at the window edge —
        // instead of crashing every branch walk (auto_compactor,
        // task_executor, …) of a resumed session.
        break;
      }
      current = parent;
    }
    return path.reversed.toList();
  }

  @override
  Future<List<SessionRecord>> getEntries() async => [..._entries];
}
