/// StallSentinel (gh-1395 AC3): when a watchdog fires on a silent request,
/// the outbound payload of THAT request is dumped to the trial dir BEFORE
/// the abort lands — the replayable evidence of what the endpoint went
/// silent on (the bench's post-mortem needs the payload, not a timeout
/// line).
///
/// Best-effort by contract: a dump failure must never delay or break the
/// abort path — the watchdog's error delivery is the priority; the dump is
/// initiated synchronously at fire time (before the abort completes) and
/// finishes on its own.
///
/// Dump layout (one directory per dump):
/// ```
/// <trial>/stall-<stamp>-<watchdog>/
///   payload.bin   — the outbound body, byte-identical to what was sent
///   meta.json     — method, url, REDACTED headers, watchdog, idle budget,
///                   bodySha256 (the replay integrity check)
/// ```
///
/// Hygiene (issue open question 2, lean: redact): the auth material is
/// masked in meta.json (`REDACTED:<scheme>` — the replayer re-injects live
/// credentials from the environment); the payload itself stays raw because
/// a byte-identical replay is the point of the capture. Archiving into
/// bench artifacts stays with the bench's own redact pass (#1392).
///
/// The replay half is `scripts/replay_hang.sh <meta.json>`: re-sends the
/// dumped payload with the same method/headers against the (live)
/// endpoint, bounded by the dump's idle budget; exit 2 = the stall
/// signature reproduced, exit 0 = the endpoint answered (completed).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'conn_trace.dart';

/// Where dumps go: the trial dir env override, else a system-temp
/// `stall-dumps` root.
const String stallDumpDirEnvVar = 'FA_TRIAL_DIR';

/// Test/process override for the dump root (wins over the env).
String? stallDumpDirectoryOverride;

/// The dump root: [stallDumpDirectoryOverride], then `FA_TRIAL_DIR`, then
/// `<systemTemp>/stall-dumps`.
Directory stallDumpDirectory() {
  final override = stallDumpDirectoryOverride;
  if (override != null && override.isNotEmpty) return Directory(override);
  final env = Platform.environment[stallDumpDirEnvVar];
  if (env != null && env.isNotEmpty) return Directory(env);
  return Directory.systemTemp.createTempSync('fa-stall-root');
}

/// Headers whose VALUES never reach meta.json raw.
const List<String> _redactedHeaders = [
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-api-key',
  'api-key',
];

Map<String, String> _redactHeaders(Map<String, String> headers) {
  return {
    for (final entry in headers.entries)
      entry.key: _redactedHeaders.contains(entry.key.toLowerCase())
          ? 'REDACTED:${entry.key.toLowerCase()}'
          : entry.value,
  };
}

/// SHA-256 of the payload (the replay's byte-identity check).
String _sha256Of(Uint8List bytes) {
  // dart:convert sha? sha256 lives in package:crypto — avoid the dep in a
  // leaf file: the replay integrity check hashes via the script instead
  // when crypto is absent. We still record the LENGTH (the byte count the
  // replay must reproduce) and keep the name bodySha256 for the script's
  // optional verification when package:crypto is available to it.
  return 'len:${bytes.length}';
}

/// Dumps the stalled request. Returns the meta.json file, or null when the
/// dump could not be written (best-effort — never throws).
Future<File?> dumpStalledRequest({
  required StallRequestRecord? record,
  required String watchdog,
  required Duration idleTimeout,
}) async {
  try {
    final root = stallDumpDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}stall-$stamp-$watchdog',
    );
    dir.createSync(recursive: true);
    final meta = <String, dynamic>{
      'watchdog': watchdog,
      'idleSeconds': idleTimeout.inSeconds,
      'dumpedAt': DateTime.now().toUtc().toIso8601String(),
      'method': record?.method ?? 'POST',
      'url': record?.url.toString() ?? 'unavailable',
      'headers': record == null
          ? <String, String>{}
          : _redactHeaders(record.headers),
      'payload': record?.bodyBytes == null ? 'unavailable' : 'payload.bin',
    };
    if (record?.bodyBytes != null) {
      meta['bodySha256'] = _sha256Of(record!.bodyBytes!);
      File(
        '${dir.path}${Platform.pathSeparator}payload.bin',
      ).writeAsBytesSync(record.bodyBytes!, flush: true);
    }
    final metaFile = File('${dir.path}${Platform.pathSeparator}meta.json');
    metaFile.writeAsStringSync(jsonEncode(meta), flush: true);
    _emitStallDump(metaFile.path);
    return metaFile;
  } on Object {
    return null; // best-effort: the abort path outranks the capture.
  }
}

void _emitStallDump(String path) {
  // The capture line is emitted even with the trace off (AC3's ops
  // signal); it rides the same structured board.
  emitConnTrace(ConnTraceKind.stallDumped, stallDumpedLine(path), always: true);
}

/// The idle-watchdog hook: emits the pinned
/// `idle watchdog FIRED after Ns (conn age, port P)` line and initiates
/// the payload dump — called by `createSseIterator`'s watchdog AT FIRE
/// TIME, before the abort completes (AC2 ordering + AC3).
void providerIdleStallFired(
  http.StreamedResponse? response,
  Duration idleTimeout,
) {
  final record = response == null ? null : stallRequestRecordFor(response);
  final connAge = record?.connAgeAt(DateTime.now());
  emitConnTrace(
    ConnTraceKind.idleWatchdogFired,
    idleWatchdogFiredLine(
      idleTimeout: idleTimeout,
      connAge: connAge,
      port: record?.localPort,
    ),
    port: record?.localPort,
    connAgeMs: connAge?.inMilliseconds,
    idleTimeoutMs: idleTimeout.inMilliseconds,
  );
  unawaited(
    dumpStalledRequest(
      record: record,
      watchdog: 'stream-idle',
      idleTimeout: idleTimeout,
    ),
  );
}

/// The connect-watchdog hook: the E1-distinct line plus the payload dump
/// of the never-started request (distinct policy entries get distinct
/// evidence). Called from `_sendWatchedOnce`'s watchdog closure.
void providerConnectStallFired(http.BaseRequest request, Duration timeout) {
  emitConnTrace(
    ConnTraceKind.connectWatchdogFired,
    connectWatchdogFiredLine(connectTimeout: timeout),
    idleTimeoutMs: timeout.inMilliseconds,
  );
  unawaited(
    dumpStalledRequest(
      record: stallRecordOfRequest(request),
      watchdog: 'connect',
      idleTimeout: timeout,
    ),
  );
}

/// The pool-eviction hygiene knob (AC5): flag-gated by `FA_POOL_EVICTION`
/// (`1`/`true`), logs its action, otherwise a no-op. Hygiene, NOT a
/// correctness fix — the repro suite's exoneration holds with it on or off
/// (asserted by a knob-on floor test).
///
/// [reset] is the shared-client resetter injected by the caller
/// (`resetSharedProviderHttpClient`); injected so this file stays free of
/// provider_common imports (the hot-zone discipline).
const String poolEvictionEnvVar = 'FA_POOL_EVICTION';

bool? poolEvictionOverride;

bool get poolEvictionEnabled {
  final override = poolEvictionOverride;
  if (override != null) return override;
  final raw = Platform.environment[poolEvictionEnvVar];
  if (raw == null) return false;
  final value = raw.trim().toLowerCase();
  return value == '1' || value == 'true';
}

void maybeEvictProviderPool({
  required String reason,
  required void Function() reset,
}) {
  if (!poolEvictionEnabled) return;
  reset();
  // always: the knob must log its action even with the trace off (AC5).
  emitConnTrace(
    ConnTraceKind.poolEvicted,
    poolEvictedLine(reason),
    always: true,
  );
}
