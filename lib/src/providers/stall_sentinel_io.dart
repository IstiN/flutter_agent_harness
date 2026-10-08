/// The dart:io half of StallSentinel (gh-1395 AC3) — the disk writer.
/// The pure contract (redaction allowlist, SHA-256, dump budget) lives in
/// `stall_sentinel.dart` (barrel-exported); this file is reachable
/// exclusively through `lib/io.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'conn_trace.dart';
import 'stall_sentinel.dart';

/// The dump root: [stallDumpDirectoryOverride], then `FA_TRIAL_DIR`, then
/// `<systemTemp>/stall-dumps`.
Directory stallDumpDirectory() {
  final override = stallDumpDirectoryOverride;
  if (override != null && override.isNotEmpty) return Directory(override);
  final lookup = providerStackEnvLookup;
  final env = lookup == null ? null : lookup(stallDumpDirEnvVar);
  if (env != null && env.isNotEmpty) return Directory(env);
  return Directory.systemTemp.createTempSync('fa-stall-root');
}

/// The disk sink: one directory per dump, `payload.bin` (raw,
/// byte-identical) + `meta.json` (the pure side's redacted/serialized
/// meta). Returns the meta.json path, or null on any failure
/// (best-effort — the abort path outranks the capture).
Future<String?> writeStallDumpToDisk(StallDump dump) async {
  final root = stallDumpDirectory();
  final stamp = dump.dumpedAt.toIso8601String().replaceAll(RegExp('[:.]'), '-');
  final dir = Directory(
    '${root.path}${Platform.pathSeparator}stall-$stamp-${dump.watchdog}',
  );
  dir.createSync(recursive: true);
  final bytes = dump.payloadBytes;
  if (bytes != null) {
    File(
      '${dir.path}${Platform.pathSeparator}payload.bin',
    ).writeAsBytesSync(bytes, flush: true);
  }
  final metaFile = File('${dir.path}${Platform.pathSeparator}meta.json');
  metaFile.writeAsStringSync(serializeStallMeta(dump), flush: true);
  return metaFile.path;
}

/// Installs the disk sink for [stallDumpSink] (the pure side's seam).
/// Idempotent. [installProviderStallForensics] (conn_trace_io.dart) calls
/// this; hosts that want dumps without the conn-trace stderr lines can
/// call it directly.
void installStallSentinelDiskSink() {
  stallDumpSink ??= writeStallDumpToDisk;
}

/// JSON encode of the redacted meta (kept here so the pure side never
/// needs dart:convert's IO-adjacent surface; identical output).
String encodeStallMeta(Map<String, dynamic> meta) => jsonEncode(meta);
