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

import '../session/session_storage.dart'
    show parseSessionEntryLine, parseShallowCustomRecord;
import '../session/session_record.dart';

/// Max lines per parse transfer.
const int sessionParseBatchMaxLines = 500;

/// Max chars per parse transfer.
///
/// `ponytail:` chars≈bytes for base64-dominated session JSON; exact utf-8
/// length only if the cap ever misbehaves.
const int sessionParseBatchMaxBytes = 4 << 20;

/// Max parse batches in flight on the executor path of
/// [parseSessionLines] (issue #503): enough to keep the cores busy on a
/// marathon walk, bounded so concurrent callers (windowed open + listing
/// fan-out) never spawn an unbounded isolate storm.
const int maxConcurrentSessionParseBatches = 8;

/// One bounded batch of raw JSONL entry lines (never the header line).
final class SessionParseBatch {
  const SessionParseBatch({
    required this.filePath,
    required this.firstLineNumber,
    required this.lines,
    this.shallowGiantCustoms = false,
  });

  /// Session file path — error-text context only, never re-read.
  final String filePath;

  /// 1-based file line number of [lines.first] (error-text context).
  final int firstLineNumber;

  /// Raw JSONL lines, file order.
  final List<String> lines;

  /// Issue #503 round 3b: when true, giant `custom` records (the
  /// ~0.75 MB `model_request_summary` ledger payloads) decode HEADER-ONLY
  /// — id/parentId/timestamp/customType — with `data` stubbed to null,
  /// skipping a full jsonDecode + isolate transfer that yields zero
  /// context tokens. Only the resume boundary walk sets this; the
  /// ingest/live-tail paths keep full fidelity. Plain data, isolate-safe.
  final bool shallowGiantCustoms;
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
  bool shallowGiantCustoms = false,
}) {
  final batches = <SessionParseBatch>[];
  var start = 0;
  var weight = 0;
  for (var i = 0; i < lines.length; i++) {
    final lineWeight = lines[i].length;
    if (i > start &&
        (i - start >= sessionParseBatchMaxLines ||
            weight + lineWeight > sessionParseBatchMaxBytes)) {
      batches.add(
        _batch(
          lines,
          start,
          i,
          filePath,
          firstLineNumber,
          shallowGiantCustoms: shallowGiantCustoms,
        ),
      );
      start = i;
      weight = 0;
    }
    weight += lineWeight;
  }
  if (start < lines.length) {
    batches.add(
      _batch(
        lines,
        start,
        lines.length,
        filePath,
        firstLineNumber,
        shallowGiantCustoms: shallowGiantCustoms,
      ),
    );
  }
  return batches;
}

SessionParseBatch _batch(
  List<String> lines,
  int start,
  int end,
  String filePath,
  int firstLineNumber, {
  bool shallowGiantCustoms = false,
}) => SessionParseBatch(
  filePath: filePath,
  firstLineNumber: firstLineNumber + start,
  lines: lines.sublist(start, end),
  shallowGiantCustoms: shallowGiantCustoms,
);

/// Parses [lines] through [executor] — or inline, batch by batch, when it
/// is null — and returns one slot per line in file order (`null` where a
/// line was torn/foreign).
///
/// Inline (web degradation): one await per batch — the event loop
/// breathes between batches by construction.
///
/// Executor path: batches are independent, so they fan out with bounded
/// concurrency — a marathon session walk parses a strip core-wide
/// instead of one 4MB batch at a time (issue #503 boot cost: the
/// sequential await serialized ~2.2s of jsonDecode on a 434MB tail).
/// Results concatenate in batch order, so the returned list is
/// byte-identical to the sequential walk.
Future<List<SessionRecord?>> parseSessionLines(
  List<String> lines, {
  required String filePath,
  required int firstLineNumber,
  SessionParseExecutor? executor,
  bool shallowGiantCustoms = false,
}) async {
  if (lines.isEmpty) return const <SessionRecord?>[];
  final batches = splitSessionParseBatches(
    lines,
    filePath: filePath,
    firstLineNumber: firstLineNumber,
    shallowGiantCustoms: shallowGiantCustoms,
  );
  if (executor == null) {
    final records = <SessionRecord?>[];
    for (final batch in batches) {
      records.addAll(parseSessionEntryLinesSync(batch).records);
    }
    return records;
  }
  final results = List<SessionParseResult?>.filled(batches.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < batches.length) {
      final i = next++;
      results[i] = await executor.parse(batches[i]);
    }
  }

  await Future.wait([
    for (
      var w = 0;
      w < maxConcurrentSessionParseBatches && w < batches.length;
      w++
    )
      worker(),
  ]);
  return [for (final result in results) ...result!.records];
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
      // Issue #503 round 3b: the resume boundary walk parses giant
      // `custom` ledger payloads header-only (data stubbed to null) —
      // they count zero context tokens, so the full decode was pure
      // cost. Falls back to the full decode on any shape mismatch.
      final shallow = batch.shallowGiantCustoms
          ? parseShallowCustomRecord(batch.lines[i])
          : null;
      records[i] =
          shallow ??
          parseSessionEntryLine(
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
