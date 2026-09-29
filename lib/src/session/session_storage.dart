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

import '../env/execution_env.dart';
import '../env/session_parse_executor.dart';
import '../exceptions.dart';
import '../session_io_retry.dart';
import '../session_line_scanner.dart';
import 'session_record.dart';
import 'uuid.dart';

/// Hard backstop for the full open (gh-1073): a session file larger than
/// this refuses to load whole — the open throws a [SessionErrorCode.
/// tooLarge] [SessionException] naming the windowed resume and
/// `fa session repair` rescue paths instead of exhausting the heap on a
/// multi-GiB read. Range-capable filesystems still stream the file in
/// bounded chunks below the bound; the bound exists so no caller is ever
/// one bad session away from an OOM kill.
const int defaultMaxFullOpenBytes = 2 << 30;

/// Human-readable byte count for the backstop error (GiB/MB granularity).
String _formatBytes(int bytes) {
  if (bytes >= (1 << 30)) {
    return '${(bytes / (1 << 30)).toStringAsFixed(1)} GiB';
  }
  if (bytes >= (1 << 20)) {
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }
  return '$bytes bytes';
}

/// Appends the byte span `(start, end)` to a sorted, disjoint span list,
/// merging into the tail when contiguous (the streamed scan yields lines
/// in file order, so good lines coalesce into one span per run).
void _appendSpan(List<(int, int)> spans, (int, int) span) {
  if (spans.isNotEmpty && spans.last.$2 == span.$1) {
    final (start, _) = spans.removeLast();
    spans.add((start, span.$2));
  } else {
    spans.add(span);
  }
}

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

/// Append-only JSONL session storage on top of a [FileSystem].
///
/// Ported from pi's `JsonlSessionStorage`.
final class JsonlSessionStorage implements SessionStorage, SessionHeaderCache {
  JsonlSessionStorage._(
    this._fs,
    this._filePath,
    SessionHeader header,
    List<SessionRecord> entries,
    String? leafId, {
    int quarantined = 0,
    this._ioRetry = const SessionIoRetryConfig(),
  }) : _metadata = headerToSessionMetadata(header, _filePath),
       _entries = entries,
       _byId = {for (final entry in entries) entry.id: entry},
       _currentLeafId = leafId,
       _quarantinedEntries = quarantined {
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

  /// Milliseconds the last [open] spent inside the file lock (read +
  /// parse + rebuild); the wrapper logs `lock_wait = total - inner`.
  int _openInnerMs = 0;

  /// The header metadata, available synchronously (it is parsed at
  /// construction). Backs [Session.cachedId].
  @override
  SessionMetadata get cachedMetadata => _metadata;

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
    int maxFullOpenBytes = defaultMaxFullOpenBytes,
  }) async {
    final sw = Stopwatch()..start();
    final storage = await withSessionFileLock(
      filePath,
      () => _openLocked(
        fs,
        filePath,
        parseExecutor,
        ioRetry,
        timingLog,
        maxFullOpenBytes,
      ),
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
    int maxFullOpenBytes,
  ) async {
    // gh-1073 backstop: stat first, refuse the pathological full read.
    // The size also bounds the streamed scan below. A 12 GiB session used
    // to die inside readTextFile with `Exhausted heap space` — the refusal
    // names the rescue paths instead.
    final stat = _fsOrThrow(
      await retryTransientSessionFileIo(
        () => fs.fileInfo(filePath),
        op: 'open',
        path: filePath,
        config: ioRetry,
      ),
      'Failed to read session $filePath',
    );
    if (stat.size > maxFullOpenBytes) {
      throw SessionException(
        'Refusing to open session $filePath: ${_formatBytes(stat.size)} '
        'exceeds the ${_formatBytes(maxFullOpenBytes)} full-open bound. '
        'Resume it windowed (`fa --session ${filePath.split('/').last}`) or '
        'shrink the ledger with `fa session repair` — the full open would '
        'exhaust the heap (gh-1073).',
        code: SessionErrorCode.tooLarge,
      );
    }
    final Object maybeRanged = fs;
    if (maybeRanged is RangedReadFileSystem) {
      return _openStreamedLocked(
        fs,
        maybeRanged,
        filePath,
        parseExecutor,
        ioRetry,
        timingLog,
        stat.size,
      );
    }
    return _openWholeFileLocked(fs, filePath, parseExecutor, ioRetry,
        timingLog);
  }

  /// Streamed full open (gh-1073): the JSONL is scanned line by line in
  /// bounded byte chunks ([SessionLineScanner] over [RangedReadFileSystem])
  /// and parsed in bounded batches — the file is NEVER materialized as one
  /// `String`.
  ///
  /// Giant `custom` ledger records (the ~0.5 MB `model_request_summary` /
  /// `shell_job_registry` payloads that grew the ticket's session to
  /// 12.4 GiB) decode HEADER-ONLY ([parseShallowCustomRecord], data
  /// stubbed to null) EXCEPT the latest record per `customType`, whose raw
  /// line is kept and fully parsed at the end — resume-time rehydration
  /// (job board, subagent registry) reads only the latest snapshot, so the
  /// retained payload is exactly what consumers need at a bounded cost of
  /// one giant line per ledger type.
  static Future<JsonlSessionStorage> _openStreamedLocked(
    FileSystem fs,
    RangedReadFileSystem ranged,
    String filePath,
    SessionParseExecutor? parseExecutor,
    SessionIoRetryConfig ioRetry,
    SessionTimingLogger? timingLog,
    int fileSize,
  ) async {
    final totalSw = Stopwatch()..start();
    var phaseSw = Stopwatch()..start();
    final entries = <SessionRecord>[];
    // Merged byte spans of the surviving (good) lines, in file order.
    final goodSpans = <(int, int)>[];
    // Byte spans of torn lines (unmerged — they are rare and disjoint).
    final tornSpans = <(int, int)>[];
    // customType → (index into entries, raw line): the LATEST giant custom
    // per type, fully parsed after the scan (see the method doc).
    final latestGiantCustoms = <String, (int, String)>{};
    SessionHeader? header;
    String? leafId;
    var first = true;
    var batchLines = <String>[];
    var batchSpans = <(int, int)>[];
    var batchFirstLineNumber = 2;

    Future<void> flushBatch() async {
      if (batchLines.isEmpty) return;
      final parsed = await parseSessionLines(
        batchLines,
        filePath: filePath,
        firstLineNumber: batchFirstLineNumber,
        executor: parseExecutor,
        // The ledger payloads are exactly what must not materialize: the
        // batch parse stubs giant canonical `custom` records header-only.
        shallowGiantCustoms: true,
      );
      for (var i = 0; i < parsed.length; i++) {
        final entry = parsed[i];
        final span = batchSpans[i];
        final rawLine = batchLines[i];
        if (entry == null) {
          // A malformed line is a torn write: drop the record, keep its
          // byte span for the quarantine below. Never fatal.
          tornSpans.add(span);
          continue;
        }
        if (entry is CustomRecord &&
            entry.data == null &&
            rawLine.length >= shallowCustomRecordThreshold &&
            rawLine.startsWith('{"type":"custom"')) {
          // Stubbed giant: remember the latest per customType.
          latestGiantCustoms[entry.customType] = (entries.length, rawLine);
        }
        entries.add(entry);
        _appendSpan(goodSpans, span);
        leafId = leafIdAfterSessionRecord(entry);
      }
      batchFirstLineNumber += batchLines.length;
      batchLines = <String>[];
      batchSpans = <(int, int)>[];
    }

    await SessionLineScanner(
      fs: fs,
      path: filePath,
    ).scan((line) async {
      if (first) {
        first = false;
        header = parseSessionHeaderLine(line.text, filePath);
        goodSpans.add((line.start, line.end));
        return;
      }
      if (line.text.trim().isEmpty) return; // blank lines are skipped
      batchLines.add(line.text);
      batchSpans.add((line.start, line.end));
      if (batchLines.length >= sessionParseBatchMaxLines ||
          batchLines.fold<int>(0, (n, l) => n + l.length) >=
              sessionParseBatchMaxBytes) {
        await flushBatch();
      }
    }, fileSize: fileSize);
    if (header == null) _invalidSession(filePath, 'missing session header');
    await flushBatch();
    final readMs = phaseSw.elapsedMilliseconds;
    phaseSw
      ..reset()
      ..start();
    // Rehydrate the LATEST giant custom per ledger type at full fidelity.
    for (final (_, rawLine) in latestGiantCustoms.values) {
      final full = parseSessionEntryLine(rawLine, filePath, 0);
      final index = entries.indexWhere((e) => e.id == full.id);
      if (index >= 0) entries[index] = full;
    }
    final parseMs = phaseSw.elapsedMilliseconds;
    phaseSw
      ..reset()
      ..start();
    var quarantined = 0;
    var rewriteMs = 0;
    if (tornSpans.isNotEmpty) {
      quarantined = tornSpans.length;
      // Forensics sidecar first; read-only storage skips both writes and
      // still loads fine with the torn records simply absent from memory.
      try {
        for (final (start, end) in tornSpans) {
          final raw = await ranged.readRange(filePath, start, end);
          final text = raw.isErr
              ? null
              : utf8.decode(raw.valueOrNull!, allowMalformed: true);
          if (text != null) {
            await fs.appendFile('$filePath.corrupt', '$text\n');
          }
        }
        // Rewrite whole via a streamed span copy into a temp file + atomic
        // rename, so the heal never materializes the good content either.
        // Text decode/encode is byte-exact for every parsed (JSON-valid)
        // line; only genuinely malformed bytes inside a JSON-valid line
        // would re-encode as U+FFFD.
        final Object maybeRenamable = fs;
        if (maybeRenamable is RenamableFileSystem) {
          final tempPath = '$filePath.repaired';
          var wrote = await fs.writeFile(tempPath, '');
          for (final (start, end) in goodSpans) {
            final raw = await ranged.readRange(filePath, start, end);
            if (raw.isErr) break;
            wrote = await fs.appendFile(
              tempPath,
              utf8.decode(raw.valueOrNull!, allowMalformed: true),
            );
            if (wrote.isErr) break;
          }
          if (wrote.isErr) {
            await fs.remove(tempPath, force: true);
          } else {
            final renamed = await maybeRenamable.renamePath(
              tempPath,
              filePath,
            );
            if (renamed.isErr) {
              // Non-renameable after all (or the rename failed): leave the
              // file untouched — the in-memory state is still consistent
              // and the next open re-quarantines the torn lines.
              await fs.remove(tempPath, force: true);
            } else {
              rewriteMs = phaseSw.elapsedMilliseconds;
            }
          }
        }
      } on Object {
        // Read-only storage: the in-memory state is still consistent.
      }
    }
    phaseSw
      ..reset()
      ..start();
    final storage = JsonlSessionStorage._(
      fs,
      filePath,
      header!,
      entries,
      leafId,
      quarantined: quarantined,
      ioRetry: ioRetry,
    );
    final buildMs = phaseSw.elapsedMilliseconds;
    storage._openInnerMs = totalSw.elapsedMilliseconds;
    timingLog?.call(
      'resume_timing open-detail file=${filePath.split('/').last} '
      'mode=full-stream bytes=$fileSize read_ms=$readMs parse_ms=$parseMs '
      'records=${entries.length} torn=$quarantined rewrite_ms=$rewriteMs '
      'build_ms=$buildMs inner_ms=${storage._openInnerMs}',
    );
    return storage;
  }

  /// Legacy whole-file open — the fallback for filesystems without byte
  /// range reads (pure web stores). Identical to the pre-gh-1073 behavior;
  /// the size backstop in [_openLocked] bounds what this can materialize.
  static Future<JsonlSessionStorage> _openWholeFileLocked(
    FileSystem fs,
    String filePath,
    SessionParseExecutor? parseExecutor,
    SessionIoRetryConfig ioRetry,
    SessionTimingLogger? timingLog,
  ) async {
    final totalSw = Stopwatch()..start();
    var phaseSw = Stopwatch()..start();
    final content = _fsOrThrow(
      // Issue #427: the whole-file read behind an open can momentarily
      // fail with a not-found-shaped error on some hosts; a short capped
      // retry rides it out before the open gives up with a named error.
      await retryTransientSessionFileIo(
        () => fs.readTextFile(filePath),
        op: 'open',
        path: filePath,
        config: ioRetry,
      ),
      'Failed to read session $filePath',
    );
    final readMs = phaseSw.elapsedMilliseconds;
    phaseSw
      ..reset()
      ..start();
    final allLines = [
      for (final line in content.split('\n'))
        if (line.trim().isNotEmpty) line,
    ];
    if (allLines.isEmpty) _invalidSession(filePath, 'missing session header');
    final header = parseSessionHeaderLine(allLines.first, filePath);
    final splitMs = phaseSw.elapsedMilliseconds;
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
      filePath: filePath,
      firstLineNumber: 2,
      executor: parseExecutor,
    );
    final parseMs = phaseSw.elapsedMilliseconds;
    phaseSw
      ..reset()
      ..start();
    final entries = <SessionRecord>[];
    final goodLines = <String>[allLines.first];
    final tornLines = <String>[];
    String? leafId;
    for (var i = 0; i < parsed.length; i++) {
      final entry = parsed[i];
      if (entry == null) {
        // A malformed line is a torn write: drop the record, keep the raw
        // bytes for the sidecar below. Never fatal.
        tornLines.add(allLines[i + 1]);
        continue;
      }
      entries.add(entry);
      goodLines.add(allLines[i + 1]);
      leafId = leafIdAfterSessionRecord(entry);
    }
    var quarantined = 0;
    var rewriteMs = 0;
    if (tornLines.isNotEmpty) {
      quarantined = tornLines.length;
      // Forensics sidecar first; read-only storage skips both writes and
      // still loads fine with the torn records simply absent from memory.
      try {
        await fs.appendFile('$filePath.corrupt', '${tornLines.join('\n')}\n');
        await fs.writeFile(filePath, '${goodLines.join('\n')}\n');
        rewriteMs = phaseSw.elapsedMilliseconds;
      } on Object {
        // Read-only storage: the in-memory state is still consistent.
      }
    }
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
      ioRetry: ioRetry,
    );
    final buildMs = phaseSw.elapsedMilliseconds;
    storage._openInnerMs = totalSw.elapsedMilliseconds;
    timingLog?.call(
      'resume_timing open-detail file=${filePath.split('/').last} mode=full '
      'bytes=${content.length} read_ms=$readMs split_ms=$splitMs '
      'parse_ms=$parseMs records=${entries.length} torn=$quarantined '
      'rewrite_ms=$rewriteMs build_ms=$buildMs '
      'inner_ms=${storage._openInnerMs}',
    );
    return storage;
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
    );
  }

  @override
  Future<SessionMetadata> getMetadata() async => _metadata;

  @override
  Future<String?> getLeafId() async {
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
    await withSessionFileLock(_filePath, () async {
      // Issue #427: a transient ENOENT on the record append (the
      // submit-death path) rides a short capped retry instead of losing
      // the record; exhaustion still fails as a named SessionException.
      _fsOrThrow(
        await retryTransientSessionFileIo(
          () => _fs.appendFile(_filePath, '${jsonEncode(record.toJson())}\n'),
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
    var current = _byId[leafId];
    if (current == null) {
      throw SessionException(
        'Entry $leafId not found',
        code: SessionErrorCode.notFound,
      );
    }
    while (true) {
      path.add(current!);
      final parentId = current.parentId;
      if (parentId == null) break;
      final parent = _byId[parentId];
      if (parent == null) {
        throw SessionException(
          'Entry $parentId not found',
          code: SessionErrorCode.invalidSession,
        );
      }
      current = parent;
    }
    return path.reversed.toList();
  }

  @override
  Future<List<SessionRecord>> getEntries() async => [..._entries];
}
