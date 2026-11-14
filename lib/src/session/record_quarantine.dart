/// Unbrickable session reads (gh-2178): the tolerant timestamp decode
/// protocol plus the quarantine report.
///
/// A session JSONL is attacker-controlled input in practice — any process
/// sharing the file (agent-side python, a skewed helper, disk corruption,
/// hand edits) can append arbitrary bytes. The incident: one foreign
/// `obligations_ledger` record with `"timestamp": "2026-11-13T14:35:18.fZ"`
/// hit the bare `DateTime.parse` in `SessionRecord.fromJson`, the
/// auto-compactor's full-branch walk threw a FormatException, and every
/// turn of a 664 MB session died within ~300 ms behind a misclassified
/// "provider error".
///
/// The protocol has four layers:
/// 1. `parseRecordTimestamp` — strict-first, deterministic placeholder on
///    failure, NEVER throws. The accepted grammar does not change in
///    either direction (no widening, no narrowing — INV4): this is
///    survivability, not leniency.
/// 2. Quarantine — a record whose timestamp degraded is excluded from
///    context building and branch walks but preserved byte-verbatim in
///    the file (the runtime reader never mutates the session file — INV2).
/// 3. The one-time report — file path, line number, record id, and the
///    raw field value (bounded excerpt), at most once per malformed
///    record per process (INV3), flood-capped (E9). CLI/stderr/fa.log
///    only — never a provider call, never telemetry of record contents.
/// 4. `fa session repair` scan mode — the whole-file scan that makes the
///    poison visible (including outside any boot window) and optionally
///    fixes it with `.bak` preservation.
library;

import 'dart:convert';

import 'session_record.dart';

/// The deterministic placeholder for undecodable persisted timestamps
/// (gh-2178 OQ1 (a)): epoch 0, local. Zero schema churn; quarantined
/// records order at 1970 instead of killing the run.
DateTime recordTimestampPlaceholder() => DateTime.fromMillisecondsSinceEpoch(0);

/// The result of [parseRecordTimestamp]: the decoded value plus whether
/// it degraded (the raw input was not strict ISO and the placeholder was
/// used).
final class RecordTimestamp {
  /// Creates a decode outcome.
  const RecordTimestamp(this.value, {required this.degraded});

  /// The decoded timestamp — the exact `DateTime.parse` value for valid
  /// input (INV4 zero drift), the epoch placeholder otherwise.
  final DateTime value;

  /// Whether [value] is the placeholder because the raw input failed the
  /// strict parse.
  final bool degraded;
}

/// Parses a persisted-input timestamp — the ONLY way persisted session
/// bytes decode (gh-2178).
///
/// 1. Strict ISO parse first — EXACTLY the grammar bare `DateTime.parse`
///    accepts today (offset forms, `Z`, fractional digits — unchanged).
/// 2. On [FormatException] → the deterministic epoch placeholder +
///    `degraded: true`. A numeric-epoch string degrades too — it is NOT
///    invented into an epoch parse (no grammar widening, E4).
/// 3. NEVER throws — no throwing path exists in the API (INV1). Valid
///    input cannot be distinguished from what `DateTime.parse` returned
///    before (bit-identical).
RecordTimestamp parseRecordTimestamp(String raw) {
  try {
    return RecordTimestamp(DateTime.parse(raw), degraded: false);
  } on FormatException {
    return RecordTimestamp(recordTimestampPlaceholder(), degraded: true);
  }
}

/// One quarantined-record finding: the coordinates of a record whose
/// timestamp failed the strict decode. Plain data — safe to pass across
/// isolates and to store in a repair report.
final class QuarantinedRecord {
  /// Creates a finding.
  const QuarantinedRecord({
    required this.filePath,
    this.lineNumber,
    required this.recordId,
    required this.rawTimestamp,
  });

  /// The session file the record was decoded from.
  final String filePath;

  /// 1-based physical line of the record in [filePath], when the decode
  /// site knows it (the raw block scans do not track line numbers).
  final int? lineNumber;

  /// The record's own id (the incident's foreign full uuidv7 — courtroom
  /// forensics only; NO runtime gate is built on id shape).
  final String recordId;

  /// The raw timestamp field value, bounded and flattened to one line for
  /// the report (a bounded literal excerpt — never the whole record).
  final String rawTimestamp;

  /// The single-line report text (AC5: names file, line, record id, raw
  /// value). System-authored coordinates only — the quarantined record's
  /// contents never re-enter model context.
  String describe() {
    final line = lineNumber == null ? '' : ' line $lineNumber';
    return 'session quarantine: $filePath$line record $recordId '
        'timestamp ${_bounded(rawTimestamp)} — malformed timestamp, '
        'quarantined (excluded from context; repair with '
        '`fa session repair`)';
  }

  /// Bounded, single-line excerpt of the raw field value.
  static String _bounded(String raw) {
    final flat = raw.replaceAll('\n', '\\n').replaceAll('\r', '\\r');
    const maxLength = 120;
    return flat.length <= maxLength
        ? "'$flat'"
        : "'${flat.substring(0, maxLength)}…'";
  }

  /// The dedupe key: one report per malformed record per process (INV3).
  String get dedupeKey => '$filePath\u0000$recordId';
}

/// The process-level quarantine report sink (gh-2178 INV3/E9).
///
/// The session layer has no console dependency — hosts wire
/// [onQuarantined] exactly like `JsonlSessionStorage.onRotationWarning`
/// (bin boot default: stderr; the CLI: the notice channel + fa.log).
/// Dedupe and the flood cap live HERE, so a repeated turn cannot spam
/// the report regardless of how many decode paths re-read the record.
final class SessionQuarantine {
  SessionQuarantine._();

  /// The host's report sink. Null (the default) = records still
  /// quarantine — the exclusion is behavioral — but nothing prints.
  static void Function(String message)? onQuarantined;

  /// Per-record report lines before the flood cap kicks in (E9: many
  /// poison records → per-record lines up to this cap, then a count
  /// summary). Visible for tests; hosts do not tune it.
  static int maxReportedRecords = 20;

  /// Records reported so far this process (dedupe + cap accounting).
  static int get reportedCount => _reportedKeys.length;

  /// Records dropped by the flood cap after the summary line.
  static int suppressedCount = 0;

  static final Set<String> _reportedKeys = {};

  /// Reports [finding] once per record per process. Fires
  /// [onQuarantined] with [QuarantinedRecord.describe]; beyond the cap
  /// emits a single count-summary line instead of per-record lines (the
  /// exact total is available via [suppressedCount], and the repair scan
  /// reports the full list).
  static void reportRecord(QuarantinedRecord finding) {
    if (_reportedKeys.contains(finding.dedupeKey)) return;
    _reportedKeys.add(finding.dedupeKey);
    final sink = onQuarantined;
    if (sink == null) return;
    if (_reportedKeys.length <= maxReportedRecords) {
      sink(finding.describe());
      return;
    }
    suppressedCount++;
    if (suppressedCount == 1) {
      sink(
        'session quarantine: further malformed record(s) suppressed '
        '(cap $maxReportedRecords per process, $suppressedCount+ so '
        'far) — scan the file with `fa session repair` for the full list',
      );
    }
  }

  /// Drops all per-process state (the sink survives — hosts wire it once
  /// at boot). Test seam only.
  static void resetForTest() {
    _reportedKeys.clear();
    suppressedCount = 0;
  }
}

/// Extracts the TOP-LEVEL `"timestamp"` string value of one JSONL line
/// without a full decode — a bounded char scan tracking
/// string/escape/depth state, exact for the writer-canonical field order
/// and for any object whose top-level key sits after nested payload
/// fields. Null when the line has no top-level timestamp key or the
/// value is not a string. Serves the repair scan's cheap gate (gh-2178
/// AC6): a full `jsonDecode` of every line would defeat the point of the
/// header-only ledger scans.
String? topLevelTimestampValue(String line) {
  final colon = _topLevelTimestampColon(line);
  if (colon < 0) return null;
  return _stringValueAfter(line, colon);
}

/// The offset of the top-level colon whose key names `timestamp`, or -1.
/// "Top level" is a key of the line's OUTERMOST object: the scan opens
/// at depth 0 and `{`/`[` increment, so those keys sit at depth 1 —
/// keys inside nested payloads sit deeper and never match (gh-2178
/// review digest: the original check compared against depth 0, which no
/// object-key colon can ever satisfy, so the gate never fired and every
/// line paid the full decode).
/// A bounded char scan tracking string/depth state — exact for
/// the writer-canonical field order and for any object whose top-level
/// timestamp key sits after nested payload fields.
int _topLevelTimestampColon(String line) {
  var depth = 0;
  var i = 0;
  while (i < line.length) {
    switch (line[i]) {
      case '"':
        // Strings never affect depth: consume each one wholesale (and
        // its escapes with it). A torn string means nothing after it
        // can be a top-level key — stop scanning.
        final end = _endOfString(line, i);
        if (end < 0) return -1;
        i = end;
      case '{' || '[':
        depth++;
        i++;
      case '}' || ']':
        depth--;
        i++;
      case ':':
        if (depth == 1 && _isTimestampKeyBefore(line, i)) return i;
        i++;
      default:
        i++;
    }
  }
  return -1;
}

/// The index just past the closing quote of the JSON string that opens
/// at [openQuote], escapes consumed with the characters they shield. -1
/// when the string is torn (EOF before the closing quote) — the caller
/// stops scanning, matching the per-char state machine it replaced (an
/// unterminated string keeps `inString` set to EOF, so no later char
/// can open or close a container).
int _endOfString(String line, int openQuote) {
  var i = openQuote + 1;
  while (i < line.length) {
    final char = line[i];
    if (char == r'\') {
      i += 2;
      continue;
    }
    if (char == '"') return i + 1;
    i++;
  }
  return -1;
}

/// Whether the key text immediately before the colon at [colon] is
/// exactly `"timestamp"` (the closest earlier occurrence ends at it).
bool _isTimestampKeyBefore(String line, int colon) {
  const key = '"timestamp"';
  return colon >= key.length &&
      line.lastIndexOf(key, colon) == colon - key.length;
}

/// The JSON string value following the top-level colon at [colon] (the
/// scanner already proved the key names timestamp). Null when the value
/// is not a string or the line is torn mid-value.
String? _stringValueAfter(String line, int colon) {
  var j = colon + 1;
  while (j < line.length && line[j] == ' ') {
    j++;
  }
  if (j >= line.length || line[j] != '"') return null;
  final valueStart = ++j;
  while (j < line.length) {
    final valueChar = line[j];
    if (valueChar == r'\') {
      j += 2;
      continue;
    }
    if (valueChar == '"') break;
    j++;
  }
  if (j >= line.length || line[j] != '"') return null; // torn line
  return line.substring(valueStart, j);
}

/// Finds the quarantined-record coordinates of one raw JSONL line — the
/// repair scan's per-line check (gh-2178 AC6).
///
/// Cheap first, exact always: the depth-0 timestamp value is extracted
/// without a decode and strict-parsed; only a value that fails (or a
/// line without one) pays the full decode that confirms the finding.
/// Torn lines, foreign JSON and unknown record types return null —
/// repair keeps those verbatim (gh-1073 conservatism); they are not
/// timestamp findings.
QuarantinedRecord? quarantineFindingForLine(
  String line, {
  required String filePath,
  required int lineNumber,
}) {
  if (!line.contains('"timestamp"')) return null;
  final raw = topLevelTimestampValue(line);
  if (raw != null && parseRecordTimestamp(raw).degraded == false) {
    return null; // exact clean verdict, zero decode
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on Object {
    return null; // torn line — repair keeps it verbatim
  }
  if (decoded is! Map) return null;
  final SessionRecord record;
  try {
    record = SessionRecord.fromJson(decoded.cast<String, dynamic>());
  } on Object {
    return null; // unknown/future record shape — kept verbatim
  }
  if (!record.timestampDegraded) return null;
  final rawValue = decoded['timestamp'];
  return QuarantinedRecord(
    filePath: filePath,
    lineNumber: lineNumber,
    recordId: record.id,
    rawTimestamp: rawValue is String ? rawValue : '',
  );
}

/// The fixed form of a degraded record line: the record's own JSON with
/// the timestamp replaced by the placeholder's canonical ISO string. The
/// payload round-trips through the decode — the JSON content is
/// preserved; only the timestamp value (and, for foreign line shapes,
/// the field order) changes. Returns null when the line cannot be
/// decoded — the caller keeps it verbatim.
String? quarantineFixedLine(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on Object {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final record = SessionRecord.fromJson(decoded);
  if (!record.timestampDegraded) return null;
  decoded['timestamp'] = recordTimestampPlaceholder().toUtc().toIso8601String();
  return jsonEncode(decoded);
}
