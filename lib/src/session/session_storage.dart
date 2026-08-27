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
import '../exceptions.dart';
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

String? _leafIdAfter(SessionRecord record) {
  return record is LeafRecord ? record.targetId : record.id;
}

void _updateLabelCache(Map<String, String> labelsById, SessionRecord record) {
  if (record is! LabelRecord) return;
  final label = record.label?.trim();
  if (label != null && label.isNotEmpty) {
    labelsById[record.targetId] = label;
  } else {
    labelsById.remove(record.targetId);
  }
}

String _generateEntryId(Map<String, SessionRecord> byId) {
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
Future<T> _withSessionFileLock<T>(
  String filePath,
  Future<T> Function() op,
) {
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

SessionHeader _parseHeaderLine(String line, String filePath) {
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

SessionRecord _parseEntryLine(String line, String filePath, int lineNumber) {
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

SessionMetadata _headerToMetadata(
  SessionHeader header,
  String path, {
  DateTime? lastUpdatedAt,
}) {
  return SessionMetadata(
    id: header.id,
    createdAt: header.timestamp,
    cwd: header.cwd,
    path: path,
    lastUpdatedAt: lastUpdatedAt,
    parentSessionPath: header.parentSessionPath,
    metadata: header.metadata,
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
}) async {
  final lines = _fsOrThrow(
    await fs.readTextLines(filePath, maxLines: 1),
    'Failed to read session header $filePath',
  );
  final line = lines.firstOrNull;
  if (line != null && line.trim().isNotEmpty) {
    return _headerToMetadata(
      _parseHeaderLine(line, filePath),
      filePath,
      lastUpdatedAt: lastUpdatedAt,
    );
  }
  _invalidSession(filePath, 'missing session header');
}

/// Append-only JSONL session storage on top of a [FileSystem].
///
/// Ported from pi's `JsonlSessionStorage`.
final class JsonlSessionStorage implements SessionStorage {
  JsonlSessionStorage._(
    this._fs,
    this._filePath,
    SessionHeader header,
    List<SessionRecord> entries,
    String? leafId, {
    int quarantined = 0,
  }) : _metadata = _headerToMetadata(header, _filePath),
      _entries = entries,
      _byId = {for (final entry in entries) entry.id: entry},
      _currentLeafId = leafId,
      _quarantinedEntries = quarantined {
    for (final entry in entries) {
      _updateLabelCache(_labelsById, entry);
    }
  }

  final FileSystem _fs;
  final String _filePath;
  final SessionMetadata _metadata;
  final List<SessionRecord> _entries;
  final Map<String, SessionRecord> _byId;
  final Map<String, String> _labelsById = {};
  String? _currentLeafId;

  /// How many malformed lines the last [open] quarantined into the
  /// `<file>.corrupt` sidecar (0 for freshly created storages).
  final int _quarantinedEntries;
  int get quarantinedEntries => _quarantinedEntries;

  /// The header metadata, available synchronously (it is parsed at
  /// construction). Backs [Session.cachedId].
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
    String filePath,
  ) async =>
      _withSessionFileLock(filePath, () => _openLocked(fs, filePath));

  static Future<JsonlSessionStorage> _openLocked(
    FileSystem fs,
    String filePath,
  ) async {
    final content = _fsOrThrow(
      await fs.readTextFile(filePath),
      'Failed to read session $filePath',
    );
    final allLines = [
      for (final line in content.split('\n'))
        if (line.trim().isNotEmpty) line,
    ];
    if (allLines.isEmpty) _invalidSession(filePath, 'missing session header');
    final header = _parseHeaderLine(allLines.first, filePath);
    final entries = <SessionRecord>[];
    final goodLines = <String>[allLines.first];
    final tornLines = <String>[];
    String? leafId;
    for (var i = 1; i < allLines.length; i++) {
      try {
        final entry = _parseEntryLine(allLines[i], filePath, i + 1);
        entries.add(entry);
        goodLines.add(allLines[i]);
        leafId = _leafIdAfter(entry);
      } on Object {
        // A malformed line is a torn write: drop the record, keep the raw
        // bytes for the sidecar below. Never fatal.
        tornLines.add(allLines[i]);
      }
    }
    var quarantined = 0;
    if (tornLines.isNotEmpty) {
      quarantined = tornLines.length;
      // Forensics sidecar first; read-only storage skips both writes and
      // still loads fine with the torn records simply absent from memory.
      try {
        await fs.appendFile('$filePath.corrupt', '${tornLines.join('\n')}\n');
        await fs.writeFile(filePath, '${goodLines.join('\n')}\n');
      } on Object {
        // Read-only storage: the in-memory state is still consistent.
      }
    }
    return JsonlSessionStorage._(
      fs,
      filePath,
      header,
      entries,
      leafId,
      quarantined: quarantined,
    );
  }

  /// Creates a new session file with just the header line.
  static Future<JsonlSessionStorage> create(
    FileSystem fs,
    String filePath, {
    required String cwd,
    required String sessionId,
    String? parentSessionPath,
    Map<String, dynamic>? metadata,
  }) async {
    final header = SessionHeader(
      id: sessionId,
      timestamp: DateTime.now(),
      cwd: cwd,
      parentSessionPath: parentSessionPath,
      metadata: metadata,
    );
    await _withSessionFileLock(filePath, () async {
      _fsOrThrow(
        await fs.writeFile(filePath, '${jsonEncode(header.toJson())}\n'),
        'Failed to create session $filePath',
      );
    });
    return JsonlSessionStorage._(fs, filePath, header, [], null);
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
      id: _generateEntryId(_byId),
      parentId: _currentLeafId,
      timestamp: DateTime.now(),
      targetId: leafId,
    );
    await appendEntry(record);
  }

  @override
  Future<String> createEntryId() async => _generateEntryId(_byId);

  @override
  Future<void> appendEntry(SessionRecord record) async {
    // Serialize with every other writer of this file (other appends, an
    // open-time heal rewrite, creation) so concurrent persistence bursts —
    // message records landing while subagent-registry snapshots flush —
    // can never interleave their byte ranges mid-record.
    await _withSessionFileLock(_filePath, () async {
      _fsOrThrow(
        await _fs.appendFile(
          _filePath,
          '${jsonEncode(record.toJson())}\n',
        ),
        'Failed to append session entry ${record.id}',
      );
    });
    _entries.add(record);
    _byId[record.id] = record;
    _updateLabelCache(_labelsById, record);
    _currentLeafId = _leafIdAfter(record);
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
