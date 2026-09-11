/// Windowed [SessionStorage] over a byte-scanned tail of the session file
/// (issue #135): open costs O(window), not O(file).
///
/// The newest chunk is resident; older records prepend on demand
/// ([loadOlder]) straight off the JSONL, and an externally-appended live
/// tail streams in via [ingestAppended]. The file stays the source of
/// truth: every mutation appends one JSON line first, exactly like
/// [JsonlSessionStorage]. Small sessions degenerate cleanly — when the
/// whole file fits in one chunk, the window IS the file and behavior is
/// identical to a full open.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import '../exceptions.dart';
import 'session_chunk_reader.dart';
import 'session_record.dart';
import 'session_storage.dart';

/// Append-only session storage over a byte-scanned window of the file.
///
/// The in-memory index holds the LOADED records only. The branch walk
/// ([getPathToRoot]) stops silently at the window edge — records above the
/// window are reachable only through [loadOlder]. Records read off disk
/// that are NOT on the active branch (side-branch writes interleaved in
/// file order) enter the index for id lookups but never render: the branch
/// walk filters them out (issue #135 pinned fact: a window spans the
/// current branch only).
final class WindowedSessionStorage
    implements SessionStorage, SessionHeaderCache {
  WindowedSessionStorage._(
    this._fs,
    this._filePath,
    this._reader,
    SessionMetadata metadata,
    SessionChunk chunk, {
    int residentRecords = defaultResidentRecords,
    int residentBytes = defaultResidentBytes,
  }) : _metadata = metadata,
       _hasOlder = chunk.hasOlder,
       _windowTopOffset = chunk.isEmpty ? null : chunk.firstOffset,
       _knownFileBytes = chunk.endOffset,
       _residentRecordCap = residentRecords,
       _residentByteCap = residentBytes {
    for (final entry in chunk.entries) {
      _indexEntry(entry.record, offset: entry.offset);
    }
    _currentLeafId = chunk.entries.isEmpty
        ? null
        : leafIdAfterSessionRecord(chunk.entries.last.record);
  }

  /// Resident-window bounds (issue #135 AC1): memory is bounded by the
  /// cache, not the file. Defaults keep ~3 chunks alive; everything
  /// older slides out of the index and counts as "above" again.
  static const defaultResidentRecords = 3 * defaultChunkRecords;
  static const defaultResidentBytes = 3 * defaultChunkBytes;

  final int _residentRecordCap;
  final int _residentByteCap;

  final FileSystem _fs;
  final String _filePath;
  final SessionChunkReader _reader;

  final List<SessionRecord> _entries = [];
  /// File-order start offsets aligned with [_entries] - the byte span of
  /// each resident record, so eviction frees exactly what it drops.
  final List<int> _offsets = [];
  final Map<String, SessionRecord> _byId = {};
  final Map<String, String> _labelsById = {};
  String? _currentLeafId;
  final SessionMetadata _metadata;

  /// Byte offset of the oldest loaded record (the [loadOlder] anchor);
  /// `null` once every record of the file is loaded.
  int? _windowTopOffset;

  /// Byte offset just past the newest loaded record — the ingest cursor.
  int _knownFileBytes;

  bool _hasOlder = false;
  int? _totalRecords;

  /// Resident-window instrumentation (issue #135 AC1: the bound is
  /// asserted by tests, not by user behavior).
  int get residentCount => _entries.length;
  int get residentWindowBytes => _residentWindowBytes;

  @override
  SessionMetadata get cachedMetadata => _metadata;

  /// Whether records may exist above the loaded window (the "more above"
  /// signal while [cachedTotalRecords] is still unknown).
  bool get hasOlder => _hasOlder;

  /// The exact record count once [countRecords] completed; `null` before —
  /// the UI shows "more above" until then.
  int? get cachedTotalRecords => _totalRecords;

  /// The [SessionChunkReader] backing this window (jump support).
  SessionChunkReader get reader => _reader;

  /// Opens a session windowed: header + newest chunk only. Small sessions
  /// load completely (window == file) and behave exactly like
  /// [JsonlSessionStorage.open].
  static Future<WindowedSessionStorage> open(
    FileSystem fs,
    String filePath, {
    int chunkRecords = defaultChunkRecords,
    int chunkBytes = defaultChunkBytes,
    int? residentRecords,
    int? residentBytes,
  }) async {
    final reader = SessionChunkReader(fs: fs, path: filePath);
    final header = await reader.readHeader();
    final chunk = await reader.readTail(
      maxRecords: chunkRecords,
      maxBytes: chunkBytes,
    );
    return WindowedSessionStorage._(
      fs,
      filePath,
      reader,
      headerToSessionMetadata(header, filePath),
      chunk,
      residentRecords: residentRecords ?? defaultResidentRecords,
      residentBytes: residentBytes ?? defaultResidentBytes,
    );
  }

  /// Background record count (streams newlines, no JSON decode). The first
  /// call scans; later calls return the memo.
  Future<int> countRecords() async =>
      _totalRecords ??= await _reader.countRecords();

  /// Loads one chunk of records above the window, prepending them to the
  /// index. Returns the records that JOINED THE ACTIVE BRANCH, root-first —
  /// the transcript delta to render. Side-branch records enter the index
  /// (id lookups) but are not returned. Reads chunks until at least one
  /// branch record lands (a chunk can consist entirely of foreign-branch
  /// records), the file top is reached, or [maxChunks] passes.
  Future<List<SessionRecord>> loadOlder({
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
    int maxChunks = 8,
  }) async {
    final seen = _byId.keys.toSet();
    final joined = <SessionRecord>[];
    for (var pass = 0; pass < maxChunks; pass++) {
      final top = _windowTopOffset;
      if (top == null) break; // whole file already loaded
      final chunk = await _reader.readBefore(
        top,
        maxRecords: maxRecords,
        maxBytes: maxBytes,
      );
      if (chunk.isEmpty) {
        _hasOlder = false;
        break;
      }
      _windowTopOffset = chunk.firstOffset;
      _hasOlder = chunk.hasOlder;
      // Older records extend the window UPWARD: they precede everything
      // loaded so far.
      for (final entry in chunk.entries) {
        _byId[entry.record.id] = entry.record;
        updateSessionLabelCache(_labelsById, entry.record);
      }
      _offsets.insertAll(0, [
        for (final entry in chunk.entries) entry.offset,
      ]);
      _entries.insertAll(0, [
        for (final entry in chunk.entries) entry.record,
      ]);
      if (_currentLeafId != null) {
        for (final record in await getPathToRoot(_currentLeafId)) {
          if (seen.add(record.id)) joined.add(record);
        }
      }
      if (joined.isNotEmpty || !chunk.hasOlder) break;
    }
    _evictToBound();
    return joined;
  }

  /// Streams externally-appended records (a running fa CLI) into the
  /// window. Returns true when new records landed. A file that SHRANK was
  /// truncated or rotated: the window re-anchors to the new tail (issue
  /// #135 E5) and stale offsets are never read.
  Future<bool> ingestAppended() async {
    final info = await _reader.stat();
    if (info == null) return false;
    if (info.size < _knownFileBytes) {
      await _reAnchorToTail();
      return true;
    }
    if (info.size == _knownFileBytes) return false;
    final chunk = await _reader.readForward(_knownFileBytes);
    for (final entry in chunk.entries) {
      _indexEntry(entry.record, offset: entry.offset);
      _currentLeafId = leafIdAfterSessionRecord(entry.record);
    }
    _knownFileBytes = chunk.fileSize;
    // Appended lines are new records in the counted total too - a stale
    // memo would drift the banner count downward (and negative) after
    // every external CLI append.
    if (chunk.entries.isNotEmpty && _totalRecords != null) {
      _totalRecords = _totalRecords! + chunk.entries.length;
    }
    _evictToBound();
    return chunk.entries.isNotEmpty;
  }

  /// Re-reads the tail after an external truncation: the window resets to
  /// the new file tail.
  Future<void> _reAnchorToTail() async {
    final chunk = await _reader.readTail();
    _entries.clear();
    _byId.clear();
    _labelsById.clear();
    _currentLeafId = null;
    _totalRecords = null;
    _windowTopOffset = chunk.isEmpty ? null : chunk.firstOffset;
    _knownFileBytes = chunk.endOffset;
    _hasOlder = chunk.hasOlder;
    _offsets.clear();
    for (final entry in chunk.entries) {
      _indexEntry(entry.record, offset: entry.offset);
    }
    _currentLeafId = chunk.entries.isEmpty
        ? null
        : leafIdAfterSessionRecord(chunk.entries.last.record);
  }

  /// Adds a record to the in-memory index (records that came FROM the
  /// file). Disk-backed appends go through [appendEntry].
  void _indexEntry(SessionRecord record, {int? offset}) {
    _entries.add(record);
    _offsets.add(offset ?? (_offsets.isEmpty ? 0 : _offsets.last));
    _byId[record.id] = record;
    updateSessionLabelCache(_labelsById, record);
  }

  /// Slides the resident window down to its bounds: the oldest records
  /// leave the index and count as "above" again ([loadOlder]'s anchor
  /// advances to the oldest resident record, so a re-tap loads NEW
  /// history instead of re-fetching the evicted zone).
  ///
  /// Returns the number of evicted records.
  int _evictToBound() {
    var evicted = 0;
    while (_entries.length > _residentRecordCap ||
        _residentWindowBytes > _residentByteCap) {
      _entries.removeAt(0);
      _offsets.removeAt(0);
      evicted++;
      if (_offsets.isEmpty) break;
    }
    if (evicted > 0) {
      _windowTopOffset = _offsets.isEmpty ? null : _offsets.first;
      if (_windowTopOffset == null) _hasOlder = false;
    }
    return evicted;
  }

  /// Bytes resident on disk: the window is one contiguous file range
  /// from the oldest indexed record to the ingest cursor.
  int get _residentWindowBytes =>
      _offsets.isEmpty ? 0 : _knownFileBytes - _offsets.first;


  @override
  Future<SessionMetadata> getMetadata() async => _metadata;

  @override
  Future<String?> getLeafId() async => _currentLeafId;

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
    // Serialize with every other writer of this file (a full-open CLI or a
    // second app instance) so concurrent bursts never interleave bytes
    // mid-record — same contract as [JsonlSessionStorage].
    final line = jsonEncode(record.toJson());
    _fsOrThrow(
      await _fs.appendFile(_filePath, '$line\n'),
      'Failed to append session entry ${record.id}',
    );
    _indexEntry(record, offset: _knownFileBytes);
    _currentLeafId = leafIdAfterSessionRecord(record);
    _knownFileBytes += line.length + 1;
    _evictToBound();
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
    while (current != null) {
      path.add(current);
      final parentId = current.parentId;
      if (parentId == null) break;
      final parent = _byId[parentId];
      if (parent == null) break; // window edge: stop, never throw
      current = parent;
    }
    return path.reversed.toList();
  }

  @override
  Future<List<SessionRecord>> getEntries() async => [..._entries];
}

void _fsOrThrow(Result<void, FileError> result, String message) {
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
}
