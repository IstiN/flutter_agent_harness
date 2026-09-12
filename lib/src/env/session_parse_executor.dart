/// Off-isolate parsing of JSONL session entry lines (issue #199).
///
/// The session layer's CPU-bound work — `jsonDecode` plus typed record
/// materialization per line — runs behind [SessionParseExecutor] so hosts
/// can move it to background isolates. File I/O stays on the caller (the
/// [FileSystem] abstraction cannot cross isolates); only raw line STRINGS
/// cross the boundary, in bounded batches (≤ [sessionParseBatchMaxLines]
/// lines AND ≤ [sessionParseBatchMaxBytes] chars per transfer), and parsed
/// [SessionRecord] lists come back.
///
/// Default (`executor == null`): batches parse INLINE on the calling
/// isolate, one batch per await — the web degradation path (issue #199 E1:
/// no `dart:isolate` there; pre-chunked batches let the event loop breathe
/// between them). IO hosts inject `IsolateSessionParseExecutor` (exported
/// from `package:flutter_agent_harness/io.dart`).
library;

import '../session/session_storage.dart' show parseSessionEntryLine;
import '../session/session_record.dart';

/// Max lines per parse transfer.
const int sessionParseBatchMaxLines = 500;

/// Max chars per parse transfer.
///
/// `ponytail:` chars≈bytes for base64-dominated session JSON; exact utf-8
/// length only if the cap ever misbehaves.
const int sessionParseBatchMaxBytes = 4 << 20;

/// One bounded batch of raw JSONL entry lines (never the header line).
final class SessionParseBatch {
  const SessionParseBatch({
    required this.filePath,
    required this.firstLineNumber,
    required this.lines,
  });

  /// Session file path — error-text context only, never re-read.
  final String filePath;

  /// 1-based file line number of [lines.first] (error-text context).
  final int firstLineNumber;

  /// Raw JSONL lines, file order.
  final List<String> lines;
}

/// Per-line parse outcomes, parallel to [SessionParseBatch.lines].
final class SessionParseResult {
  const SessionParseResult(this.records);

  /// The parsed record for each submitted line, or `null` for a
  /// torn/foreign line — parse failures are DATA here, so the caller's
  /// quarantine/skip flow stays byte-identical to the inline path (issue
  /// #199 E2/AC4).
  final List<SessionRecord?> records;
}

/// Where CPU-bound session JSONL parsing runs (issue #199).
abstract interface class SessionParseExecutor {
  /// Parses one bounded batch. Never throws for torn lines — they come
  /// back as `null` records.
  Future<SessionParseResult> parse(SessionParseBatch batch);
}

/// Splits [lines] into bounded transfer batches. Issue #199 E5: an
/// oversize line becomes its own batch, so one huge record can never stall
/// a batch beyond its own parse.
List<SessionParseBatch> splitSessionParseBatches(
  List<String> lines, {
  required String filePath,
  required int firstLineNumber,
}) {
  final batches = <SessionParseBatch>[];
  var start = 0;
  var weight = 0;
  for (var i = 0; i < lines.length; i++) {
    final lineWeight = lines[i].length;
    if (i > start &&
        (i - start >= sessionParseBatchMaxLines ||
            weight + lineWeight > sessionParseBatchMaxBytes)) {
      batches.add(_batch(lines, start, i, filePath, firstLineNumber));
      start = i;
      weight = 0;
    }
    weight += lineWeight;
  }
  if (start < lines.length) {
    batches.add(_batch(lines, start, lines.length, filePath, firstLineNumber));
  }
  return batches;
}

SessionParseBatch _batch(
  List<String> lines,
  int start,
  int end,
  String filePath,
  int firstLineNumber,
) => SessionParseBatch(
  filePath: filePath,
  firstLineNumber: firstLineNumber + start,
  lines: lines.sublist(start, end),
);

/// Parses [lines] through [executor] — or inline, batch by batch, when it
/// is null — and returns one slot per line in file order (`null` where a
/// line was torn/foreign). One await per batch: the inline path yields to
/// the event loop between batches by construction.
Future<List<SessionRecord?>> parseSessionLines(
  List<String> lines, {
  required String filePath,
  required int firstLineNumber,
  SessionParseExecutor? executor,
}) async {
  if (lines.isEmpty) return const <SessionRecord?>[];
  final batches = splitSessionParseBatches(
    lines,
    filePath: filePath,
    firstLineNumber: firstLineNumber,
  );
  final records = <SessionRecord?>[];
  for (final batch in batches) {
    final result = executor == null
        ? parseSessionEntryLinesSync(batch)
        : await executor.parse(batch);
    records.addAll(result.records);
  }
  return records;
}

/// Parses one batch right here — the inline executor's body and the
/// isolate worker's entry point share it, so both paths run the exact same
/// parse code (issue #199 AC4 parity).
SessionParseResult parseSessionEntryLinesSync(SessionParseBatch batch) {
  final records = List<SessionRecord?>.filled(
    batch.lines.length,
    null,
    growable: false,
  );
  for (var i = 0; i < batch.lines.length; i++) {
    try {
      records[i] = parseSessionEntryLine(
        batch.lines[i],
        batch.filePath,
        batch.firstLineNumber + i,
      );
    } on Object {
      records[i] = null; // torn/foreign line: data, not an error
    }
  }
  return SessionParseResult(records);
}
