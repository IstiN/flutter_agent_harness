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
final class SessionChunkReader {
  /// Creates a reader over [path]. [startWindowBytes] is the first backward
  /// read size; it doubles up to the file length as needed.
  SessionChunkReader({
    required this.fs,
    required this.path,
    this.startWindowBytes = 128 << 10,
    this.parseExecutor,
  });

  /// The store backing [path].
  final FileSystem fs;
  final String path;

  /// Where record parsing runs — `null` keeps the inline batched path
  /// (web); IO hosts inject the isolate executor (issue #199).
  final SessionParseExecutor? parseExecutor;
  final int startWindowBytes;

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
        maxRecords: maxRecords ?? 1 << 40,
        maxBytes: maxBytes ?? 1 << 60,
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
        final record = parseSessionEntryLine(text, '', lineOffset);
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
  Future<List<SessionChunkEntry>> _collectNewest(
    List<(int offset, Uint8List bytes)> lines, {
    required int maxRecords,
    required int maxBytes,
  }) async {
    final decoded = _decodeLines(lines);
    if (decoded.isEmpty) return const [];
    final batches = splitSessionParseBatches(
      [for (final (_, text, _) in decoded) text],
      filePath: path,
      firstLineNumber: decoded.first.$1,
    );
    final picked = <SessionChunkEntry>[];
    var totalBytes = 0;
    for (var b = batches.length - 1; b >= 0; b--) {
      final batch = batches[b];
      // firstLineNumber was the first decoded offset; the delta recovers
      // this batch's start index within [decoded].
      final base = batch.firstLineNumber - decoded.first.$1;
      final result = parseExecutor == null
          ? parseSessionEntryLinesSync(batch)
          : await parseExecutor!.parse(batch);
      for (var i = result.records.length - 1; i >= 0; i--) {
        if (picked.length >= maxRecords) {
          return picked.reversed.toList(growable: false);
        }
        if (maxBytes >= 0 && picked.isNotEmpty && totalBytes >= maxBytes) {
          return picked.reversed.toList(growable: false);
        }
        final record = result.records[i];
        if (record == null) continue;
        final (offset, _, weight) = decoded[base + i];
        picked.add(
          SessionChunkEntry(offset: offset, bytes: weight, record: record),
        );
        totalBytes += weight + 1;
      }
    }
    return picked.reversed.toList(growable: false);
  }

  /// Parses lines oldest-first through the executor, skipping torn ones.
  Future<List<SessionChunkEntry>> _parseAllLines(
    List<(int offset, Uint8List bytes)> lines,
  ) async {
    final decoded = _decodeLines(lines);
    if (decoded.isEmpty) return const [];
    final parsed = await parseSessionLines(
      [for (final (_, text, _) in decoded) text],
      filePath: path,
      firstLineNumber: decoded.first.$1,
      executor: parseExecutor,
    );
    return [
      for (var i = 0; i < parsed.length; i++)
        if (parsed[i] != null)
          SessionChunkEntry(
            offset: decoded[i].$1,
            bytes: decoded[i].$3,
            record: parsed[i]!,
          ),
    ];
  }

  /// Strict-UTF8 decodes candidate lines, dropping empty or undecodable
  /// ones — the same skip semantics the inline parser had, applied BEFORE
  /// any executor transfer. Returns (offset, text, byteWeight) triples.
  static List<(int, String, int)> _decodeLines(
    List<(int offset, Uint8List bytes)> lines,
  ) {
    final decoded = <(int, String, int)>[];
    for (final (offset, raw) in lines) {
      if (raw.isEmpty) continue;
      try {
        decoded.add((offset, utf8.decode(raw), raw.length));
      } on Object {
        continue;
      }
    }
    return decoded;
  }

  static int _bytesOf(List<SessionChunkEntry> entries) =>
      entries.fold(0, (sum, entry) => sum + entry.bytes + 1);
}
