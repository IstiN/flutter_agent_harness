/// Windowed reads over an append-only JSONL session file.
///
/// Issue #135: opening a session must cost O(window), not O(file). The
/// reader byte-scans the JSONL backward with a doubling window (exactly
/// `tail -n` semantics) and parses only the records it keeps, so a
/// multi-hundred-MB session opens by touching the last ~200 records.
/// Record-atomic by construction: JSONL lines are never split, and the dual
/// chunk cap (`maxRecords` AND `maxBytes`) bounds memory even when a single
/// image / `model_request_summary` record is megabytes wide.
///
/// Pure Dart over the [FileSystem] abstraction — hosts without seekable
/// files probe [SessionChunkReader.canReadRanges] and keep the full-load
/// path.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../env/execution_env.dart';
import '../exceptions.dart';
import '../env/session_parse_executor.dart';
import 'session_record.dart';
import 'session_storage.dart';

/// Default records per chunk (issue #135 open question — 200 recommended).
const int defaultChunkRecords = 200;

/// Default byte cap per chunk: a record-count cap alone does not bound
/// memory (one image record can be megabytes), so a chunk stops at whichever
/// cap fills first.
const int defaultChunkBytes = 8 << 20;

/// Parse-cache capacity (issue #1498): distinct lines remembered per
/// reader. Bounded so a marathon open cannot grow it without limit.
const int defaultParseCacheEntries = 4096;

/// Parse-cache raw-line byte budget (issue #1498): the sum of remembered
/// line lengths stays under this regardless of the entry count.
const int defaultParseCacheBytes = 32 << 20;

/// One parsed record with the byte range it occupies in the session file.
///
/// [offset] is the byte offset of the record's line start — the anchor the
/// next [SessionChunkReader.readBefore] (or a jump) seeks from.
final class SessionChunkEntry {
  const SessionChunkEntry({
    required this.offset,
    required this.bytes,
    required this.record,
  });

  /// Byte offset of the record's line start.
  final int offset;

  /// Line length in bytes, excluding the trailing newline.
  final int bytes;

  final SessionRecord record;
}

/// One chunk read off the session file: records oldest-first plus the file
/// facts the window cache needs (staleness re-anchors, "N above" labels).
final class SessionChunk {
  const SessionChunk({
    required this.entries,
    required this.fileSize,
    required this.fileMtimeMs,
    required this.hasOlder,
    required this.limitOffset,
  });

  /// Parsed records, oldest first. Torn (unparseable) lines are skipped.
  final List<SessionChunkEntry> entries;

  /// File size (bytes) at read time.
  final int fileSize;

  /// File mtime (ms since epoch) at read time.
  final int fileMtimeMs;

  /// Whether at least one record exists above the first entry's offset —
  /// the "more above" signal while the exact count is still unknown.
  final bool hasOlder;

  /// Exclusive end of the scan that produced this chunk (the anchor for
  /// `readBefore`, EOF for `readTail`/`readForward`) — the ingest cursor.
  final int limitOffset;

  bool get isEmpty => entries.isEmpty;

  /// Byte offset of the first (oldest) record — [limitOffset] when empty.
  int get firstOffset => entries.isEmpty ? limitOffset : entries.first.offset;

  /// Byte offset just past the scanned range — where live-tail ingest
  /// resumes (a line boundary).
  int get endOffset => limitOffset;
}

/// Backward/forward byte-scan reader over one JSONL session file.
///
/// All reads are record-atomic: a window is grown until its oldest boundary
/// sits on a record start, so a record straddling the initial read window is
/// never truncated (issue #135 E1) — the window doubles until the whole
/// record is inside, bounded only by the file length.
///
/// The parse cache (issue #1498) assumes the session JSONL is APPEND-ONLY:
/// entries survive observed growth and are dropped on any observed shrink
/// or mtime anomaly (see [_noteParseCacheStamp]). A writer that rewrites
/// earlier bytes in place while keeping size AND mtime is unobservable at
/// that granularity — the same signal the windowed storage itself relies
/// on — and would serve stale records.
final class SessionChunkReader {
  /// Creates a reader over [path]. [startWindowBytes] is the first backward
  /// read size; it doubles up to the file length as needed. The parse cache
  /// ([parseCacheEntries] × [parseCacheBytes], issue #1498) remembers
  /// parsed lines across scans — `0` entries disables it.
  SessionChunkReader({
    required this.fs,
    required this.path,
    this.startWindowBytes = 128 << 10,
    this.parseExecutor,
    this.parseCacheEntries = defaultParseCacheEntries,
    this.parseCacheBytes = defaultParseCacheBytes,
  });

  /// Remembered distinct lines (issue #1498).
  final int parseCacheEntries;

  /// Remembered raw-line bytes across all cached lines (issue #1498).
  /// `0` means no byte budget (the entry cap still applies); combined
  /// with [parseCacheEntries] `0` the cache is fully disabled.
  final int parseCacheBytes;

  /// The store backing [path].
  final FileSystem fs;
  final String path;

  /// Where record parsing runs — `null` keeps the inline batched path
  /// (web); IO hosts inject the isolate executor (issue #199).
  final SessionParseExecutor? parseExecutor;
  final int startWindowBytes;

  /// Cache marker for a line that failed to parse (torn or foreign):
  /// the failed probe is remembered too, so re-visited windows skip the
  /// decode attempt on junk lines as well. Values in [_parseCache] are
  /// either a [SessionChunkEntry] or this marker — a record instance can
  /// never collide with it.
  static const Object _tornLine = 'torn';

  /// A line wider than this is never cached (issue #1498): a handful of
  /// megabyte-wide image records would flood the byte budget; they re-parse
  /// instead, amortized by their rarity.
  static const int _parseCacheMaxLineBytes = 4 << 20;

  /// Parsed lines keyed by the line's (offset, byteLength, shallow) — the
  /// shallow flag in the key keeps the resume walk's header-only giant
  /// customs from ever serving a full-fidelity read (and vice versa, where
  /// a full record would change what the walk observes). Insertion order
  /// drives the FIFO eviction.
  final Map<(int, int, bool), Object> _parseCache = {};
  int _parseCacheBytesUsed = 0;

  /// Last file facts the cache was validated against ([stat] reports the
  /// transition; growth keeps entries — the append-only contract means
  /// older lines never change — a shrink or same-size mtime move clears).
  int _parseCacheStampSize = -1;
  int _parseCacheStampMtimeMs = -1;

  /// Lines the cache saved from decode+parse (issue #1498 instrumentation,
  /// the [locatePassCount] precedent): a repeat scan must add misses, not
  /// parse work.
  int get parseCacheHitCount => _parseCacheHits;
  int get parseCacheMissCount => _parseCacheMisses;
  int get parseCacheEntryCount => _parseCache.length;
  int _parseCacheHits = 0;
  int _parseCacheMisses = 0;

  /// Cache probe for one raw line: `(hit, entry)` — a hit with a null
  /// entry is a known-torn line. Counter-free: the hit/miss counters
  /// belong to the scan paths, where a miss means decode+parse work
  /// actually done (a probed-but-never-reached line is not a parse).
  (bool, SessionChunkEntry?) _parseCacheLookup(
    int offset,
    int bytes,
    bool shallow,
  ) {
    final value = _parseCache[(offset, bytes, shallow)];
    if (value == null) return (false, null);
    _parseCacheHits++;
    return (true, value == _tornLine ? null : value as SessionChunkEntry);
  }

  void _parseCacheStore(SessionChunkEntry entry, bool shallow) {
    if (parseCacheEntries <= 0 || entry.bytes > _parseCacheMaxLineBytes) {
      return;
    }
    _parseCache[(entry.offset, entry.bytes, shallow)] = entry;
    _parseCacheBytesUsed += entry.bytes;
    _evictParseCache();
  }

  void _parseCacheStoreTorn(int offset, int bytes, bool shallow) {
    if (parseCacheEntries <= 0 || bytes > _parseCacheMaxLineBytes) return;
    _parseCache[(offset, bytes, shallow)] = _tornLine;
    _parseCacheBytesUsed += bytes;
    _evictParseCache();
  }

  void _evictParseCache() {
    while (_parseCache.length > parseCacheEntries ||
        (parseCacheBytes > 0 && _parseCacheBytesUsed > parseCacheBytes)) {
      if (_parseCache.isEmpty) {
        _parseCacheBytesUsed = 0;
        return;
      }
      final first = _parseCache.keys.first;
      _parseCacheBytesUsed -= first.$2;
      _parseCache.remove(first);
    }
  }

  /// Re-validates the cache against the observed file facts. The cache
  /// leans on the session format's APPEND-ONLY contract: growth with an
  /// mtime move keeps entries (older lines never change); a SHRINK
  /// (truncation or segment rotation), a same-size mtime move (the
  /// rewrite signal `WindowedSessionStorage.ingestAppended` uses), or
  /// growth WITHOUT an mtime move (indistinguishable from an in-place
  /// rewrite at this granularity) drops everything. Residual risk,
  /// shared with the storage's own rewrite detection: a same-size
  /// rewrite landing inside one mtime tick is unobservable — a writer
  /// that rewrites earlier bytes MUST shrink the file or move mtime
  /// (the format's writers do both by construction).
  void _noteParseCacheStamp(int size, int mtimeMs) {
    if (_parseCacheStampSize >= 0 &&
        (size < _parseCacheStampSize ||
            (size == _parseCacheStampSize &&
                mtimeMs != _parseCacheStampMtimeMs) ||
            (size > _parseCacheStampSize &&
                mtimeMs == _parseCacheStampMtimeMs))) {
      _parseCache.clear();
      _parseCacheBytesUsed = 0;
    }
    _parseCacheStampSize = size;
    _parseCacheStampMtimeMs = mtimeMs;
  }

  /// Whether the backing filesystem supports byte-range reads. Hosts without
  /// it keep the whole-file load path.
  bool get canReadRanges => fs is RangedReadFileSystem;

  /// Reads up to the newest [maxRecords] records (bounded by [maxBytes]).
  Future<SessionChunk> readTail({
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
  }) => _scanBackward(maxRecords: maxRecords, maxBytes: maxBytes);

  /// Reads up to [maxRecords] records immediately above [anchorOffset] (the
  /// byte offset of a record start — typically a previous chunk's
  /// [SessionChunk.firstOffset]).
  Future<SessionChunk> readBefore(
    int anchorOffset, {
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
  }) => _scanBackward(
    endExclusive: anchorOffset,
    maxRecords: maxRecords,
    maxBytes: maxBytes,
  );

  /// Boundary-walk block read (issue #503): ONE strip of up to [maxBytes]
  /// immediately above [anchorOffset], trimmed to the newest [maxRecords]
  /// records. Unlike the capped [readBefore] — whose doubling window
  /// re-splits and re-decodes its whole buffer on every pass — every byte
  /// here is read, decoded and parsed exactly once, so a deep resume walk
  /// costs one linear pass over the span instead of ~5x the parse work
  /// (a 400 MB tail-after-compaction walked 10s+ through [readBefore]).
  ///
  /// A single record wider than the strip re-reads with a doubled span
  /// until it fits (pathological giant lines only). When the strip reaches
  /// the file top the header line (offset 0) is dropped; [SessionChunk.
  /// hasOlder] stays true when the record cap trimmed or the strip started
  /// mid-file.
  Future<SessionChunk> readBlockBefore(
    int anchorOffset, {
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
    bool shallowGiantCustoms = false,
  }) async {
    final info = await stat();
    if (info == null) {
      throw SessionException(
        'Session not found: $path',
        code: SessionErrorCode.notFound,
      );
    }
    final limit = anchorOffset < info.size ? anchorOffset : info.size;
    SessionChunk chunk(List<SessionChunkEntry> entries, bool hasOlder) =>
        SessionChunk(
          entries: entries,
          fileSize: info.size,
          fileMtimeMs: info.mtimeMs,
          hasOlder: hasOlder,
          limitOffset: limit,
        );
    if (limit <= 0) return chunk(const [], false);
    final (lines, reachedTop) = await _readStripLines(limit, maxBytes);
    var entries = await _parseAllLines(
      lines,
      shallowGiantCustoms: shallowGiantCustoms,
    );
    var hasOlder = !reachedTop;
    if (entries.length > maxRecords) {
      entries = entries.sublist(entries.length - maxRecords);
      hasOlder = true;
    }
    if (reachedTop) {
      // File top: the offset-0 line is the session header, not a record.
      entries = [
        for (final entry in entries)
          if (entry.offset != 0) entry,
      ];
    }
    return chunk(entries, hasOlder);
  }

  /// The raw lines of one strip above [limit], span-grown (×2 per pass)
  /// until at least one COMPLETE line fits or the file top is reached —
  /// the giant-line escape of [readBlockBefore] (a record wider than the
  /// first strip straddles it whole). Returns the parseable lines (the
  /// partial first segment of a mid-file strip already dropped) plus
  /// whether the strip reached the file top.
  Future<(List<(int, Uint8List)>, bool)> _readStripLines(
    int limit,
    int maxBytes,
  ) async {
    var span = maxBytes;
    while (true) {
      final lo = limit - span > 0 ? limit - span : 0;
      final bytes = await _readRange(lo, limit);
      var lines = _splitLines(bytes, lo);
      // The first segment of a mid-file strip is the TAIL of a record that
      // begins above the strip — not parseable on its own.
      if (lo > 0 && lines.isNotEmpty) lines = lines.sublist(1);
      if (lines.isNotEmpty || lo == 0) return (lines, lo == 0);
      span *= 2; // a single record straddles the whole strip: widen
    }
  }

  /// Reads a window centered on the record at [byteOffset] (a jump target):
  /// the record itself, the newer records below it, and older records above
  /// it, bounded by the same dual cap.
  Future<SessionChunk> readAround(
    int byteOffset, {
    int maxRecords = defaultChunkRecords,
    int maxBytes = defaultChunkBytes,
  }) async {
    final info = await stat();
    if (info == null) {
      throw SessionException(
        'Session not found: $path',
        code: SessionErrorCode.notFound,
      );
    }
    if (byteOffset >= info.size) {
      return SessionChunk(
        entries: const [],
        fileSize: info.size,
        fileMtimeMs: info.mtimeMs,
        hasOlder: false,
        limitOffset: byteOffset,
      );
    }
    // Forward part first: the target record plus half the budget below it,
    // so records above the target (the older half) keep room.
    final forwardRecords = 1 + (maxRecords - 1) ~/ 2;
    final forward = await readForward(byteOffset, maxRecords: forwardRecords);
    var budgetRecords = maxRecords - forward.entries.length;
    var budgetBytes = maxBytes - _bytesOf(forward.entries);
    final backward = await _scanBackward(
      endExclusive: byteOffset,
      maxRecords: budgetRecords < 0 ? 0 : budgetRecords,
      maxBytes: budgetBytes < 0 ? 0 : budgetBytes,
    );
    return SessionChunk(
      entries: [...backward.entries, ...forward.entries],
      fileSize: info.size,
      fileMtimeMs: info.mtimeMs,
      // Anything above the backward part means older history remains.
      hasOlder: backward.hasOlder,
      limitOffset: info.size,
    );
  }

  /// Reads records from the line boundary [fromOffset] to EOF. With
  /// [maxRecords]/[maxBytes] (the jump and page-down paths) at most that
  /// much is kept, scanned block-wise — the below-range of a deep-paged
  /// window is never read whole; without caps (the live-tail ingest path
  /// — an external CLI appended while the app held the window) everything
  /// is returned, so a burst of external appends is never silently
  /// dropped. The chunk's [SessionChunk.limitOffset] is the end of the
  /// last kept record, so a capped read resumes exactly after it.
  Future<SessionChunk> readForward(
    int fromOffset, {
    int? maxRecords,
    int? maxBytes,
  }) async {
    final info = await stat();
    if (info == null) {
      throw SessionException(
        'Session not found: $path',
        code: SessionErrorCode.notFound,
      );
    }
    if (fromOffset >= info.size) {
      return SessionChunk(
        entries: const [],
        fileSize: info.size,
        fileMtimeMs: info.mtimeMs,
        hasOlder: false,
        limitOffset: info.size,
      );
    }
    if (maxRecords != null || maxBytes != null) {
      return _scanForwardCapped(
        fromOffset,
        size: info.size,
        mtimeMs: info.mtimeMs,
        // Literals, not `1 << 40`/`1 << 60`: dart2js shifts are 32-bit —
        // 0 on web would read nothing (issue #1074).
        maxRecords: maxRecords ?? 0x10000000000,
        maxBytes: maxBytes ?? 0x1000000000000000,
      );
    }
    final bytes = await _readRange(fromOffset, info.size);
    final lines = _splitLines(bytes, fromOffset);
    final entries = await _parseAllLines(lines);
    return SessionChunk(
      entries: entries,
      fileSize: info.size,
      fileMtimeMs: info.mtimeMs,
      hasOlder: false,
      limitOffset: info.size,
    );
  }

  /// Streaming id seek (issue #135 AC6): scans the file block-wise for
  /// the line whose record id is [recordId] and returns its byte
  /// offset; `null` when absent. Cost is one pass — callers jump through
  /// the sparse offset map instead whenever the record was read before
  /// ([locatePassCount] instruments the difference).
  Future<int?> locateRecord(String recordId) async {
    final info = await stat();
    if (info == null) return null;
    const block = 1 << 20;
    var offset = 0;
    final needle = '"id":"$recordId"';
    while (offset < info.size) {
      _locatePassCount++;
      final end = (offset + block) < info.size ? offset + block : info.size;
      final bytes = await _readRange(offset, end);
      // Cheap substring gate before any JSON decode.
      if (!_containsAscii(bytes, needle)) {
        offset = end;
        continue;
      }
      final lines = _splitLines(bytes, offset);
      for (final (lineOffset, lineBytes) in lines) {
        final text = utf8.decode(lineBytes, allowMalformed: true);
        if (!text.contains(needle)) continue;
        final SessionRecord record;
        try {
          record = parseSessionEntryLine(text, '', lineOffset);
        } on Object {
          continue; // torn or foreign line: a locate degrades to a miss
        }
        if (record.id == recordId) return lineOffset;
      }
      offset = end;
    }
    return null;
  }

  /// Blocks read by [locateRecord] this open (AC6 instrumentation: a
  /// jump through the sparse offset map adds none).
  int get locatePassCount => _locatePassCount;
  int _locatePassCount = 0;

  /// Hidden-range drill-in (issue #385 F4): one forward block scan
  /// collecting the records whose ids appear in [ids] — the records a
  /// [HiddenRangeRecord] covers. They sit OFF the kept branch (the
  /// compaction evicted them from the context), so the branch readers
  /// never surface them; this reads the raw file instead. Serves what
  /// exists: a range still open at the file tail resolves the records
  /// already written, honestly; ids absent from the file stay absent from
  /// the result. Cost is one pass, bounded like [locateRecord].
  Future<Map<String, SessionRecord>> readRecordsByIds(Set<String> ids) async {
    final found = <String, SessionRecord>{};
    if (ids.isEmpty) return found;
    final info = await stat();
    if (info == null) return found;
    const block = 1 << 20;
    var offset = 0;
    while (offset < info.size && found.length < ids.length) {
      final end = (offset + block) < info.size ? offset + block : info.size;
      final bytes = await _readRange(offset, end);
      _scanChunkForIds(bytes, offset, ids, found);
      offset = end;
    }
    return found;
  }

  /// Scans one raw chunk for the wanted ids, folding hits into [found]
  /// (issue #385 F4). Torn or foreign lines are skipped: the drill-in
  /// degrades around them instead of failing the whole range.
  void _scanChunkForIds(
    Uint8List bytes,
    int offset,
    Set<String> ids,
    Map<String, SessionRecord> found,
  ) {
    for (final (lineOffset, lineBytes) in _splitLines(bytes, offset)) {
      final text = utf8.decode(lineBytes, allowMalformed: true);
      if (text.length < 12) continue;
      final SessionRecord record;
      try {
        record = parseSessionEntryLine(text, '', lineOffset);
      } on Object {
        continue;
      }
      if (ids.contains(record.id)) found[record.id] = record;
    }
  }

  /// Case-sensitive ASCII substring match without decoding.
  bool _containsAscii(Uint8List haystack, String needle) {
    final pattern = ascii.encode(needle);
    outer:
    for (var i = 0; i + pattern.length <= haystack.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (haystack[i + j] != pattern[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// ASCII needle for the raw `session_info` gate. Records serialize
  /// `type` first, compact (no whitespace), so the byte pattern is
  /// stable; the parse of the containing line stays the real check —
  /// the needle only selects candidate lines (the same bet
  /// [locateRecord] makes with `"id":`).
  static const String _sessionInfoNeedle = '"type":"session_info"';

  /// Byte cap per name-probe window (issue #369 AC1): fixed bounded
  /// reads at each end of the file instead of any backward walk. A
  /// 400 MB giant pays at most 2 MiB plus the probed lines' own bytes —
  /// far below the file size by construction, so proving a name is
  /// ABSENT never touches the body between the windows.
  static const int _nameProbeBytes = 1 << 20;

  /// The newest `session_info` record's name via two bounded probes
  /// (issue #369). The HEAD window is read first: a named-at-creation
  /// session keeps its session_info among the first records, so the
  /// 400 MB giant case resolves from the file start without any
  /// backward walk (AC2). The TAIL window's verdict wins whenever it
  /// sees a record — bytes after the head are newer, so a
  /// rename-at-end still beats the header name (AC5, newest within the
  /// cap) — and on a head miss it is the bounded-cap fallback AC1
  /// names. The body between the windows is never read. Returns the
  /// name, `null` when the probes see no session_info or the newest
  /// probed record clears the name (empty/whitespace — the caller's
  /// contract). Throws [SessionException] like [readTail] when the
  /// file is missing.
  Future<String?> readNewestSessionInfoName() async =>
      (await readNewestSessionInfo())?.name;

  /// The newest `session_info` record of the file (null when it holds
  /// none) — the record form of [readNewestSessionInfoName], so callers
  /// probing several segments can tell "no record" apart from an empty
  /// (name-clearing) one.
  Future<SessionInfoRecord?> readNewestSessionInfo() async {
    final info = await stat();
    if (info == null) {
      throw SessionException(
        'Session not found: $path',
        code: SessionErrorCode.notFound,
      );
    }
    if (info.size == 0) return null;
    if (info.size <= _nameProbeBytes) {
      // One window covers the file - the whole name history is probed.
      return _newestSessionInfoInWindow(0, info.size, info.size);
    }
    final head = await _newestSessionInfoInWindow(
      0,
      _nameProbeBytes,
      info.size,
    );
    final tail = await _newestSessionInfoInWindow(
      info.size - _nameProbeBytes,
      info.size,
      info.size,
    );
    return tail ?? head;
  }

  /// The newest `session_info` record whose LINE starts inside
  /// [start, end), probed with a needle-length overlap past each edge
  /// so a gate hit on a line crossing the boundary still resolves
  /// through the line-seek parse. `null` when the window sees no
  /// session_info.
  Future<SessionInfoRecord?> _newestSessionInfoInWindow(
    int start,
    int end,
    int size,
  ) async {
    if (end <= start) return null;
    final needle = ascii.encode(_sessionInfoNeedle);
    final overlap = needle.length - 1;
    final readStart = start > overlap ? start - overlap : 0;
    final readEnd = end + overlap < size ? end + overlap : size;
    final bytes = await _readRange(readStart, readEnd);
    for (var i = bytes.length - needle.length; i >= 0; i--) {
      if (bytes[i] != needle[0]) continue;
      if (!_matchesAsciiAt(bytes, i, needle)) continue;
      final (lineStart, record) = await _parseLineContaining(
        readStart + i,
        size,
      );
      if (lineStart >= end) continue; // the record lives beyond the window
      if (record is SessionInfoRecord) return record;
    }
    return null;
  }

  /// Full ASCII match of [needle] at [bytes] offset [i]; the caller has
  /// already matched the first byte.
  static bool _matchesAsciiAt(Uint8List bytes, int i, List<int> needle) {
    for (var j = 1; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) return false;
    }
    return true;
  }

  /// Parses the record on the JSONL line containing absolute byte
  /// offset [hit]; returns the line's start offset with the record.
  /// The line may extend far beyond one probe window (a megabyte-wide
  /// image record can quote the needle in its payload), so its bounds
  /// are found with block-wise newline seeks and the exact range is
  /// read once. Torn or foreign lines return a `null` record — the
  /// scan moves on, never fatal in a read-only probe. The line start
  /// is always hit's own line, so the caller can tell records that
  /// begin beyond its window from boundary-crossing ones.
  Future<(int, SessionRecord?)> _parseLineContaining(int hit, int size) async {
    final nlBefore = await _lastNewlineBefore(hit);
    final lineStart = nlBefore == null ? 0 : nlBefore + 1;
    final lineEnd = await _firstNewlineFrom(hit) ?? size;
    final bytes = await _readRange(lineStart, lineEnd);
    try {
      return (
        lineStart,
        parseSessionEntryLine(
          utf8.decode(bytes, allowMalformed: true),
          path,
          lineStart,
        ),
      );
    } on Object {
      return (lineStart, null);
    }
  }

  /// Seek block for the line bounds below: JSONL lines are short, so a
  /// small block keeps a probe's byte budget tight; megabyte-wide
  /// records just take a few more bounded reads.
  static const int _lineSeekBytes = 1 << 16;

  /// Offset of the last 0x0A strictly below [from], block-wise; `null`
  /// when none exists above the file start.
  Future<int?> _lastNewlineBefore(int from) async {
    var end = from;
    while (end > 0) {
      final start = end > _lineSeekBytes ? end - _lineSeekBytes : 0;
      final bytes = await _readRange(start, end);
      for (var i = bytes.length - 1; i >= 0; i--) {
        if (bytes[i] == 0x0A) return start + i;
      }
      end = start;
    }
    return null;
  }

  /// Offset of the first 0x0A at or after [from], block-wise; `null`
  /// when the file has none above [from] (torn final line).
  Future<int?> _firstNewlineFrom(int from) async {
    final info = await stat();
    if (info == null) return null;
    var start = from;
    while (start < info.size) {
      final end = start + _lineSeekBytes < info.size
          ? start + _lineSeekBytes
          : info.size;
      final bytes = await _readRange(start, end);
      final nl = bytes.indexOf(0x0A);
      if (nl >= 0) return start + nl;
      start = end;
    }
    return null;
  }

  /// Forward scan bounded by both caps: 1 MiB blocks, the torn tail line
  /// carries into the next block, unparseable lines are skipped (never
  /// fatal in a windowed read).
  Future<SessionChunk> _scanForwardCapped(
    int fromOffset, {
    required int size,
    required int mtimeMs,
    required int maxRecords,
    required int maxBytes,
  }) async {
    const block = 1 << 20;
    final entries = <SessionChunkEntry>[];
    var lastKeptEnd = fromOffset;
    var totalBytes = 0;
    final torn = BytesBuilder();
    var tornStart = fromOffset;
    var offset = fromOffset;
    var capped = false;
    while (!capped && offset < size) {
      final end = offset + block < size ? offset + block : size;
      final bytes = await _readRange(offset, end);
      var scan = 0;
      final blockLines = <(int, Uint8List)>[];
      while (scan < bytes.length) {
        final nl = bytes.indexOf(0x0A, scan);
        if (nl < 0) {
          if (torn.isEmpty) tornStart = offset + scan;
          torn.add(Uint8List.sublistView(bytes, scan));
          scan = bytes.length;
          break;
        }
        torn.add(Uint8List.sublistView(bytes, scan, nl));
        final raw = torn.takeBytes();
        blockLines.add((tornStart, raw));
        tornStart = offset + nl + 1;
        scan = nl + 1;
      }
      // The block parses in bounded executor batches (issue #199); caps
      // still stop at the first record that fills them, so the cursor
      // semantics (lastKeptEnd / totalBytes) are unchanged.
      if (blockLines.isNotEmpty) {
        final parsed = await _parseAllLines(blockLines);
        for (final entry in parsed) {
          entries.add(entry);
          lastKeptEnd = entry.offset + entry.bytes + 1;
          totalBytes += entry.bytes + 1;
          if (entries.length >= maxRecords || totalBytes >= maxBytes) {
            capped = true;
            break;
          }
        }
      }
      offset = end;
    }
    return SessionChunk(
      entries: entries,
      fileSize: size,
      fileMtimeMs: mtimeMs,
      hasOlder: false,
      limitOffset: lastKeptEnd,
    );
  }

  /// Streams the file counting newlines — no JSON decode (~1 s per 300 MB).
  /// Returns the number of RECORDS (lines minus the header line).
  Future<int> countRecords() async {
    final info = await stat();
    if (info == null || info.size == 0) return 0;
    var newlines = 0;
    var offset = 0;
    const block = 1 << 20;
    var lastByte = -1;
    while (offset < info.size) {
      final end = (offset + block) < info.size ? offset + block : info.size;
      final bytes = await _readRange(offset, end);
      for (final b in bytes) {
        if (b == 0x0A) newlines++;
      }
      if (bytes.isNotEmpty) lastByte = bytes.last;
      offset = end;
    }
    var lines = newlines;
    if (lastByte != -1 && lastByte != 0x0A) lines++; // torn final line
    return lines > 0 ? lines - 1 : 0; // minus the header line
  }

  /// File facts for staleness guards; `null` when the file is gone.
  Future<({int size, int mtimeMs})?> stat() async {
    final result = await fs.fileInfo(path);
    if (result.isErr) return null;
    final info = result.valueOrNull!;
    if (info.kind != FileKind.file) return null;
    _noteParseCacheStamp(info.size, info.mtimeMs);
    return (size: info.size, mtimeMs: info.mtimeMs);
  }

  /// Reads the session header (first line) only — the metadata an open
  /// needs without touching the record body. The prefix read doubles from
  /// 4 KiB so a normal open moves a few KiB, never the file.
  Future<SessionHeader> readHeader() async {
    final info = await stat();
    if (info == null) {
      throw SessionException(
        'Session not found: $path',
        code: SessionErrorCode.notFound,
      );
    }
    const maxPrefix = 64 << 10;
    var prefix = info.size < 4 << 10 ? info.size : 4 << 10;
    List<(int, Uint8List)> lines = const [];
    while (true) {
      final bytes = await _readRange(0, prefix);
      lines = _splitLines(bytes, 0);
      if (lines.isNotEmpty || info.size <= prefix) break;
      prefix *= 4; // header line longer than the prefix: keep doubling
      if (prefix > maxPrefix) prefix = info.size; // last resort: full read
    }
    if (lines.isEmpty) {
      throw SessionException(
        'Missing session header: $path',
        code: SessionErrorCode.invalidSession,
      );
    }
    return parseSessionHeaderLine(utf8.decode(lines.first.$2), path);
  }

  /// Backward scan bounded by both caps. When [endExclusive] is null the
  /// scan starts at EOF (readTail); otherwise at the anchor (readBefore).
  Future<SessionChunk> _scanBackward({
    int? endExclusive,
    required int maxRecords,
    required int maxBytes,
  }) async {
    final info = await stat();
    if (info == null) {
      throw SessionException(
        'Session not found: $path',
        code: SessionErrorCode.notFound,
      );
    }
    final limit = endExclusive == null
        ? info.size
        : (endExclusive < info.size ? endExclusive : info.size);
    SessionChunk chunk(bool hasOlder, List<SessionChunkEntry> entries) =>
        SessionChunk(
          entries: entries,
          fileSize: info.size,
          fileMtimeMs: info.mtimeMs,
          hasOlder: hasOlder,
          limitOffset: limit,
        );
    if (limit <= 0) return chunk(false, const []);

    var window = startWindowBytes;
    // Previously-read bytes covering [bufferStart, limit). Each doubling
    // pass reads only the NEW strip below the previous one, so every byte
    // of the file crosses the wire at most once per scan (the `tail`
    // trick) — a doubling scan without the buffer re-reads its own tail
    // and doubles the total bytes moved.
    var buffer = Uint8List(0);
    var bufferStart = limit;
    while (true) {
      final (merged, start, lo) = await _readChunkAt(
        limit: limit,
        window: window,
        buffer: buffer,
        bufferStart: bufferStart,
      );
      buffer = merged;
      bufferStart = start;
      final lines = _splitLines(buffer, lo);
      // When the window does not reach the file (anchor) start, the first
      // line segment is the TAIL of a record that begins above the window —
      final parseable = lo > 0 && lines.isNotEmpty ? lines.sublist(1) : lines;
      final entries = await _collectNewest(
        parseable,
        maxRecords: maxRecords,
        maxBytes: maxBytes,
      );
      if (lo == 0) {
        return _topChunk(chunk: chunk, entries: entries, lines: lines);
      }
      final capped = _cappedChunk(
        chunk: chunk,
        entries: entries,
        maxRecords: maxRecords,
        maxBytes: maxBytes,
      );
      if (capped != null) return capped;
      window *= 2;
    }
  }

  /// Reads the window strip above [bufferStart] and prepends it to
  /// [buffer]. Returns the merged buffer, its new start, and [lo] — the
  /// window's low watermark (0 = file start reached).
  Future<(Uint8List, int, int)> _readChunkAt({
    required int limit,
    required int window,
    required Uint8List buffer,
    required int bufferStart,
  }) async {
    final lo = limit - window > 0 ? limit - window : 0;
    if (lo >= bufferStart) return (buffer, bufferStart, lo);
    final strip = await _readRange(lo, bufferStart);
    final merged = Uint8List(strip.length + buffer.length)
      ..setAll(0, strip)
      ..setAll(strip.length, buffer);
    return (merged, lo, lo);
  }

  /// Chunk for a scan that reached the file top: the header line (offset
  /// 0) is not a record — drop it if it landed in the chunk. There is
  /// older history ONLY if the caps stopped the collection above the
  /// first record line; reaching lines[1] means the whole file is loaded.
  SessionChunk _topChunk({
    required SessionChunk Function(bool, List<SessionChunkEntry>) chunk,
    required List<SessionChunkEntry> entries,
    required List<(int offset, Uint8List bytes)> lines,
  }) {
    final withoutHeader = [
      for (final entry in entries)
        if (entry.offset != 0) entry,
    ];
    final firstRecordOffset = lines.length > 1 ? lines[1].$1 : null;
    final reachedTop =
        withoutHeader.isEmpty ||
        firstRecordOffset == null ||
        withoutHeader.first.offset == firstRecordOffset;
    return chunk(!reachedTop, withoutHeader);
  }

  /// The caps-stopped chunk, or null when the window must keep growing.
  SessionChunk? _cappedChunk({
    required SessionChunk Function(bool, List<SessionChunkEntry>) chunk,
    required List<SessionChunkEntry> entries,
    required int maxRecords,
    required int maxBytes,
  }) {
    if (entries.isEmpty) return null;
    if (entries.length < maxRecords && _bytesOf(entries) < maxBytes) {
      return null;
    }
    return chunk(true, entries);
  }

  Future<Uint8List> _readRange(int start, int end) async {
    if (fs case final RangedReadFileSystem ranged) {
      final result = await ranged.readRange(path, start, end);
      if (result.isErr) {
        throw SessionException(
          'Failed to read session range [$start, $end) of $path: '
          '${result.errorOrNull!.message}',
          code: SessionErrorCode.storage,
          cause: result.errorOrNull,
        );
      }
      return result.valueOrNull ?? Uint8List(0);
    }
    throw SessionException(
      'Session store does not support ranged reads: $path',
      code: SessionErrorCode.storage,
    );
  }

  /// Splits [bytes] into line byte-ranges. A final segment without a
  /// trailing newline (torn last write) is still a line — parsing decides.
  static List<(int offset, Uint8List bytes)> _splitLines(
    Uint8List bytes,
    int baseOffset,
  ) {
    final lines = <(int, Uint8List)>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0x0A) continue;
      if (i > start) {
        lines.add((baseOffset + start, Uint8List.sublistView(bytes, start, i)));
      }
      start = i + 1;
    }
    if (start < bytes.length) {
      lines.add((baseOffset + start, Uint8List.sublistView(bytes, start)));
    }
    return lines;
  }

  /// Parses lines from the END, newest-first, until the caps are hit. At
  /// least one parseable record is always kept (a single multi-MB record
  /// still opens). Returns the kept records OLDEST-first. Torn lines are
  /// skipped. [maxBytes] < 0 disables the byte cap (live-tail ingest).
  ///
  /// Parsing runs in bounded batches through [parseExecutor] (issue #199);
  /// the newest-side walk order — and therefore the caps' early break — is
  /// unchanged. One batch may parse a few records past the cap break; the
  /// overshoot is bounded by a single transfer.
  ///
  /// Issue #1498: every line resolves against the parse cache first, so a
  /// re-visited window (repeat jump, doubling-pass overlap, scroll
  /// bounce) splices its records instead of re-decoding; a batch parses
  /// only when the walk reaches one of its uncached lines, which keeps
  /// the caps' parse volume identical to the uncached walk.
  Future<List<SessionChunkEntry>> _collectNewest(
    List<(int offset, Uint8List bytes)> lines, {
    required int maxRecords,
    required int maxBytes,
  }) async {
    if (lines.isEmpty) return const [];
    final probe = _probeParseCache(lines);
    final plan = _planMissBatches(lines, probe.missIdx);
    return _walkNewestWithinCaps(
      lines,
      probe: probe,
      plan: plan,
      maxRecords: maxRecords,
      maxBytes: maxBytes,
    );
  }

  /// Resolves every line of a window against the parse cache (issue
  /// #1498): hits splice, empties mark torn, everything else is a miss
  /// for the batch planner. Counter-free — a miss costs work only when
  /// the cap walk reaches it.
  _WindowCacheProbe _probeParseCache(
    List<(int offset, Uint8List bytes)> lines,
  ) {
    final resolved = List<SessionChunkEntry?>.filled(lines.length, null);
    final torn = List<bool>.filled(lines.length, false);
    final missIdx = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final (offset, raw) = lines[i];
      if (raw.isEmpty) {
        torn[i] = true;
        continue;
      }
      final (hit, entry) = _parseCacheLookup(offset, raw.length, false);
      if (hit) {
        torn[i] = entry == null;
        resolved[i] = entry;
      } else {
        missIdx.add(i);
      }
    }
    return _WindowCacheProbe(resolved: resolved, torn: torn, missIdx: missIdx);
  }

  /// Decodes the miss lines once and partitions them into bounded parse
  /// batches (issue #199); batch parsing itself stays lazy — a batch
  /// parses when the cap walk first reaches one of its lines, so the
  /// caps stop it at the same volume as the uncached walk.
  _MissBatchPlan _planMissBatches(
    List<(int offset, Uint8List bytes)> lines,
    List<int> missIdx,
  ) {
    final decoded = _decodeLines([for (final i in missIdx) lines[i]]);
    final decodedJByOffset = <int, int>{
      for (var j = 0; j < decoded.length; j++) decoded[j].$1: j,
    };
    final missJByLine = List<int>.filled(lines.length, -1);
    for (final i in missIdx) {
      final j = decodedJByOffset[lines[i].$1];
      if (j != null) missJByLine[i] = j;
    }
    final base = decoded.isEmpty ? 0 : decoded.first.$1;
    final batches = decoded.isEmpty
        ? const <SessionParseBatch>[]
        : splitSessionParseBatches(
            [for (final (_, text, _) in decoded) text],
            filePath: path,
            firstLineNumber: base,
          );
    // Line → (batch, position in batch). Batches partition [decoded] in
    // order, so a decoded slot maps to exactly one (batch, pos).
    final batchOfMiss = List<int>.filled(decoded.length, -1);
    final posInBatch = List<int>.filled(decoded.length, -1);
    for (var b = 0; b < batches.length; b++) {
      final start = batches[b].firstLineNumber - base;
      for (var p = 0; p < batches[b].lines.length; p++) {
        batchOfMiss[start + p] = b;
        posInBatch[start + p] = p;
      }
    }
    return _MissBatchPlan(
      decoded: decoded,
      missJByLine: missJByLine,
      batches: batches,
      batchOfMiss: batchOfMiss,
      posInBatch: posInBatch,
      results: List<SessionParseResult?>.filled(batches.length, null),
    );
  }

  /// Parses batch [b] of [plan] on first touch; later touches splice the
  /// memoized result (the executor path stays one transfer per batch).
  Future<SessionParseResult> _parseMissBatch(_MissBatchPlan plan, int b) async {
    final existing = plan.results[b];
    if (existing != null) return existing;
    final result = parseExecutor == null
        ? parseSessionEntryLinesSync(plan.batches[b])
        : await parseExecutor!.parse(plan.batches[b]);
    return plan.results[b] = result;
  }

  /// The newest-first cap walk over a probed window: records splice from
  /// the cache, miss batches parse on first reach, and the caps break at
  /// exactly the uncached walk's volume (issue #1498).
  Future<List<SessionChunkEntry>> _walkNewestWithinCaps(
    List<(int offset, Uint8List bytes)> lines, {
    required _WindowCacheProbe probe,
    required _MissBatchPlan plan,
    required int maxRecords,
    required int maxBytes,
  }) async {
    final picked = <SessionChunkEntry>[];
    var totalBytes = 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (picked.length >= maxRecords) break;
      if (maxBytes >= 0 && picked.isNotEmpty && totalBytes >= maxBytes) break;
      if (probe.torn[i]) continue;
      var entry = probe.resolved[i];
      if (entry == null) {
        entry = await _materializeMiss(lines, probe: probe, plan: plan, i: i);
        if (entry == null) continue; // torn or undecodable — marked above
      }
      picked.add(entry);
      totalBytes += entry.bytes + 1;
    }
    return picked.reversed.toList(growable: false);
  }

  /// Parses one miss line through its batch (issue #1498) — the only
  /// spot a line turns into decode+parse work — and lands the result in
  /// the cache. Returns null for a line that stays torn (parse failure)
  /// or whose bytes never decoded; both are marked in [probe.torn].
  Future<SessionChunkEntry?> _materializeMiss(
    List<(int offset, Uint8List bytes)> lines, {
    required _WindowCacheProbe probe,
    required _MissBatchPlan plan,
    required int i,
  }) async {
    // A miss that costs work: this is the only place a line turns
    // into decode+parse (the probe above is counter-free).
    _parseCacheMisses++;
    final j = plan.missJByLine[i];
    if (j < 0) {
      // Undecodable bytes: remember the failed decode too, so a
      // re-visited window skips the attempt.
      probe.torn[i] = true;
      _parseCacheStoreTorn(lines[i].$1, lines[i].$2.length, false);
      return null;
    }
    final record = (await _parseMissBatch(
      plan,
      plan.batchOfMiss[j],
    )).records[plan.posInBatch[j]];
    final (offset, _, weight) = plan.decoded[j];
    if (record == null) {
      probe.torn[i] = true;
      _parseCacheStoreTorn(offset, weight, false);
      return null;
    }
    final entry = SessionChunkEntry(
      offset: offset,
      bytes: weight,
      record: record,
    );
    probe.resolved[i] = entry;
    _parseCacheStore(entry, false);
    return entry;
  }

  /// Parses lines oldest-first through the executor, skipping torn ones.
  ///
  /// Issue #1498: cached lines splice from the parse cache; only the
  /// misses decode + parse, and every fresh parse result is stored back —
  /// a re-read window pays for its new lines only.
  Future<List<SessionChunkEntry>> _parseAllLines(
    List<(int offset, Uint8List bytes)> lines, {
    bool shallowGiantCustoms = false,
  }) async {
    final results = List<SessionChunkEntry?>.filled(lines.length, null);
    final missIdx = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final (offset, raw) = lines[i];
      if (raw.isEmpty) continue;
      final (hit, entry) = _parseCacheLookup(
        offset,
        raw.length,
        shallowGiantCustoms,
      );
      if (hit) {
        results[i] = entry;
      } else {
        missIdx.add(i);
      }
    }
    // Full-parse semantics: every miss below is decoded + parsed now.
    _parseCacheMisses += missIdx.length;
    if (missIdx.isNotEmpty) {
      final decoded = _decodeLines([
        for (final i in missIdx) lines[i],
      ], shallowGiantCustoms: shallowGiantCustoms);
      final decodedOffsets = {for (final (offset, _, _) in decoded) offset};
      _storeUndecodableTorn(
        lines,
        missIdx,
        decodedOffsets,
        shallowGiantCustoms,
      );
      if (decoded.isNotEmpty) {
        final parsed = await parseSessionLines(
          [
            for (final (_, text, _) in decoded)
              // Byte-level truncation in _decodeLines handles the canonical
              // shape; this string-level pass catches any line the byte twin
              // declined (defense in depth, cheap on short lines).
              if (shallowGiantCustoms &&
                  text.length >= shallowCustomRecordThreshold &&
                  text.startsWith('{"type":"custom"'))
                shallowCustomHeader(text) ?? text
              else
                text,
          ],
          filePath: path,
          firstLineNumber: decoded.first.$1,
          executor: parseExecutor,
          shallowGiantCustoms: shallowGiantCustoms,
        );
        final lineIdxByOffset = <int, int>{
          for (final i in missIdx)
            if (decodedOffsets.contains(lines[i].$1)) lines[i].$1: i,
        };
        for (var i = 0; i < parsed.length; i++) {
          final record = parsed[i];
          final (offset, _, weight) = decoded[i];
          if (record == null) {
            _parseCacheStoreTorn(offset, weight, shallowGiantCustoms);
            continue;
          }
          final entry = SessionChunkEntry(
            offset: offset,
            bytes: weight,
            record: record,
          );
          results[lineIdxByOffset[offset]!] = entry;
          _parseCacheStore(entry, shallowGiantCustoms);
        }
      }
    }
    return [for (final entry in results) ?entry];
  }

  /// Remembers decode-failed miss lines as torn (issue #1498 review):
  /// their (offset, len) key is deterministic, so a re-visited window
  /// skips the doomed utf8 attempt instead of re-paying it — and adding
  /// misses — on every pass.
  void _storeUndecodableTorn(
    List<(int offset, Uint8List bytes)> lines,
    List<int> missIdx,
    Set<int> decodedOffsets,
    bool shallow,
  ) {
    for (final i in missIdx) {
      if (decodedOffsets.contains(lines[i].$1)) continue;
      _parseCacheStoreTorn(lines[i].$1, lines[i].$2.length, shallow);
    }
  }

  /// Strict-UTF8 decodes candidate lines, dropping empty or undecodable
  /// ones — the same skip semantics the inline parser had, applied BEFORE
  /// any executor transfer. Returns (offset, text, byteWeight) triples.
  ///
  /// With [shallowGiantCustoms], giant `custom` lines are truncated to
  /// their JSON header at the BYTE level (issue #503 round 3b): UTF-8
  /// decoding ~350 MB of `model_request_summary` payloads was the bulk of
  /// the boundary walk even after the isolate transfer was avoided. The
  /// byteWeight still reports the full line so chunk byte budgets stay
  /// honest.
  static List<(int, String, int)> _decodeLines(
    List<(int offset, Uint8List bytes)> lines, {
    bool shallowGiantCustoms = false,
  }) {
    final decoded = <(int, String, int)>[];
    for (final (offset, raw) in lines) {
      if (raw.isEmpty) continue;
      try {
        final truncated = shallowGiantCustoms ? _truncateGiantCustom(raw) : raw;
        decoded.add((offset, utf8.decode(truncated), raw.length));
      } on Object {
        continue;
      }
    }
    return decoded;
  }

  /// Byte-level twin of [shallowCustomHeader]: when [raw] is a giant
  /// `custom` record line in canonical writer order, returns the bytes up
  /// to `,"data":` plus a closing brace. Anything else passes through
  /// untouched (the string-level fallback in the parse path then decides).
  static Uint8List _truncateGiantCustom(Uint8List raw) {
    if (raw.length < shallowCustomRecordThreshold) return raw;
    const prefix = '{"type":"custom"';
    const dataMarker = ',"data":';
    const customTypeMarker = ',"customType":';
    int needleAt(List<int> haystack, String needle, int from) {
      final codes = needle.codeUnits;
      outer:
      for (var i = from; i <= haystack.length - codes.length; i++) {
        for (var j = 0; j < codes.length; j++) {
          if (haystack[i + j] != codes[j]) continue outer;
        }
        return i;
      }
      return -1;
    }

    if (needleAt(raw, prefix, 0) != 0) return raw;
    final dataAt = needleAt(raw, dataMarker, prefix.length);
    if (dataAt < 0) return raw;
    if (needleAt(raw, customTypeMarker, prefix.length) < 0 ||
        needleAt(raw, customTypeMarker, prefix.length) > dataAt) {
      return raw; // foreign field order — keep the full line
    }
    final header = Uint8List(dataAt + 1)
      ..setRange(0, dataAt, raw)
      ..[dataAt] = 0x7d; // '}'
    return header;
  }

  static int _bytesOf(List<SessionChunkEntry> entries) =>
      entries.fold(0, (sum, entry) => sum + entry.bytes + 1);
}

/// Per-line cache resolution of one scan window (issue #1498).
final class _WindowCacheProbe {
  const _WindowCacheProbe({
    required this.resolved,
    required this.torn,
    required this.missIdx,
  });

  /// Cache-provided entries per line; null where the line must parse.
  final List<SessionChunkEntry?> resolved;

  /// Known-skip lines (empty, torn, foreign) — never picked.
  final List<bool> torn;

  /// Line indices that need decode+parse.
  final List<int> missIdx;
}

/// The decoded misses of one window, partitioned into bounded parse
/// batches (issue #1498); [results] memoizes per batch so the lazy walk
/// parses each batch at most once.
final class _MissBatchPlan {
  const _MissBatchPlan({
    required this.decoded,
    required this.missJByLine,
    required this.batches,
    required this.batchOfMiss,
    required this.posInBatch,
    required this.results,
  });

  /// (offset, text, byteWeight) triples for the decodable misses.
  final List<(int, String, int)> decoded;

  /// Line index → decoded slot; -1 where the bytes never decoded.
  final List<int> missJByLine;

  final List<SessionParseBatch> batches;
  final List<int> batchOfMiss;
  final List<int> posInBatch;

  /// One slot per batch, filled on first parse.
  final List<SessionParseResult?> results;
}
