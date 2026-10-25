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
    writeln(
      jsonEncode({
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
      }),
    );
    return tally.partial ? 130 : 0;
  }

  final lines = <String>[
    'session: ${metadata.id}',
    'file: ${metadata.path} — ${formatSessionBytes(totalBytes)}, '
        '${tally.totalRecords} records'
        '${tally.partial ? ' (PARTIAL — scan canceled)' : ''}',
    if (tally.header['created'] is String)
      'created: ${tally.header['created']}'
          '${tally.header['cwd'] is String ? ' · cwd: ${tally.header['cwd']}' : ''}',
    if (heavy != null) ...[
      'heavy file (> ${formatSessionBytes(sessionHeavyScanWarnBytes)}): '
          'full reads scan the whole ledger',
    ],
    '',
    'records by kind:',
    for (final entry in tally.kindEntries)
      '  ${_pad(entry.key, 22)} ${_pad(entry.value.records, 8)} '
          '${formatSessionBytes(entry.value.bytes)}',
    '',
    'custom ledgers:',
    for (final entry in tally.ledgerEntries)
      '  ${_pad(entry.key, 22)} ${_pad(entry.value.records, 8)} '
          '${formatSessionBytes(entry.value.bytes)}'
          '${_ledgerNote(entry.key, entry.value, tally)}',
    if (tally.ledgerEntries.isEmpty) '  (none)',
    '',
    if (tally.compactions > 0)
      'compactions: ${tally.compactions}'
    else
      'compactions: none — compaction frees context, not bytes',
  ];
  for (final line in lines) {
    writeln(line);
  }
  return tally.partial ? 130 : 0;
}

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
  if (sessionId.isEmpty) {
    SessionMetadata? newest;
    for (final metadata in listed) {
      final stamp = metadata.lastUpdatedAt ?? metadata.createdAt;
      final best = newest == null
          ? null
          : (newest.lastUpdatedAt ?? newest.createdAt);
      if (best == null || stamp.isAfter(best)) newest = metadata;
    }
    return newest;
  }
  final exact = listed.where((m) => m.id == sessionId).toList();
  if (exact.length == 1) return exact.single;
  final prefix = listed.where((m) => m.id.startsWith(sessionId)).toList();
  if (prefix.length == 1) return prefix.single;
  if (prefix.isEmpty) {
    writeln('session info: session not found: $sessionId');
  } else {
    writeln(
      'session info: ambiguous prefix: $sessionId '
      '(${prefix.length} matches — name more characters)',
    );
  }
  return null;
}

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
  var nextProgressAt = infoProgressChunkBytes;
  var canceled = false;
  await SessionLineScanner(fs: env, path: path).scan((line) async {
    if (line.text.trim().isEmpty) return;
    if (!canceled && isCanceled != null && await isCanceled()) {
      canceled = true;
    }
    if (canceled) {
      tally.partial = true;
      return;
    }
    if (onProgress != null && line.end >= nextProgressAt) {
      onProgress(line.end);
      nextProgressAt += infoProgressChunkBytes;
    }
    if (tally.totalRecords == 0 && line.text.startsWith('{"type":"session"')) {
      tally.header.addAll(_parseInfoHeader(line.text));
      return;
    }
    tally.totalRecords++;
    final kind = _sniffRecordKind(line.text);
    if (kind == 'custom') {
      final customType = _sniffCustomType(line.text) ?? '(unknown)';
      (tally.ledgerTallies[customType] ??= SessionTypeTally()).add(
        line.byteLength,
      );
      if (keepLatestTypes.contains(customType)) {
        tally.latestByType[customType] = line.byteLength;
      }
      if (customType == 'compaction') tally.compactions++;
      return;
    }
    final label = kind == 'message' ? _sniffMessageRole(line.text) : kind;
    (tally.kindTallies[label] ??= SessionTypeTally()).add(line.byteLength);
    if (kind == 'compaction') tally.compactions++;
  }, fileSize: await totalBytesOf(env, path));
  return tally;
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
