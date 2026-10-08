/// Web-safe stub for `conn_trace_io.dart` (issue #1392 bench round 3).
///
/// ConnTrace is the connection forensics hook: when `FA_CONN_DEBUG=1`
/// (or `FA_PROVIDER_DEBUG`) is set, every provider HTTP lifecycle event
/// — request start (fresh vs reused from the keep-alive pool, local
/// port, pool size), first byte (with the >120s slow flag), connect /
/// stream-idle watchdog fires, transparent retries, stale keep-alive
/// sockets — emits one structured `FA_CONN {json}` line to stderr and to
/// `FA_CONN_TRACE_FILE`, so a bench stall is diagnosable from the run
/// log instead of being a 300s-shaped guess.
///
/// The real implementation reads `dart:io` (`HttpClient.connectionInfo`
/// for the local port, socket errors for stale-socket detection), so web
/// builds of the root library import this file conditionally:
///
/// ```dart
/// export 'conn_trace_stub.dart' if (dart.library.io) 'conn_trace_io.dart';
/// ```
///
/// On web tracing never enables: [ConnTrace.enabled] stays false and
/// every emit is a no-op — call sites compile unchanged against the same
/// API surface.
library;

import 'package:http/http.dart' as http;

/// ConnTrace API surface (see the library comment): a no-op on web.
final class ConnTrace {
  ConnTrace._();

  /// Process-wide instance ([sharedProviderHttpClient] and the provider
  /// send paths talk to this one object).
  static final ConnTrace instance = ConnTrace._();

  /// Whether tracing is on. False on web, always.
  bool get enabled => false;

  /// Test seam: when set, lines land here instead of stderr.
  void Function(String line)? emitSink;

  /// Monotonic per-process request sequence number.
  int get nextSeq => 0;

  /// The local port of the connection currently carrying a response (set
  /// by the traced client at first byte; single-flight bench contract).
  int? get lastLocalPort => null;

  /// Seconds the current connection has been alive at first byte.
  double? get lastConnAgeSec => null;

  /// Reads FA_CONN_DEBUG / FA_PROVIDER_DEBUG once; idempotent.
  void configureFromEnv() {}

  /// Force-enable (bench workflows set the env and let
  /// [configureFromEnv] do this; tests may call it directly).
  void enable() {}

  /// Resets every piece of process state (tests).
  void resetForTest() {}

  /// Where [payloadSnapshot] writes the last outbound request
  /// (StallSentinel replay input). No-op storage on web.
  String? payloadSnapshotPath;

  /// Whether [payloadSnapshot] keeps Authorization/cookie headers.
  bool keepAuthInSnapshots = false;

  /// The traced client for [sharedProviderHttpClient], or null when
  /// tracing is off / the platform has no dart:io client.
  http.Client? tracedClient() => null;

  // --- event emitters (all no-ops unless enabled) ---

  void requestStart({
    required int seq,
    required String method,
    required String url,
    required bool? fresh,
    int? localPort,
    int? poolSize,
    double? connAgeSec,
  }) {}

  void firstByte({
    required int seq,
    required double wallSec,
    required bool fresh,
    int? localPort,
    int? poolSize,
    double? connAgeSec,
  }) {}

  void requestDone({required int seq, required int statusCode}) {}

  void connectWatchdogFired({
    required double timeoutSec,
    required int attempt,
  }) {}

  void idleWatchdogFired({
    required double idleSec,
    double? connAgeSec,
    int? localPort,
  }) {}

  void retryScheduled({
    required int attempt,
    required double delaySec,
    required String reason,
  }) {}

  void staleSocket({int? localPort, double? ageSec, required String error}) {}

  void streamError({int? seq, required String error}) {}

  /// Writes the last outbound request payload for the bench StallSentinel
  /// (`hang-*.json` replay, issue #1392 AC3). Authorization is redacted
  /// unless FA_CONN_PAYLOAD_KEEP_AUTH=1.
  void payloadSnapshot({
    required String method,
    required String url,
    required Map<String, String> headers,
    required String body,
  }) {}
}

/// Web stand-in for the dart:io traced client: never constructed in
/// production ([tracedClient] returns null when tracing is off, and
/// tracing never enables on web) — the type exists so call sites and the
/// shared accessor compile unchanged against the seam.
final class TracedProviderClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  /// Web surface parity with the io implementation (the analyzer resolves
  /// the seam's first branch for member lookup): never constructed here —
  /// tracing never enables on web.
  int get poolSizeForTest => 0;

  void blameSendFailureForTest(
    Uri url,
    String message, {
    bool connectPhase = false,
  }) {}
}

/// Call-side handle ([provider_common.dart] and tests): the seam picks
/// the real instance on VM/IO targets and the no-op on web.
ConnTrace get connTrace => ConnTrace.instance;
