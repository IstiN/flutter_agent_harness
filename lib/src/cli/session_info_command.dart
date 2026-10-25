import 'dart:convert';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_chunk_reader.dart'
    show sessionHeavyScanWarnBytes;
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart'
    show SessionMetadata, formatSessionBytes;
import 'package:flutter_agent_harness/src/session_line_scanner.dart';

/// Per-type ledger tallies for one session file: record count plus the
/// exact byte weight (line spans, newline included).
final class SessionTypeTally {
  SessionTypeTally();

  int records = 0;

  int bytes = 0;

  void add(int lineBytes) {
    records++;
    bytes += lineBytes;
  }
}

/// The headless `fa session info [<sessionId>] [--json]` command
/// (issue #1882 AC5): ONE streaming pass over the session file (the same
/// bounded [SessionLineScanner] the repair and search passes use — never
/// a whole-file read) producing the size/records breakdown the next
/// 2.9 GB session needs to be visible before it hurts: file size,
/// records by kind, the custom-ledger breakdown with per-type bytes,
/// the vacuum-reclaimable estimate for the latest-snapshot-wins
/// registries, and what `fa session repair` would drop.
///
/// The scan is cancellable: [isCanceled] is polled between scan chunks —
/// a cancellation prints the PARTIAL tally (honestly labeled) and exits
/// 130. [onProgress] reports scanned/total bytes every
/// [infoProgressChunkBytes] so a multi-GB pass is never silent.
Future<int> runSessionInfoCliCommand({
  required void Function(String text) writeln,
  required FileSystem env,
  required String sessionRoot,
  String? sessionId,
  bool json = false,
  void Function(int scannedBytes, int totalBytes)? onProgress,
  Future<bool> Function()? isCanceled,
}) async {
  final resolved = await _resolveInfoTarget(
    sessionId: sessionId?.trim() ?? '',
    writeln: writeln,
    env: env,
    sessionRoot: sessionRoot,
  );
  if (resolved == null) return 1;
  final metadata = resolved;
  final stat = await env.fileInfo(metadata.path);
  final totalBytes = stat.valueOrNull?.size ?? 0;

  final tally = await _scanSessionTally(
    env,
    metadata.path,
    onProgress: onProgress == null
        ? null
        : (done) => onProgress(done, totalBytes),
    isCanceled: isCanceled,
  );

  // The heavy-file guard rides the report too: the breakdown IS the
  // hygiene surface, so the exact size leads it.
  final heavy = totalBytes > sessionHeavyScanWarnBytes ? totalBytes : null;

  if (json) {
    writeln(_infoJson(metadata, totalBytes, tally, heavy));
  } else {
    for (final line in _infoLines(metadata, totalBytes, tally, heavy)) {
      writeln(line);
    }
  }
  return tally.partial ? 130 : 0;
}

/// The JSON rendering of one info report.
String _infoJson(
  SessionMetadata metadata,
  int totalBytes,
  _SessionTally tally,
  int? heavy,
) => jsonEncode({
  'session': metadata.id,
  'path': metadata.path,
  'bytes': totalBytes,
  if (tally.partial) 'partial': true,
  'records': tally.totalRecords,
  'header': tally.header,
  'kinds': [
    for (final entry in tally.kindEntries)
      {
        'kind': entry.key,
        'records': entry.value.records,
        'bytes': entry.value.bytes,
      },
  ],
  'ledgers': [
    for (final entry in tally.ledgerEntries)
      {
        'customType': entry.key,
        'records': entry.value.records,
        'bytes': entry.value.bytes,
        'latestBytes': tally.latestByType[entry.key] ?? 0,
        'repairDrop': repairDropTypes.contains(entry.key),
      },
  ],
  'compactions': tally.compactions,
  if (heavy != null) 'heavyScan': true,
});

/// The human rendering of one info report.
List<String> _infoLines(
  SessionMetadata metadata,
  int totalBytes,
  _SessionTally tally,
  int? heavy,
) => [
  'session: ${metadata.id}',
  'file: ${metadata.path} — ${formatSessionBytes(totalBytes)}, '
      '${tally.totalRecords} records'
      '${tally.partial ? ' (PARTIAL — scan canceled)' : ''}',
  ..._infoHeadLines(tally),
  if (heavy != null)
    'heavy file (> ${formatSessionBytes(sessionHeavyScanWarnBytes)}): '
        'full reads scan the whole ledger',
  '',
  'records by kind:',
  for (final entry in tally.kindEntries)
    '  ${_pad(entry.key, 22)} ${_pad(entry.value.records, 8)} '
        '${formatSessionBytes(entry.value.bytes)}',
  '',
  'custom ledgers:',
  ..._infoLedgerLines(tally),
  '',
  if (tally.compactions > 0)
    'compactions: ${tally.compactions}'
  else
    'compactions: none — compaction frees context, not bytes',
];

/// The header/created/cwd/heavy lines of the human report.
List<String> _infoHeadLines(_SessionTally tally) => [
  if (tally.header['created'] is String)
    'created: ${tally.header['created']}'
        '${tally.header['cwd'] is String ? ' · cwd: ${tally.header['cwd']}' : ''}',
];

/// The custom-ledger table lines of the human report.
List<String> _infoLedgerLines(_SessionTally tally) => [
  for (final entry in tally.ledgerEntries)
    '  ${_pad(entry.key, 22)} ${_pad(entry.value.records, 8)} '
        '${formatSessionBytes(entry.value.bytes)}'
        '${_ledgerNote(entry.key, entry.value, tally)}',
  if (tally.ledgerEntries.isEmpty) '  (none)',
];

/// The repair drop types: whole-ledger drops (`fa session repair`
/// reclaims their bytes entirely). Mirrors `repairDropCustomTypes`
/// (session_repair.dart) without importing the surgery.
const Set<String> repairDropTypes = {
  'model_request_summary',
  'trajectory_prompt_blob',
  'trajectory_manifest_blob',
  'trajectory_wire_dump',
};

/// The latest-snapshot-wins registries: only the newest snapshot feeds
/// the projection; superseded ones are what `sessions.vacuumLedgers` /
/// `fa session repair` reclaim. Mirrors `repairKeepLatestCustomTypes`.
const Set<String> keepLatestTypes = {
  'shell_job_registry',
  'subagent_registry',
  'obligations_ledger',
};

String _ledgerNote(String type, SessionTypeTally tally, _SessionTally all) {
  if (repairDropTypes.contains(type)) {
    return '   ← dropped by `fa session repair` (reclaims all '
        '${formatSessionBytes(tally.bytes)})';
  }
  if (keepLatestTypes.contains(type)) {
    final latest = all.latestByType[type] ?? 0;
    final dead = tally.bytes - latest;
    if (dead <= 0) return '   ← latest-snapshot-wins (nothing dead)';
    return '   ← vacuum reclaims ~${formatSessionBytes(dead)} '
        '(dead snapshots; latest is ${formatSessionBytes(latest)})';
  }
  return '';
}

String _pad(Object value, int width) {
  final text = '$value';
  return text.length >= width ? text : text + ' ' * (width - text.length);
}

/// Resolves [sessionId] (exact id or unambiguous prefix; empty = the
/// most recently used session) to metadata. Returns null — after writing
/// the reason — when nothing matches.
Future<SessionMetadata?> _resolveInfoTarget({
  required String sessionId,
  required void Function(String text) writeln,
  required FileSystem env,
  required String sessionRoot,
}) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
  final listed = await repo.list();
  if (listed.isEmpty) {
    writeln('session info: no sessions in $sessionRoot');
    return null;
  }
  if (sessionId.isEmpty) return _newestInfoTarget(listed);
  return _matchInfoTarget(listed, sessionId, writeln);
}

/// The most recently used session — the empty-target default.
SessionMetadata _newestInfoTarget(List<SessionMetadata> listed) {
  SessionMetadata? newest;
  for (final metadata in listed) {
    if (newest == null || _infoStamp(metadata).isAfter(_infoStamp(newest))) {
      newest = metadata;
    }
  }
  return newest!;
}

/// The sort stamp of a listed session (last activity, create fallback).
DateTime _infoStamp(SessionMetadata metadata) =>
    metadata.lastUpdatedAt ?? metadata.createdAt;

/// Exact-id match first, then an unambiguous id prefix; null — with the
/// reason written — when nothing or too many match.
SessionMetadata? _matchInfoTarget(
  List<SessionMetadata> listed,
  String sessionId,
  void Function(String text) writeln,
) {
  final exact = listed.where((m) => m.id == sessionId).toList();
  if (exact.isNotEmpty) return exact.single;
  final prefix = listed.where((m) => m.id.startsWith(sessionId)).toList();
  if (prefix.length == 1) return prefix.single;
  writeln(_unmatchedInfoMessage(sessionId, prefix.length));
  return null;
}

/// Why the id/prefix matched nothing usable.
String _unmatchedInfoMessage(String sessionId, int matches) => matches == 0
    ? 'session info: session not found: $sessionId'
    : 'session info: ambiguous prefix: $sessionId '
          '($matches matches — name more characters)';

/// Mutable accumulator for the streaming info pass.
class _SessionTally {
  final kindTallies = <String, SessionTypeTally>{};
  final ledgerTallies = <String, SessionTypeTally>{};
  final latestByType = <String, int>{};
  final header = <String, Object?>{};
  var totalRecords = 0;
  var compactions = 0;
  var partial = false;

  List<MapEntry<String, SessionTypeTally>> get kindEntries {
    final entries = kindTallies.entries.toList()
      ..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
    return entries;
  }

  List<MapEntry<String, SessionTypeTally>> get ledgerEntries {
    final entries = ledgerTallies.entries.toList()
      ..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
    return entries;
  }
}

/// Chunk cadence of the [onProgress] callback: ~64 MB between progress
/// reports so a multi-GB pass is never silent but never chatty.
const int infoProgressChunkBytes = 64 << 20;

/// ONE bounded streaming pass over [path]: every line is classified by
/// cheap prefix gates (never a whole-line JSON decode of a multi-MB
/// record), weighed by its exact byte span, and tallied. The header line
/// is the only decode.
Future<_SessionTally> _scanSessionTally(
  FileSystem env,
  String path, {
  void Function(int scannedBytes)? onProgress,
  Future<bool> Function()? isCanceled,
}) async {
  final tally = _SessionTally();
  final progress = _InfoScanProgress(
    onProgress: onProgress,
    isCanceled: isCanceled,
  );
  await SessionLineScanner(fs: env, path: path).scan(
    (line) => _ingestInfoLine(tally, progress, line),
    fileSize: await totalBytesOf(env, path),
  );
  return tally;
}

/// Cancel polling + progress cadence of one info scan.
class _InfoScanProgress {
  _InfoScanProgress({this.onProgress, this.isCanceled});

  final void Function(int scannedBytes)? onProgress;

  final Future<bool> Function()? isCanceled;

  var _nextProgressAt = infoProgressChunkBytes;

  var _canceled = false;

  /// Runs the per-line gate: polls the cancel token (the tally turns
  /// PARTIAL on first fire) and reports progress. True when the line
  /// must be skipped.
  Future<bool> beginLine(_SessionTally tally, SessionScannedLine line) async {
    if (await _pollCanceled()) {
      tally.partial = true;
      return true;
    }
    _noteProgress(line);
    return false;
  }

  Future<bool> _pollCanceled() async {
    if (_canceled || isCanceled == null) return _canceled;
    _canceled = await isCanceled!();
    return _canceled;
  }

  void _noteProgress(SessionScannedLine line) {
    final report = onProgress;
    if (report == null || line.end < _nextProgressAt) return;
    report(line.end);
    _nextProgressAt += infoProgressChunkBytes;
  }
}

/// One scanned line into the tally: blank skip, cancel/progress gate,
/// header decode, then the kind/custom classification.
Future<void> _ingestInfoLine(
  _SessionTally tally,
  _InfoScanProgress progress,
  SessionScannedLine line,
) async {
  if (line.text.trim().isEmpty) return;
  if (await progress.beginLine(tally, line)) return;
  if (_ingestInfoHeader(tally, line.text)) return;
  _ingestInfoRecord(tally, line);
}

/// The (single) session header line: decoded into the report's header
/// fields. True when the line WAS the header.
bool _ingestInfoHeader(_SessionTally tally, String text) {
  if (tally.totalRecords > 0 || !text.startsWith('{"type":"session"')) {
    return false;
  }
  tally.header.addAll(_parseInfoHeader(text));
  return true;
}

/// A non-header record into the kind/ledger tallies.
void _ingestInfoRecord(_SessionTally tally, SessionScannedLine line) {
  tally.totalRecords++;
  final kind = _sniffRecordKind(line.text);
  if (kind == 'custom') {
    _ingestInfoCustom(tally, line);
    return;
  }
  final label = kind == 'message' ? _sniffMessageRole(line.text) : kind;
  (tally.kindTallies[label] ??= SessionTypeTally()).add(line.byteLength);
  if (kind == 'compaction') tally.compactions++;
}

/// A custom ledger record into the ledger tallies (+ the keep-latest
/// newest-snapshot tracker).
void _ingestInfoCustom(_SessionTally tally, SessionScannedLine line) {
  final customType = _sniffCustomType(line.text) ?? '(unknown)';
  (tally.ledgerTallies[customType] ??= SessionTypeTally()).add(line.byteLength);
  if (keepLatestTypes.contains(customType)) {
    tally.latestByType[customType] = line.byteLength;
  }
  if (customType == 'compaction') tally.compactions++;
}

Future<int?> totalBytesOf(FileSystem env, String path) async {
  try {
    final info = await env.fileInfo(path);
    return info.valueOrNull?.size;
  } on Object {
    return null;
  }
}

/// The record `type` field, by cheap gate — never a decode of a
/// multi-megabyte line.
String _sniffRecordKind(String line) {
  const gate = '{"type":"';
  if (!line.startsWith(gate)) return '(other)';
  final end = line.indexOf('"', gate.length);
  if (end < 0) return '(other)';
  return line.substring(gate.length, end);
}

/// The `customType` value of a custom record, by gate.
String? _sniffCustomType(String line) {
  const gate = '"customType":"';
  final at = line.indexOf(gate);
  if (at < 0) return null;
  final start = at + gate.length;
  final end = line.indexOf('"', start);
  if (end < 0) return null;
  return line.substring(start, end);
}

/// The message role, by gate — user/assistant/toolResult/stub counts.
String _sniffMessageRole(String line) {
  const gate = '"role":"';
  final at = line.indexOf(gate);
  if (at < 0) return 'message';
  final start = at + gate.length;
  final end = line.indexOf('"', start);
  if (end < 0) return 'message';
  return line.substring(start, end);
}

/// Decodes the (small) header line into the report's header fields.
Map<String, Object?> _parseInfoHeader(String line) {
  try {
    final decoded = jsonDecode(line);
    if (decoded is! Map) return const {};
    return {
      if (decoded['id'] is String) 'id': decoded['id'],
      if (decoded['timestamp'] is String) 'created': decoded['timestamp'],
      if (decoded['cwd'] is String) 'cwd': decoded['cwd'],
    };
  } on Object {
    return const {};
  }
}
