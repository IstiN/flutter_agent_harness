/// Streaming line scan over a JSONL session file (gh-1073).
///
/// The full open used to materialize the whole file with `readTextFile` —
/// a 12.4 GiB UTF-8 session became a ~25 GB UTF-16 `String` and the VM
/// died with `Exhausted heap space` before the parse could even start.
/// The scanner reads the file in bounded byte chunks through
/// [RangedReadFileSystem.readRange], splits complete lines at the `\n`
/// bytes (a `\n` can never appear inside a multi-byte UTF-8 sequence, so
/// byte-splitting is line-exact), and hands each line to the caller with
/// the byte span it occupied — everything a caller needs to stream-parse,
/// quarantine torn writes, or copy byte ranges.
///
/// Pure Dart over the [FileSystem] abstraction; filesystems without range
/// reads keep the legacy whole-file path in `session_storage.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'env/execution_env.dart';
import 'exceptions.dart';

/// Bytes fetched per [RangedReadFileSystem.readRange] call. Bounded so a
/// scan holds one chunk plus the partial line carry, never the file.
const int defaultScanChunkBytes = 4 << 20;

/// One scanned line: the decoded text plus the half-open byte span
/// `[start, end)` it occupies in the file, trailing newline included.
final class SessionScannedLine {
  const SessionScannedLine({
    required this.start,
    required this.end,
    required this.text,
  });

  /// Byte offset of the line's first byte.
  final int start;

  /// Byte offset just past the line's trailing `\n` (or EOF for the final
  /// unterminated line).
  final int end;

  /// The decoded line text, newline stripped.
  final String text;

  /// The line's raw byte length, newline included.
  int get byteLength => end - start;
}

/// Scan totals reported by [SessionLineScanner.scan].
final class SessionLineScanResult {
  const SessionLineScanResult({required this.bytes, required this.lines});

  /// Total file bytes scanned.
  final int bytes;

  /// Total lines yielded (empty lines included).
  final int lines;
}

/// Forward byte-chunked line reader over one file. See the library doc.
final class SessionLineScanner {
  /// Creates a scanner over [path]. [chunkBytes] is the read-granularity;
  /// the default keeps a scan's transient footprint at one chunk.
  SessionLineScanner({
    required this.fs,
    required this.path,
    this.chunkBytes = defaultScanChunkBytes,
  });

  /// The store backing [path].
  final FileSystem fs;

  /// The file to scan.
  final String path;

  /// Read granularity in bytes.
  final int chunkBytes;

  /// Streams every line of the file (empty lines included) to [onLine] in
  /// file order. Malformed UTF-8 degrades to replacement characters — a
  /// torn crash-write must surface as a torn JSON line for the caller's
  /// quarantine, never as a whole-file decode failure.
  ///
  /// Throws [SessionException] (code [SessionErrorCode.storage]) when a
  /// range read fails. [fileSize] skips the internal stat when the caller
  /// just stat'd the file (the streamed session open has).
  Future<SessionLineScanResult> scan(
    Future<void> Function(SessionScannedLine line) onLine, {
    int? fileSize,
  }) async {
    final Object? maybeRanged = fs;
    if (maybeRanged is! RangedReadFileSystem) {
      throw SessionException(
        'Failed to read session $path: streaming scan needs byte-range '
        'reads',
        code: SessionErrorCode.storage,
      );
    }
    final ranged = maybeRanged;
    late final int size;
    if (fileSize != null) {
      size = fileSize;
    } else {
      final stat = await fs.fileInfo(path);
      if (stat.isErr) {
        final error = stat.errorOrNull!;
        throw SessionException(
          'Failed to read session $path: ${error.message}',
          code: error.code == FileErrorCode.notFound
              ? SessionErrorCode.notFound
              : SessionErrorCode.storage,
          cause: error,
        );
      }
      size = stat.valueOrNull!.size;
    }
    var lines = 0;
    var carry = BytesBuilder(copy: false);
    var carryStart = 0;
    var cursor = 0;
    while (cursor < size) {
      final end = cursor + chunkBytes > size ? size : cursor + chunkBytes;
      final chunk = await _readRange(ranged, cursor, end);
      var lineStart = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        carry.add(chunk.sublist(lineStart, i));
        final line = carry.toBytes();
        carry = BytesBuilder(copy: false);
        await onLine(
          SessionScannedLine(
            start: carryStart,
            end: cursor + i + 1,
            text: utf8.decode(line, allowMalformed: true),
          ),
        );
        lines++;
        carryStart = cursor + i + 1;
        lineStart = i + 1;
      }
      if (lineStart < chunk.length) {
        carry.add(chunk.sublist(lineStart));
      }
      cursor = end;
    }
    // Final line without a trailing newline.
    if (carry.isNotEmpty) {
      final line = carry.toBytes();
      await onLine(
        SessionScannedLine(
          start: carryStart,
          end: size,
          text: utf8.decode(line, allowMalformed: true),
        ),
      );
      lines++;
    }
    return SessionLineScanResult(bytes: size, lines: lines);
  }

  Future<Uint8List> _readRange(RangedReadFileSystem ranged, int a, int b) async {
    final result = await ranged.readRange(path, a, b);
    if (result.isErr) {
      final error = result.errorOrNull!;
      throw SessionException(
        'Failed to read session $path: ${error.message}',
        code: error.code == FileErrorCode.notFound
            ? SessionErrorCode.notFound
            : SessionErrorCode.storage,
        cause: error,
      );
    }
    return result.valueOrNull!;
  }
}
