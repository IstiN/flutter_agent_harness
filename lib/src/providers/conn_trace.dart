/// ConnTrace (gh-1395 AC2): one structured line per provider connection
/// open, per first response byte, and per watchdog fire — the forensics
/// that turn "the bench went silent for 300 s" into "conn open (fresh,
/// port P) at t0, first byte at t1, idle watchdog FIRED after 300 s (conn
/// age, port P)".
///
/// Gated by the `FA_CONN_DEBUG` env knob ([connTraceEnabled]): with the
/// knob off the traced client is a pass-through — the caller gets the
/// IDENTICAL [http.StreamedResponse] object, no stream wrapping, no timer
/// churn (E4, asserted by a no-op test). With the knob on, lines go to
/// stderr (prefixed `[conn-trace] `) AND into the structured event board
/// ([connTraceEvents] / [connTraceSink]) that the bench's LatencyMeter
/// aggregation consumes unchanged (#1392 owns that wiring).
///
/// The client wrapper ALSO records every in-flight request against its
/// response (always, knob or not — the sentinel needs the payload on
/// watchdog fire); the association lives in an `Expando`, so it cannot
/// outlive the response object.
///
/// The observed dart:io client (fresh-vs-reused classification + local
/// port) is only built when the host did NOT inject its own
/// [providerHttpClientFactory] product: a native-stack client cannot be
// ignore: comment_references
/// re-opened through `HttpClient.connectionFactory`, so on such hosts the
/// conn-open line degrades to no port (`conn open (reused)`) while the
/// byte and watchdog lines keep working.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;

/// The debug knob: `FA_CONN_DEBUG=1` (or `true`) turns the trace on.
const String connTraceEnvVar = 'FA_CONN_DEBUG';

/// Test override for [connTraceEnabled] (null = read the env).
bool? connTraceOverride;

/// Whether the connection trace is on.
bool get connTraceEnabled {
  final override = connTraceOverride;
  if (override != null) return override;
  final raw = Platform.environment[connTraceEnvVar];
  if (raw == null) return false;
  final value = raw.trim().toLowerCase();
  return value == '1' || value == 'true';
}

/// The structured trace event kinds, in the order a healthy request can
/// produce them.
enum ConnTraceKind {
  /// One provider connection was opened fresh, or a pooled one was reused.
  connOpen,

  /// The first body byte of a response arrived.
  firstByte,

  /// The stream-idle watchdog fired mid-stream.
  idleWatchdogFired,

  /// The connect watchdog fired before any response byte.
  connectWatchdogFired,

  /// The pool-eviction hygiene knob acted (AC5; logged even with the trace
  /// off).
  poolEvicted,

  /// A stalled request's outbound payload was dumped (AC3; logged even
  /// with the trace off).
  stallDumped,
}

/// One structured trace event: [line] is the pinned stderr shape, the rest
/// are the machine-readable fields the bench aggregates.
final class ConnTraceEvent {
  const ConnTraceEvent._(
    this.kind,
    this.line, {
    this.port,
    this.freshConn,
    this.afterMs,
    this.connAgeMs,
    this.idleTimeoutMs,
  });

  /// The event kind.
  final ConnTraceKind kind;

  /// The pinned line (what stderr carries after the `[conn-trace] `
  /// prefix).
  final String line;

  /// The client-side local port of the connection, when known.
  final int? port;

  /// Whether the request rode a freshly opened connection (null: unknown).
  final bool? freshConn;

  /// Milliseconds from request send to the observation, when applicable.
  final int? afterMs;

  /// Connection age at the observation (fresh conns only), when known.
  final int? connAgeMs;

  /// The watchdog budget that was in effect, when applicable.
  final int? idleTimeoutMs;

  @override
  String toString() => line;
}

/// The process-local structured board (bounded ring). [connTraceSink], when
/// set, receives every event as well — that is the seam the bench's
/// `bench_metrics.json` aggregation consumes (#1392 owns the wiring).
final List<ConnTraceEvent> connTraceEvents = <ConnTraceEvent>[];

/// The board's cap — a debug surface must never grow unbounded.
const int _connTraceBoardCap = 512;

/// The structured-event consumer (bench/LatencyMeter). Null keeps the
/// board-only behavior.
void Function(ConnTraceEvent event)? connTraceSink;

/// Clears the board and the sink (tests).
void resetConnTraceForTest() {
  connTraceEvents.clear();
  connTraceSink = null;
}

/// Seconds with two decimals, the trace's time unit (`0.42`, `3.40`).
String _secs(Duration d) =>
    (d.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(2);

/// Watchdog budgets render as whole seconds when whole (`300s`), two
/// decimals otherwise (`0.40s`) — the production budgets stay the pinned
/// `Ns` shape while test overrides stay legible.
String _durSecs(Duration d) =>
    d.inMicroseconds % Duration.microsecondsPerSecond == 0
    ? '${d.inSeconds}s'
    : '${_secs(d)}s';

/// `conn open (fresh, port P)` / `conn open (reused[, port P])`.
String connOpenLine({required bool fresh, int? port}) {
  if (port == null) return fresh ? 'conn open (fresh)' : 'conn open (reused)';
  return 'conn open (${fresh ? 'fresh' : 'reused'}, port $port)';
}

/// `first byte after Ns`.
String firstByteLine(Duration after) => 'first byte after ${_secs(after)}s';

/// The stable keyword of the idle-watchdog line (consumed by tests that
/// must not hard-code the whole shape).
const String idleWatchdogFiredLineKeyword = 'idle watchdog FIRED after';

/// `idle watchdog FIRED after Ns (conn age Ns, port P)` — the conn bits
/// degrade away when the response's connection was not observed.
String idleWatchdogFiredLine({
  required Duration idleTimeout,
  Duration? connAge,
  int? port,
}) {
  var line = '$idleWatchdogFiredLineKeyword ${_durSecs(idleTimeout)}';
  if (connAge != null && port != null) {
    line = '$line (conn age ${_secs(connAge)}s, port $port)';
  }
  return line;
}

/// `connect watchdog FIRED after Ns (no response bytes)` — deliberately
/// distinct from the idle line (E1: distinct watchdogs, distinct lines).
String connectWatchdogFiredLine({required Duration connectTimeout}) =>
    'connect watchdog FIRED after ${_durSecs(connectTimeout)} '
    '(no response bytes)';

/// `pool evicted (reason)` — the AC5 knob's log line.
String poolEvictedLine(String reason) => 'pool evicted ($reason)';

/// `stall payload dumped to <path>` — the AC3 capture line.
String stallDumpedLine(String path) => 'stall payload dumped to $path';

/// Emits one trace event: onto the board (+ sink) and stderr. [always]
/// keeps the line alive when the trace is off (the pool-eviction and
/// dump signals are ops-critical regardless of the knob).
void emitConnTrace(
  ConnTraceKind kind,
  String line, {
  int? port,
  bool? freshConn,
  int? afterMs,
  int? connAgeMs,
  int? idleTimeoutMs,
  bool always = false,
}) {
  if (!always && !connTraceEnabled) return;
  final event = ConnTraceEvent._(
    kind,
    line,
    port: port,
    freshConn: freshConn,
    afterMs: afterMs,
    connAgeMs: connAgeMs,
    idleTimeoutMs: idleTimeoutMs,
  );
  connTraceEvents.add(event);
  if (connTraceEvents.length > _connTraceBoardCap) {
    connTraceEvents.removeAt(0);
  }
  try {
    connTraceSink?.call(event);
  } on Object {
    // A broken consumer must never break the request path.
  }
  stderr.writeln('[conn-trace] $line');
}

void _emit(ConnTraceEvent event, {bool always = false}) {
  emitConnTrace(
    event.kind,
    event.line,
    port: event.port,
    freshConn: event.freshConn,
    afterMs: event.afterMs,
    connAgeMs: event.connAgeMs,
    idleTimeoutMs: event.idleTimeoutMs,
    always: always,
  );
}

/// Dart:io connection observation: one note per OPENED socket, carrying the
/// client-side local port (the connection identity the repro suite keys
/// on) and the open timestamp (the conn age on watchdog fire).
int _openCount = 0;
int? _lastLocalPort;
DateTime? _lastOpenedAt;

/// Called by the observed connection factory when a socket opens. Exposed
/// for tests (the real leg is IT-covered against a loopback server).
void connObserverNote({required int port, required Duration openedAfter}) {
  _openCount++;
  _lastLocalPort = port;
  _lastOpenedAt = DateTime.now().subtract(openedAfter);
}

/// A dart:io [HttpClient] whose connections funnel through the observer
/// above. Debug-only: the factory override re-implements the connect leg
/// (`Socket.startConnect`, TLS via `SecureSocket.startConnect`); proxy
/// connections are traced at the proxy endpoint. Only ever installed when
/// the trace is ON.
HttpClient observeHttpClient() {
  final client = HttpClient();
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final host = proxyHost ?? uri.host;
    final fallbackPort = uri.scheme == 'https' ? 443 : 80;
    final port = proxyPort ?? (uri.port != 0 ? uri.port : fallbackPort);
    final secure = uri.scheme == 'https' && proxyHost == null;
    final watch = Stopwatch()..start();
    final task = secure
        ? await SecureSocket.startConnect(host, port)
        : await Socket.startConnect(host, port);
    unawaited(
      task.socket.then(
        (socket) =>
            connObserverNote(port: socket.port, openedAfter: watch.elapsed),
        onError: (Object _) {},
      ),
    );
    return task;
  };
  return client;
}

/// The outbound-payload record the sentinel reads on watchdog fire: what
/// was sent, where, and on which connection.
final class StallRequestRecord {
  StallRequestRecord._({
    required this.method,
    required this.url,
    required this.headers,
    this.bodyBytes,
    required DateTime sentAt,
    // ignore: prefer_initializing_formals
  }) : _sentAt = sentAt;

  /// HTTP method of the stalled request.
  final String method;

  /// The request URL (userinfo/query included only in the REDACTED dump).
  final Uri url;

  /// Request headers (values held raw; the dump formatter redacts).
  final Map<String, String> headers;

  /// The outbound payload bytes, when the request carried a body that
  /// could be captured.
  final Uint8List? bodyBytes;

  final DateTime _sentAt;

  /// The observed connection bits (fresh conns only, trace on).
  int? localPort;
  DateTime? connOpenedAt;
  bool? freshConn;

  /// When the request was sent.
  DateTime get sentAt => _sentAt;

  /// Connection age at [at], when the connection was observed fresh.
  Duration? connAgeAt(DateTime at) {
    final opened = connOpenedAt;
    if (opened == null) return null;
    return at.difference(opened);
  }
}

/// response → record association. An `Expando` keeps this leak-free: the
/// entry dies with the response object.
final Expando<StallRequestRecord> _responseRecords =
    Expando<StallRequestRecord>();

/// The outbound-payload record of [response], when its request rode a
/// tracked client ([connTraceWrapProviderClient]).
StallRequestRecord? stallRequestRecordFor(http.StreamedResponse response) =>
    _responseRecords[response];

/// Captures the outbound identity + payload of [request] (the sentinel's
/// evidence record; also used by the registry).
StallRequestRecord stallRecordOfRequest(http.BaseRequest request) {
  Uint8List? body;
  if (request is http.Request) {
    try {
      body = request.bodyBytes;
    } on Object {
      body =
          null; // a finalized/streamed body we cannot re-read — dump metadata only.
    }
  }
  return StallRequestRecord._(
    method: request.method,
    url: request.url,
    headers: Map.of(request.headers),
    bodyBytes: body,
    sentAt: DateTime.now(),
  );
}

/// The traced client: pass-through recorder when the trace is off (E4:
/// identical response object, zero wrapping), structured tracer when on.
final class ConnTracedClient extends http.BaseClient {
  ConnTracedClient._(this._inner, {required bool tracing})
    // ignore: prefer_initializing_formals
    : _tracing = tracing;

  final http.Client _inner;
  final bool _tracing;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final record = stallRecordOfRequest(request);
    if (!_tracing) {
      final response = await _inner.send(request);
      _responseRecords[response] = record;
      return response; // E4: the caller's object, untouched.
    }
    final opensBefore = _openCount;
    final sw = Stopwatch()..start();
    final innerResponse = await _inner.send(request);
    final fresh = _openCount > opensBefore;
    final port = _lastLocalPort;
    if (fresh) {
      record.freshConn = true;
      record.localPort = port;
      record.connOpenedAt = _lastOpenedAt;
    } else {
      record.freshConn = false;
    }
    _emit(
      ConnTraceEvent._(
        ConnTraceKind.connOpen,
        connOpenLine(fresh: fresh, port: fresh ? port : null),
        port: fresh ? port : null,
        freshConn: fresh,
      ),
    );
    // First-byte line: a one-shot peek transformer over the body.
    var firstByteSeen = false;
    final traced = innerResponse.stream.transform<List<int>>(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          if (!firstByteSeen) {
            firstByteSeen = true;
            _emit(
              ConnTraceEvent._(
                ConnTraceKind.firstByte,
                firstByteLine(sw.elapsed),
                afterMs: sw.elapsedMilliseconds,
              ),
            );
          }
          sink.add(data);
        },
      ),
    );
    final effectiveResponse = http.StreamedResponse(
      traced,
      innerResponse.statusCode,
      contentLength: innerResponse.contentLength,
      request: innerResponse.request,
      headers: innerResponse.headers,
      isRedirect: innerResponse.isRedirect,
      persistentConnection: innerResponse.persistentConnection,
      reasonPhrase: innerResponse.reasonPhrase,
    );
    // Register the object the CALLER holds (the traced wrapper), so the
    // watchdog hook can find the payload on fire.
    _responseRecords[effectiveResponse] = record;
    return effectiveResponse;
  }

  @override
  void close() => _inner.close();
}

/// Wraps the provider stack's HTTP client. [canInstallObserver] tells the
/// wrapper it may replace the client with an observed dart:io one — true
/// only when the caller built a plain default client (no host-injected
/// factory product).
///
/// Always returns a client whose requests are REGISTERED for the sentinel;
/// the trace lines only appear while [connTraceEnabled].
http.Client connTraceWrapProviderClient(
  http.Client inner, {
  required bool canInstallObserver,
}) {
  if (!connTraceEnabled) {
    return ConnTracedClient._(inner, tracing: false);
  }
  if (canInstallObserver) {
    return ConnTracedClient._(IOClient(observeHttpClient()), tracing: true);
  }
  return ConnTracedClient._(inner, tracing: true);
}
