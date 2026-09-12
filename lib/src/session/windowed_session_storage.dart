/// Windowed [SessionStorage] over a byte-scanned tail of the session file
/// (issue #135): open costs O(window), not O(file).
///
/// The resident window is ANCHORED ON THE TAIL: the newest records are
/// the expensive ones to lose (they are the live conversation), so
/// appends and tail ingests only ever evict the OLDEST side. Paging
/// upward past the residency cap slides the window up instead — the
/// newest side leaves through an explicit user action ([loadOlder]) and
/// comes back through [loadNewer] (the page-down path); it can never
/// vanish silently. The session leaf ([_currentLeafId]) is the TRUE file
/// leaf regardless of what is resident — eviction never rewrites it.
///
/// The view equals the resident window: [loadOlder] returns the records
/// that joined the active branch so the caller can prepend them,
/// [loadNewer] returns the ones that rejoined at the bottom, and
/// [jumpToOffset] re-centers the window anywhere in the file. Every
/// read also feeds the sparse offset map ([offsetOf]) — record byte
/// offsets for everything explored this open — so repeat jumps skip
/// re-reads. Small sessions degenerate cleanly: when the whole file
/// fits in one chunk, the window IS the file.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import '../exceptions.dart';
import 'session_chunk_reader.dart';
import 'session_record.dart';
import 'session_storage.dart';

/// Append-only session storage over a byte-scanned window of the file.
///
/// The in-memory index holds the LOADED records only; every structure
/// (`_entries`, `_byId`, `_labelsById`, offsets) is pruned in the same
/// pass when eviction drops records, so no strong reference outlives
/// residency (issue #135 round-2 review). The branch walk
/// ([getPathToRoot]) stops silently at the window edge — records
/// outside are reachable through [loadOlder]/[loadNewer]/
/// [jumpToOffset]. Side-branch records that share a chunk with the
/// active branch enter the index for id lookups but never render: the
/// branch joins ([_joinBranchUpward]) walk the parent chain only.
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
       _fileSize = chunk.fileSize,
       _fileMtimeMs = chunk.fileMtimeMs,
       _residentRecordCap = residentRecords,
       _residentByteCap = residentBytes {
    _indexChunk(chunk);
    _currentLeafId = chunk.entries.isEmpty
        ? null
        : leafIdAfterSessionRecord(chunk.entries.last.record);
    _branchBottomId = _currentLeafId;
  }

  /// Resident-window bounds (issue #135 AC1): memory is bounded by the
  /// cache, not the file. Defaults keep ~3 chunks alive.
  static const defaultResidentRecords = 3 * defaultChunkRecords;
  static const defaultResidentBytes = 3 * defaultChunkBytes;

  final int _residentRecordCap;
  final int _residentByteCap;

  final FileSystem _fs;
  final String _filePath;
  final SessionChunkReader _reader;

  final List<SessionRecord> _entries = [];

  /// File-order start offsets aligned with [_entries].
  final List<int> _offsets = [];

  /// File-order END offsets aligned with [_entries] (half-open spans
  /// [_offsets[i], _ends[i])) - the byte span of each resident record.
  final List<int> _ends = [];
  final Map<String, SessionRecord> _byId = {};
  final Map<String, String> _labelsById = {};

  /// Sparse offset map (issue #135 AC6): record id → line start offset
  /// for every record whose chunk was read THIS OPEN, evicted or not.
  /// Ints and id strings only — never a record reference — and it dies
  /// with the open (nothing persisted, nothing to invalidate).
  final Map<String, int> _offsetById = {};

  /// Records appended (or read) BELOW the window while deep-paged: the
  /// view branch still needs them reachable ([getEntry] /
  /// [getPathToRoot]) until [loadNewer] pages them in. Entries leave
  /// the moment they re-enter the window; a re-anchor clears it. Bounded
  /// by this open's own writes, not by the file (the live conversation
  /// itself is the bound — the app already holds these records in its
  /// provider context).
  final Map<String, SessionRecord> _appendedBelow = {};

  /// The TRUE session leaf: set at open, advanced by appends/ingests,
  /// reset by re-anchoring — NEVER derived from residency, so eviction
  /// cannot ride it down the file.
  String? _currentLeafId;

  /// The newest ACTIVE-BRANCH record inside the window — the bottom
  /// anchor the branch joins extend. Rides up (to its parent) only when
  /// bottom-side eviction drops it.
  String? _branchBottomId;

  final SessionMetadata _metadata;

  /// Byte offset of the oldest resident record — the [loadOlder] anchor.
  /// Rides up with oldest-side eviction; `null` only for an empty
  /// window over an empty file.
  int? _windowTopOffset;

  /// Byte offset just past the newest resident record — the
  /// [loadNewer]/ingest cursor.
  int _knownFileBytes;

  /// Last-seen file size (truncation guard, append offset math).
  int _fileSize;

  /// Last-seen mtime (same-size rewrite guard, issue #135 AC7); `0`
  /// until the first stat — never triggers a spurious re-anchor.
  int _fileMtimeMs;

  bool _hasOlder = false;
  int? _totalRecords;

  /// File records ABOVE the window (the "Load earlier" banner count),
  /// maintained incrementally; `null` = unknown (right after a jump)
  /// until an edge is walked. Never negative by construction: every
  /// transition is anchored to a byte scan, not to a stale total.
  int? _aboveCount;

  /// File records BELOW the window — what [loadNewer] reveals next
  /// (the page-down count). `null` = unknown (after a jump).
  int? _belowCount = 0;

  /// Resident-window instrumentation (issue #135 AC1: the bound is
  /// asserted by tests, not by user behavior).
  int get residentCount => _entries.length;
  int get residentWindowBytes => _residentWindowBytes;

  @override
  SessionMetadata get cachedMetadata => _metadata;

  /// Whether records may exist above the loaded window (the "more above"
  /// signal while [cachedTotalRecords] is still unknown).
  bool get hasOlder => _hasOlder || (_aboveCount ?? -1) > 0;

  /// Whether records sit below the loaded window (the "Load newer"
  /// signal — the page-down path back to the live tail).
  bool get hasNewer =>
      (_belowCount ?? (_knownFileBytes < _fileSize ? 1 : 0)) > 0;

  /// The exact record count once [countRecords] completed; `null` before —
  /// the UI shows "more above" until then.
  int? get cachedTotalRecords => _totalRecords;

  /// The byte offset of [recordId] if its chunk was ever read this open
  /// (the sparse offset map); `null` for unexplored records.
  int? offsetOf(String recordId) => _offsetById[recordId];

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

  /// File records above the window — the "Load earlier" banner count.
  /// `null` while unknown (background count running, or right after a
  /// [jumpToOffset] until an edge is walked); `0` at the file top.
  Future<int?> countAbove() async {
    if (_aboveCount case final known?) return known;
    if (!_hasOlder) return _aboveCount = 0;
    final below = _belowCount;
    if (below == null) return null;
    final total = await countRecords();
    return _aboveCount = total - _entries.length - below;
  }

  /// File records below the window — the "Load newer" banner count.
  /// `null` while unknown (after a [jumpToOffset]); `0` at the tail.
  int? get countBelow => _belowCount;

  /// Loads one chunk of records above the window. Returns the records
  /// that JOIN THE ACTIVE BRANCH, root-first — the transcript delta to
  /// prepend. Side-branch records in the chunk enter the index (id
  /// lookups) but are not returned. Reads chunks until a branch record
  /// lands (a chunk can be entirely foreign-branch), the branch root or
  /// file top is reached, or [maxChunks] passes. When the residency cap
  /// is exceeded the NEWEST side slides out — deep paging moves the
  /// window up; [loadNewer] (or [jumpToOffset]) brings the tail side
  /// back.
  Future<List<SessionRecord>> loadOlder({
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
    int maxChunks = 8,
  }) async {
    final joined = <SessionRecord>[];
    for (var pass = 0; pass < maxChunks; pass++) {
      final chunk = await _readOlderChunk(maxRecords, maxBytes);
      if (chunk == null) break;
      joined.addAll(_joinBranchUpward(chunk.$1, chunk.$2));
      if (joined.isNotEmpty || !_hasOlder) break;
    }
    _evictToBound(newestSide: true);
    return joined;
  }

  /// One page-up pass: reads the chunk above the window, indexes it
  /// (prepended), advances the window top, and reports the connect id
  /// for the branch join. `null` when no pass applies (no history above,
  /// branch root resident, or the file top reached - `_hasOlder` then
  /// goes false).
  Future<(SessionChunk, String?)?> _readOlderChunk(
    int maxRecords,
    int maxBytes,
  ) async {
    if (!_hasOlder) return null;
    final connectId = await _branchConnectId();
    if (connectId == null) return null; // branch root is already resident
    final top = _windowTopOffset;
    if (top == null) return null;
    final chunk = await _reader.readBefore(
      top,
      maxRecords: maxRecords,
      maxBytes: maxBytes,
    );
    if (chunk.isEmpty) {
      _hasOlder = false;
      return null;
    }
    _windowTopOffset = chunk.firstOffset;
    _hasOlder = chunk.hasOlder;
    _indexChunk(chunk, prepend: true);
    _aboveCount = _aboveCount == null
        ? null
        : _aboveCount! - chunk.entries.length;
    return (chunk, connectId);
  }

  /// Pages one chunk of records back in BELOW the window — the
  /// page-down path after deep paging slid the newest side out.
  /// Returns the records that rejoin the active branch at the bottom,
  /// oldest-first (the transcript delta to append).
  Future<List<SessionRecord>> loadNewer({
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
  }) async {
    final chunk = await _reader.readForward(
      _knownFileBytes,
      maxRecords: maxRecords,
      maxBytes: maxBytes,
    );
    if (chunk.isEmpty) {
      _belowCount = 0;
      return const [];
    }
    _indexChunk(chunk);
    _knownFileBytes = chunk.endOffset;
    if (_belowCount != null) {
      _belowCount = (_belowCount! - chunk.entries.length).clamp(0, 1 << 31);
    }
    if (chunk.endOffset >= _fileSize) _belowCount = 0;
    final joined = _joinBranchDownward(chunk);
    _evictToBound(newestSide: false);
    return joined;
  }

  /// Re-centers the window on the record at [byteOffset] (issue #135
  /// AC6): the window becomes the chunk around the target, the leaf
  /// stays the true file leaf, and both edge counts reset to unknown
  /// until an edge is walked. Returns the branch records inside the new
  /// window, root-first — the transcript replacement delta. Offsets for
  /// repeat jumps come from [offsetOf] without a re-read.
  Future<List<SessionRecord>> jumpToOffset(
    int byteOffset, {
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
  }) async {
    final info = await _reader.stat();
    if (info == null) return const [];
    _fileSize = info.size;
    _fileMtimeMs = info.mtimeMs;
    if (byteOffset < 0 || byteOffset >= info.size) return const [];
    final chunk = await _reader.readAround(
      byteOffset,
      maxRecords: maxRecords,
      maxBytes: maxBytes,
    );
    if (chunk.isEmpty) return const [];
    _replaceWindowWithChunk(chunk);
    _hasOlder = chunk.hasOlder;
    return _branchWithinChunk(chunk, byteOffset);
  }

  /// Jump-to-record (issue #135 AC6, the mechanism the review asked
  /// for): the offset comes from the sparse map when the record was
  /// ever read this open — [SessionChunkReader.locatePassCount] then
  /// stays flat, the "instant" AC6 jump — and only unexplored records
  /// pay the one-pass [SessionChunkReader.locateRecord] seek. Returns
  /// the re-centered branch (root-first) or an empty list on a miss.
  Future<List<SessionRecord>> jumpToRecord(
    String recordId, {
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
  }) async {
    final offset =
        _offsetById[recordId] ?? await _reader.locateRecord(recordId);
    if (offset == null) return const [];
    return jumpToOffset(offset, maxRecords: maxRecords, maxBytes: maxBytes);
  }

  /// The active branch as currently RESIDENT, root-first — the view
  /// baseline. Bounded by the residency cap by construction (issue
  /// #135 round 4: the app layer must not re-accumulate what the
  /// storage evicted).
  Future<List<SessionRecord>> currentBranch() => _windowBranch();

  Future<({bool reanchored, List<SessionRecord> delta})>
  ingestAppended() async {
    final info = await _reader.stat();
    if (info == null) {
      return (reanchored: false, delta: const <SessionRecord>[]);
    }
    final previousSize = _fileSize;
    if (info.size < previousSize) {
      await _reAnchorToTail();
      return (reanchored: true, delta: await _windowBranch());
    }
    // Same size but the file was REWRITTEN (mtime moved — issue #135
    // AC7): bytes under the window may differ; re-anchor to the tail
    // with the truncation notice rather than trust stale residency.
    if (info.size == previousSize) {
      if (info.mtimeMs != _fileMtimeMs && _fileMtimeMs != 0) {
        await _reAnchorToTail();
        return (reanchored: true, delta: await _windowBranch());
      }
      return (reanchored: false, delta: const <SessionRecord>[]);
    }
    _fileSize = info.size;
    _fileMtimeMs = info.mtimeMs;
    if (_knownFileBytes != previousSize) {
      return _ingestBelowWindow();
    }
    return _ingestAtTail();
  }

  /// Deep-paged ingest: the appended lines land BELOW the window. They
  /// are counted (and their offsets remembered for jumps) without being
  /// indexed - paging down re-reads the range.
  Future<({bool reanchored, List<SessionRecord> delta})>
  _ingestBelowWindow() async {
    final chunk = await _reader.readForward(_knownFileBytes);
    for (final entry in chunk.entries) {
      _offsetById[entry.record.id] = entry.offset;
      _appendedBelow[entry.record.id] = entry.record;
    }
    if (_belowCount != null) {
      _belowCount = _belowCount! + chunk.entries.length;
    }
    return (reanchored: false, delta: const <SessionRecord>[]);
  }

  /// Tail-anchored ingest: the appended lines extend the window bottom
  /// directly. The delta is the part of the branch below the old bottom.
  Future<({bool reanchored, List<SessionRecord> delta})> _ingestAtTail() async {
    final chunk = await _reader.readForward(_knownFileBytes);
    _indexChunk(chunk);
    if (chunk.entries.isNotEmpty) {
      _currentLeafId = leafIdAfterSessionRecord(chunk.entries.last.record);
    }
    _knownFileBytes = chunk.endOffset;
    // Appended lines are new records in the counted total too - a stale
    // memo would drift the banner count downward after every external
    // CLI append.
    if (chunk.entries.isNotEmpty && _totalRecords != null) {
      _totalRecords = _totalRecords! + chunk.entries.length;
    }
    final delta = <SessionRecord>[];
    final path = await getPathToRoot(_currentLeafId);
    final bottomIndex = path.indexWhere((r) => r.id == _branchBottomId);
    if (bottomIndex >= 0) {
      delta.addAll(path.skip(bottomIndex + 1));
      _branchBottomId = path.last.id;
    }
    _evictToBound(newestSide: false);
    return (reanchored: false, delta: delta);
  }

  /// Re-reads the tail after an external truncation: the window resets to
  /// the new file tail.
  Future<void> _reAnchorToTail() async {
    final chunk = await _reader.readTail();
    _fileSize = chunk.fileSize;
    _fileMtimeMs = chunk.fileMtimeMs;
    _totalRecords = null;
    _aboveCount = null;
    _belowCount = 0;
    _offsetById.clear(); // offsets into the truncated file are garbage
    _replaceWindowWithChunk(chunk);
    _hasOlder = chunk.hasOlder;
    _currentLeafId = chunk.entries.isEmpty
        ? null
        : leafIdAfterSessionRecord(chunk.entries.last.record);
    _branchBottomId = _currentLeafId;
  }

  /// The parent id of the oldest branch record in the window — the
  /// connecting record the next [loadOlder] chunk must contain.
  Future<String?> _branchConnectId() async {
    final path = await getPathToRoot(_branchBottomId);
    return path.isEmpty ? null : path.first.parentId;
  }

  /// Records of the freshly-read chunk (above the window) that join the
  /// active branch, root-first: walk parents from the connecting record
  /// ([connectId]) while the chain stays inside the chunk.
  List<SessionRecord> _joinBranchUpward(SessionChunk chunk, String? connectId) {
    if (connectId == null) return const [];
    final byId = {
      for (final entry in chunk.entries) entry.record.id: entry.record,
    };
    final joined = <SessionRecord>[];
    SessionRecord? current = byId[connectId];
    while (current != null) {
      joined.add(current);
      final parentId = current.parentId;
      current = parentId == null ? null : byId[parentId];
    }
    return joined.reversed.toList();
  }

  /// Records of the freshly-read chunk (below the window) that rejoin
  /// the active branch, oldest-first: follow the single-child chain
  /// down from the branch bottom. A fork in the fresh range stops the
  /// walk — the next [loadNewer] (or a jump) resolves it.
  List<SessionRecord> _joinBranchDownward(SessionChunk chunk) {
    final bottom = _branchBottomId;
    if (bottom == null) return const [];
    final childrenByParent = <String, List<SessionRecord>>{};
    for (final entry in chunk.entries) {
      final parentId = entry.record.parentId;
      if (parentId == null) continue;
      childrenByParent.putIfAbsent(parentId, () => []).add(entry.record);
    }
    final joined = <SessionRecord>[];
    var current = bottom;
    while (childrenByParent[current]?.length == 1) {
      final record = childrenByParent[current]!.single;
      joined.add(record);
      _branchBottomId = record.id;
      current = record.id;
    }
    return joined;
  }

  /// The branch records inside a jump chunk around [byteOffset]:
  /// ancestors of the target up to the chunk top, then the single-child
  /// chain down to the chunk bottom. Sets the window's branch bottom.
  List<SessionRecord> _branchWithinChunk(SessionChunk chunk, int byteOffset) {
    var target = chunk.entries.last.record;
    for (final entry in chunk.entries) {
      if (entry.offset <= byteOffset) target = entry.record;
    }
    final byId = {
      for (final entry in chunk.entries) entry.record.id: entry.record,
    };
    final ups = <SessionRecord>[target];
    var walker = target;
    while (walker.parentId != null && byId[walker.parentId!] != null) {
      walker = byId[walker.parentId!]!;
      ups.add(walker);
    }
    final childrenByParent = <String, List<SessionRecord>>{};
    for (final entry in chunk.entries) {
      final parentId = entry.record.parentId;
      if (parentId == null) continue;
      childrenByParent.putIfAbsent(parentId, () => []).add(entry.record);
    }
    final downs = <SessionRecord>[];
    var current = target;
    while (childrenByParent[current.id]?.length == 1) {
      final record = childrenByParent[current.id]!.single;
      downs.add(record);
      current = record;
    }
    _branchBottomId = downs.isEmpty ? target.id : downs.last.id;
    return [...ups.reversed, ...downs];
  }

  /// The active branch as currently resident, root-first (the view
  /// baseline after a truncation re-anchor).
  Future<List<SessionRecord>> _windowBranch() => getPathToRoot(_branchBottomId);

  /// Indexes a chunk's records into the window. [prepend] inserts above
  /// the window (loadOlder); otherwise the chunk extends the bottom.
  void _indexChunk(SessionChunk chunk, {bool prepend = false}) {
    if (chunk.isEmpty) return;
    void add(SessionChunkEntry entry, int end) {
      _offsetById[entry.record.id] = entry.offset;
      if (prepend) {
        _entries.insert(0, entry.record);
        _offsets.insert(0, entry.offset);
        _ends.insert(0, end);
      } else {
        _entries.add(entry.record);
        _offsets.add(entry.offset);
        _ends.add(end);
      }
      _byId[entry.record.id] = entry.record;
      _appendedBelow.remove(entry.record.id);
      updateSessionLabelCache(_labelsById, entry.record);
    }

    // The byte END of entry i: the next entry's start, or for the last
    // entry its own line end — chunk.endOffset is NOT the chunk's end for
    // readAround chunks (it is the file EOF there).
    int endOf(int i) {
      final entry = chunk.entries[i];
      return i + 1 < chunk.entries.length
          ? chunk.entries[i + 1].offset
          : entry.offset + entry.bytes + 1;
    }

    // Prepending iterates newest-first: each insert lands at index 0, so
    // the oldest entry must go in LAST to keep file order.
    final first = prepend ? chunk.entries.length - 1 : 0;
    final step = prepend ? -1 : 1;
    for (var i = first; i >= 0 && i < chunk.entries.length; i += step) {
      add(chunk.entries[i], endOf(i));
    }
  }

  /// Adds a record to the in-memory index (records that came FROM the
  /// file). Disk-backed appends go through [appendEntry].
  void _indexEntry(
    SessionRecord record, {
    required int start,
    required int end,
  }) {
    _offsetById[record.id] = start;
    _entries.add(record);
    _offsets.add(start);
    _ends.add(end);
    _byId[record.id] = record;
    _appendedBelow.remove(record.id);
    updateSessionLabelCache(_labelsById, record);
  }

  /// Resets the whole window to [chunk] (jump / re-anchor): every
  /// structure is rebuilt, the sparse offset map keeps its history, the
  /// leaf survives.
  void _replaceWindowWithChunk(SessionChunk chunk) {
    _entries.clear();
    _offsets.clear();
    _ends.clear();
    _byId.clear();
    _appendedBelow.clear();
    _labelsById.clear();
    _windowTopOffset = chunk.isEmpty ? null : chunk.firstOffset;
    _knownFileBytes = chunk.entries.isEmpty
        ? chunk.endOffset
        : chunk.entries.last.offset + chunk.entries.last.bytes + 1;
    _aboveCount = null;
    _belowCount = chunk.isEmpty ? 0 : null;
    _indexChunk(chunk);
  }

  /// Slides the window to its bounds. [newestSide] picks WHICH side
  /// gives way — the two directions are the review's core contract:
  ///
  /// - `false` (appends, tail ingests, page-downs): the OLDEST records
  ///   drop. The live tail can never fall out of the window this way,
  ///   and the leaf never moves.
  /// - `true` (deep [loadOlder] paging): the NEWEST records drop. This
  ///   only happens because the user paged up past the cap, and the
  ///   tail side is one [loadNewer] away.
  ///
  /// Every dropped record is pruned from ALL side structures — the
  /// index, the id/label caches — so nothing stays strongly referenced
  /// past residency.
  int _evictToBound({required bool newestSide}) {
    var evicted = 0;
    while (_entries.isNotEmpty &&
        (_entries.length > _residentRecordCap ||
            _residentWindowBytes > _residentByteCap)) {
      if (newestSide) {
        _dropNewest();
      } else {
        _dropOldest();
      }
      evicted++;
    }
    if (evicted > 0 && !newestSide) _hasOlder = true;
    return evicted;
  }

  void _dropOldest() {
    final record = _entries.removeAt(0);
    _offsets.removeAt(0);
    _ends.removeAt(0);
    _byId.remove(record.id);
    _labelsById.remove(record.id);
    if (_offsets.isNotEmpty) _windowTopOffset = _offsets.first;
    if (_aboveCount != null) _aboveCount = _aboveCount! + 1;
  }

  void _dropNewest() {
    final record = _entries.removeLast();
    _offsets.removeLast();
    _ends.removeLast();
    _byId.remove(record.id);
    _labelsById.remove(record.id);
    if (_branchBottomId == record.id) {
      _branchBottomId = record.parentId;
    }
    if (_ends.isNotEmpty) _knownFileBytes = _ends.last;
    if (_belowCount != null) _belowCount = _belowCount! + 1;
  }

  /// Bytes resident on disk: the resident records form one contiguous
  /// file range from the oldest record's start to the newest record's
  /// end.
  int get _residentWindowBytes =>
      _ends.isEmpty ? 0 : _ends.last - _offsets.first;

  @override
  Future<SessionMetadata> getMetadata() async => _metadata;

  @override
  Future<String?> getLeafId() async => _currentLeafId;

  @override
  Future<void> setLeafId(String? leafId) async {
    if (leafId != null &&
        !(_byId.containsKey(leafId) ||
            _appendedBelow.containsKey(leafId) ||
            await _locateEntryOrNull(leafId) != null) &&
        leafId != _currentLeafId) {
      throw SessionException(
        'Entry $leafId not found',
        code: SessionErrorCode.notFound,
      );
    }
    final previousLeaf = _currentLeafId;
    final record = LeafRecord(
      id: generateSessionEntryId(_byId),
      parentId: _currentLeafId,
      timestamp: DateTime.now(),
      targetId: leafId,
    );
    await appendEntry(record);
    _branchBottomId = _currentLeafId;
    // Branch switch (issue #135 AC10): the window re-centers on the
    // TARGET branch's tail — the previous branch's resident records
    // must not render. A null target (move to root) keeps the window;
    // the branch walk from the root re-derives the first branch.
    if (leafId != null && leafId != previousLeaf) {
      await _recentreOnBranch(leafId);
    }
  }

  /// Re-centers the window on [leafId]'s own branch tail (the AC10
  /// branch-switch re-center): previous-branch residency is dropped, so
  /// no foreign-branch record can render.
  Future<void> _recentreOnBranch(String leafId) async {
    final known =
        _byId.containsKey(leafId) || _appendedBelow.containsKey(leafId);
    final offset = known
        ? _offsetById[leafId] ?? await _reader.locateRecord(leafId)
        : await _reader.locateRecord(leafId);
    if (offset == null) return;
    final chunk = await _reader.readAround(offset);
    if (chunk.isEmpty) return;
    _replaceWindowWithChunk(chunk);
    _hasOlder = chunk.hasOlder;
    _branchBottomId = leafId;
    _currentLeafId = leafId;
    _aboveCount = null;
    _belowCount = null;
  }

  @override
  Future<String> createEntryId() async => generateSessionEntryId(_byId);

  @override
  Future<void> appendEntry(SessionRecord record) async {
    // Serialize with every other in-process writer of this file (a
    // full-open JsonlSessionStorage on the same path — issue #135
    // round-4 review): concurrent bursts must never interleave bytes
    // mid-record. Same contract as [JsonlSessionStorage].
    final line = jsonEncode(record.toJson());
    await withSessionFileLock(_filePath, () async {
      _fsOrThrow(
        await _fs.appendFile(_filePath, '$line\n'),
        'Failed to append session entry ${record.id}',
      );
      final info = await _reader.stat();
      final start = info == null
          ? _knownFileBytes
          : info.size - line.length - 1;
      _fileSize = start + line.length + 1;
      _fileMtimeMs = info?.mtimeMs ?? _fileMtimeMs;
      _offsetById[record.id] = start;
      final leaf = leafIdAfterSessionRecord(record);
      if (_knownFileBytes == start) {
        // Window bottom is the file tail: the record extends it.
        final chained =
            record.parentId == _branchBottomId ||
            record is LeafRecord && record.parentId == _branchBottomId;
        _indexEntry(record, start: start, end: _fileSize);
        _knownFileBytes = _fileSize;
        if (chained) _branchBottomId = leaf;
      } else if (_belowCount != null) {
        // Deep-paged: the record lands below the window and pages in later.
        _belowCount = _belowCount! + 1;
        _appendedBelow[record.id] = record;
      }
      _currentLeafId = leaf;
    });
    _evictToBound(newestSide: false);
  }

  @override
  Future<SessionRecord?> getEntry(String id) async {
    final resident = _byId[id] ?? _appendedBelow[id];
    if (resident != null) return resident;
    return _locateEntryOrNull(id);
  }

  /// Reads [id] straight from the file when it is not resident (a
  /// foreign-branch target of [setLeafId] — issue #135 AC10): one
  /// bounded seek, no window change.
  Future<SessionRecord?> _locateEntryOrNull(String id) async {
    final offset = await _reader.locateRecord(id);
    if (offset == null) return null;
    final chunk = await _reader.readForward(offset, maxRecords: 1);
    for (final entry in chunk.entries) {
      if (entry.record.id == id) return entry.record;
    }
    return null;
  }

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
    var current = _byId[leafId] ?? _appendedBelow[leafId];
    while (current != null) {
      path.add(current);
      final parentId = current.parentId;
      if (parentId == null) break;
      final parent = _byId[parentId] ?? _appendedBelow[parentId];
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
