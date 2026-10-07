/// StallSentinel (gh-1395 AC3): when a watchdog fires on a silent request,
/// the outbound payload of THAT request is dumped to the trial dir BEFORE
/// the abort lands — the replayable evidence of what the endpoint went
/// silent on (the bench's post-mortem needs the payload, not a timeout
/// line).
///
/// PURE Dart (barrel-exported; the dart2js web build pulls it): this file
/// decides WHAT to dump — the allowlist-redacted meta, the real SHA-256,
/// the per-process dump budget — and hands it to the injected
/// [stallDumpSink]. The disk writer lives in `stall_sentinel_io.dart`
/// (reachable only through `lib/io.dart`) and is installed at the host
/// boundary by `installProviderStallForensics()`; an unset sink means
/// dumps are dropped (the web build never dumps).
///
/// Gated by [stallSentinelEnabled] (`FA_STALL_SENTINEL=0` opts out —
/// `conn_trace.dart` owns the knob): with the sentinel off, requests are
/// not recorded with their bodies (no `Expando` retention) and no dump is
/// attempted.
///
/// Best-effort by contract: a dump failure must never delay or break the
/// abort path — the watchdog's error delivery is the priority; the dump is
/// initiated synchronously at fire time (before the abort completes) and
/// finishes on its own.
///
/// Dump layout (one directory per dump; produced by the io sink):
/// ```
/// <trial>/stall-<stamp>-<watchdog>/
///   payload.bin   — the outbound body, byte-identical to what was sent
///   meta.json     — method, url, REDACTED headers (ALLOWLIST: only
///                   non-credential headers survive), watchdog, idle
///                   budget, bodySha256 (the replay integrity check)
/// ```
///
/// Header redaction is an ALLOWLIST (review round 1, blocking): credential
/// carriers differ per provider (`authorization`, `x-api-key`,
/// `x-goog-api-key`, user-configured `authHeader` names, cookies) and a
/// blocklist always lags the producers — only headers on
/// [safeForensicHeaders] reach meta.json, everything else is masked to
/// `REDACTED:<name>`. The payload itself stays raw because a
/// byte-identical replay is the point of the capture; `scripts/
/// replay_hang.sh` re-injects live credentials from the environment.
///
/// The replay half is `scripts/replay_hang.sh <meta.json>`: re-sends the
/// dumped payload with the same method/headers against the (live)
/// endpoint, bounded by the dump's idle budget; exit 2 = the stall
/// signature reproduced, exit 0 = the endpoint answered (completed).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'conn_trace.dart';

/// Where dumps go: the trial dir env override, else a system-temp
/// `stall-dumps` root. (Read by the io sink.)
const String stallDumpDirEnvVar = 'FA_TRIAL_DIR';

/// Test/process override for the dump root (wins over the env). Read by
/// the io sink.
String? stallDumpDirectoryOverride;

/// Headers that carry NO credential material and may reach meta.json
/// verbatim. The allowlist is the security boundary — a header not listed
/// here is masked even if a future provider ships its auth in a new name.
const List<String> safeForensicHeaders = [
  'accept',
  'accept-encoding',
  'accept-language',
  'cache-control',
  'content-type',
  'user-agent',
];

/// Builds the REDACTED header map for meta.json: allowlisted headers keep
/// their values, everything else becomes `REDACTED:<name>` (case kept).
Map<String, String> redactHeadersForMeta(Map<String, String> headers) {
  final allowed = safeForensicHeaders.toSet();
  return {
    for (final entry in headers.entries)
      entry.key: allowed.contains(entry.key.toLowerCase())
          ? entry.value
          : 'REDACTED:${entry.key.toLowerCase()}',
  };
}

/// SHA-256 of the payload (the replay's byte-identity check) — the real
/// digest: `crypto` is already a direct dependency.
String stallPayloadSha256(Uint8List bytes) =>
    crypto.sha256.convert(bytes).toString();

/// One pending dump, fully redacted and payload-ready: the sink's input.
final class StallDump {
  const StallDump({
    required this.watchdog,
    required this.idleTimeout,
    required this.dumpedAt,
    required this.method,
    required this.url,
    required this.redactedHeaders,
    required this.payloadBytes,
  });

  /// Which watchdog fired (`stream-idle` / `connect`).
  final String watchdog;

  /// The watchdog budget in effect (the replay's bound).
  final Duration idleTimeout;

  /// When the dump was initiated.
  final DateTime dumpedAt;

  /// HTTP method of the stalled request.
  final String method;

  /// The request URL (verbatim; the io sink writes it as-is).
  final String url;

  /// The ALLOWLIST-redacted headers (credential carriers masked).
  final Map<String, String> redactedHeaders;

  /// The outbound payload bytes, when captured (null = unavailable).
  final Uint8List? payloadBytes;
}

/// The dump sink: writes the dump and returns the artifact path (for the
/// trace line), or null when it could not be written. Null sink = dumps
/// are dropped (the pure/web default).
typedef StallDumpSink = Future<String?> Function(StallDump dump);

/// The io-installed disk writer (`stall_sentinel_io.dart`); null keeps the
/// capture decision pure and drops the dump.
StallDumpSink? stallDumpSink;

/// The per-process dump budget (review round 1: a black-holed endpoint
/// must not fill the disk — after this many dumps the sentinel stops
/// writing and says so once on the trace board).
const int maxStallDumpsPerProcess = 8;

int _dumpsWritten = 0;
bool _budgetSpent = false;

/// Test hook: resets the dump budget counters.
void resetStallDumpBudgetForTest() {
  _dumpsWritten = 0;
  _budgetSpent = false;
}

/// Dumps the stalled request. Returns the meta.json path, or null when the
/// dump was skipped (sentinel off, budget spent, no sink) or could not be
/// written (best-effort — never throws).
Future<String?> dumpStalledRequest({
  required StallRequestRecord? record,
  required String watchdog,
  required Duration idleTimeout,
}) async {
  if (!stallSentinelEnabled) return null;
  if (_dumpsWritten >= maxStallDumpsPerProcess) {
    if (!_budgetSpent) {
      _budgetSpent = true;
      emitConnTrace(
        ConnTraceKind.stallDumped,
        'stall dump budget spent ($maxStallDumpsPerProcess dumps) — '
        'further payloads skipped this process',
        always: true,
      );
    }
    return null;
  }
  final sink = stallDumpSink;
  if (sink == null) return null;
  try {
    final bytes = record?.bodyBytes;
    final path = await sink(
      StallDump(
        watchdog: watchdog,
        idleTimeout: idleTimeout,
        dumpedAt: DateTime.now().toUtc(),
        method: record?.method ?? 'POST',
        url: record?.url.toString() ?? 'unavailable',
        redactedHeaders: record == null
            ? <String, String>{}
            : redactHeadersForMeta(record.headers),
        payloadBytes: bytes,
      ),
    );
    if (path == null) return null;
    _dumpsWritten++;
    _emitStallDump(path);
    return path;
  } on Object {
    return null; // best-effort: the abort path outranks the capture.
  }
}

/// Builds the meta.json map (the io sink serializes it verbatim; exposed
/// for the contract test that pins the redaction + integrity fields).
Map<String, dynamic> buildStallMeta(StallDump dump) {
  final meta = <String, dynamic>{
    'watchdog': dump.watchdog,
    'idleSeconds': dump.idleTimeout.inSeconds,
    'dumpedAt': dump.dumpedAt.toIso8601String(),
    'method': dump.method,
    'url': dump.url,
    'headers': dump.redactedHeaders,
    'payload': dump.payloadBytes == null ? 'unavailable' : 'payload.bin',
  };
  if (dump.payloadBytes != null) {
    meta['bodySha256'] = stallPayloadSha256(dump.payloadBytes!);
  }
  return meta;
}

/// The meta.json serializer (jsonEncode of [buildStallMeta]) — pure, so
/// the contract test can pin the exact on-disk bytes.
String serializeStallMeta(StallDump dump) => jsonEncode(buildStallMeta(dump));

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
  final lookup = providerStackEnvLookup;
  if (lookup == null) return false;
  return _flagValue(lookup(poolEvictionEnvVar));
}

bool _flagValue(String? raw) {
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
