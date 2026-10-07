/// The `dart:io` ConnTrace implementation (see `conn_trace_stub.dart` for
/// the contract). Root library imports this conditionally:
///
/// ```dart
/// export 'conn_trace_stub.dart' if (dart.library.io) 'conn_trace_io.dart';
/// ```
///
/// [TracedProviderClient] replaces the anonymous `http.Client()` in
/// [sharedProviderHttpClient] when tracing is on: it speaks `dart:io`
/// HttpClient directly so every response carries `connectionInfo` — the
/// only way to see the LOCAL PORT and fresh-vs-reused state of the
/// keep-alive pool (package:http hides both). Reuse detection keys on the
/// local port: a keep-alive pool hands the same local socket back, so a
/// local port seen on a previous response means REUSED; a new port means
/// FRESH. Wire format: one `FA_CONN {json}` line per event on stderr and
/// appended to `FA_CONN_TRACE_FILE` when set.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const _connPrefix = 'FA_CONN ';
const _slowFirstByteSec = 120.0;

final class ConnTrace {
  ConnTrace._();

  static final ConnTrace instance = ConnTrace._();

  bool _enabled = false;
  bool _configured = false;
  String? _traceFilePath;

  /// Where [payloadSnapshot] writes the last outbound request (StallSentinel
  /// replay input). [enable] seeds it from FA_CONN_PAYLOAD_SNAPSHOT; tests
  /// may assign it directly.
  String? payloadSnapshotPath;

  /// Whether [payloadSnapshot] keeps Authorization/cookie headers. [enable]
  /// seeds it from FA_CONN_PAYLOAD_KEEP_AUTH=1; tests may assign directly.
  bool keepAuthInSnapshots = false;
  bool _keepAuth = false;
  int _seq = 0;
  int? _lastLocalPort;
  double? _lastConnAgeSec;

  bool get enabled => _enabled;

  /// Test seam: when set, lines land here instead of stderr.
  void Function(String line)? emitSink;

  int get nextSeq => ++_seq;

  int? get lastLocalPort => _lastLocalPort;

  double? get lastConnAgeSec => _lastConnAgeSec;

  /// Reads FA_CONN_DEBUG / FA_PROVIDER_DEBUG once; idempotent.
  void configureFromEnv() {
    if (_configured) return;
    _configured = true;
    if (_flag(Platform.environment['FA_CONN_DEBUG']) ||
        _flag(Platform.environment['FA_PROVIDER_DEBUG'])) {
      enable();
    }
  }

  /// Force-enable (bench workflows set the env and let
  /// [configureFromEnv] do this; tests may call it directly).
  /// Force-enable (bench workflows set the env and let
  /// [configureFromEnv] do this; tests may call it directly).
  ///
  /// The payload snapshot is STRICTLY OPT-IN ([payloadSnapshotPath] only
  /// when FA_CONN_PAYLOAD_SNAPSHOT is set — review round 2: capturing the
  /// whole conversation body to a predictable /tmp path must never be a
  /// silent side effect of turning tracing on).
  void enable() {
    _enabled = true;
    _traceFilePath = Platform.environment['FA_CONN_TRACE_FILE'];
    payloadSnapshotPath = Platform.environment['FA_CONN_PAYLOAD_SNAPSHOT'];
    keepAuthInSnapshots = _flag(
      Platform.environment['FA_CONN_PAYLOAD_KEEP_AUTH'],
    );
    _keepAuth = keepAuthInSnapshots;
  }

  /// Resets every piece of process state (tests).
  void resetForTest() {
    _enabled = false;
    _configured = false;
    _seq = 0;
    _lastLocalPort = null;
    _lastConnAgeSec = null;
    emitSink = null;
    payloadSnapshotPath = null;
    keepAuthInSnapshots = false;
    _keepAuth = false;
  }

  /// The traced client for [sharedProviderHttpClient], or null when
  /// tracing is off.
  http.Client? tracedClient() => _enabled ? TracedProviderClient() : null;

  // --- event emitters ---

  void requestStart({
    required int seq,
    required String method,
    required String url,
    required bool? fresh,
    int? localPort,
    int? poolSize,
    double? connAgeSec,
  }) {
    emit({
      'event': 'request_start',
      'seq': seq,
      'method': method,
      // Query stripped: key-in-query providers would leak the credential
      // into every run log (issue #1392 review).
      'url': redactUrlForLog(url),
      'fresh': fresh,
      'localPort': ?localPort,
      'poolSize': ?poolSize,
      'connAgeSec': ?_round2(connAgeSec),
    });
  }

  /// A fresh connect that never came up (refused / DNS / no route).
  /// Deliberately NOT a [staleSocket] — blaming the previously pooled
  /// socket for every outage made the stale-connection metric
  /// meaningless (issue #1392 review, AC9 discrimination).
  void connectFailed({required String error}) {
    emit({'event': 'connect_failed', 'error': error});
  }

  /// The URL as it may appear in LOG lines: query stripped entirely —
  /// key-in-query providers (Google-style ?key=…) would otherwise leak
  /// live credentials into run logs and artifacts (issue #1392 review).
  static String redactUrlForLog(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasQuery) return raw;
    return uri.replace(query: null).toString();
  }

  /// The URL as it may land in the payload SNAPSHOT (replayable): query
  /// KEPT (a replay needs the request shape) but credential-looking
  /// values masked — bench flows are header-auth and unaffected.
  static String redactUrlForSnapshot(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasQuery) return raw;
    final masked = <String, String>{
      for (final entry in uri.queryParameters.entries)
        entry.key: _sensitiveQueryParam(entry.key)
            ? '**redacted**'
            : entry.value,
    };
    return uri.replace(queryParameters: masked).toString();
  }

  static bool _sensitiveQueryParam(String name) {
    final key = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return key == 'key' ||
        key == 'apikey' ||
        key == 'token' ||
        key == 'accesstoken' ||
        key == 'signature' ||
        key == 'sig' ||
        key == 'secret' ||
        key == 'password';
  }

  void firstByte({
    required int seq,
    required double wallSec,
    required bool fresh,
    int? localPort,
    int? poolSize,
    double? connAgeSec,
  }) {
    emit({
      'event': 'first_byte',
      'seq': seq,
      'wallSec': _round(wallSec),
      'slow': wallSec > _slowFirstByteSec,
      'fresh': fresh,
      'localPort': ?localPort,
      'poolSize': ?poolSize,
      'connAgeSec': ?_round2(connAgeSec),
    });
    _lastLocalPort = localPort;
    _lastConnAgeSec = connAgeSec;
  }

  void requestDone({required int seq, required int statusCode}) {
    emit({'event': 'request_done', 'seq': seq, 'statusCode': statusCode});
  }

  void connectWatchdogFired({
    required double timeoutSec,
    required int attempt,
  }) {
    emit({
      'event': 'connect_watchdog_fired',
      'timeoutSec': _round(timeoutSec),
      'attempt': attempt,
    });
  }

  void idleWatchdogFired({
    required double idleSec,
    double? connAgeSec,
    int? localPort,
  }) {
    emit({
      'event': 'idle_watchdog_fired',
      'idleSec': _round(idleSec),
      'connAgeSec': ?_round2(connAgeSec),
      'localPort': ?localPort,
    });
  }

  void retryScheduled({
    required int attempt,
    required double delaySec,
    required String reason,
  }) {
    emit({
      'event': 'retry',
      'attempt': attempt,
      'delaySec': _round(delaySec),
      'reason': reason,
    });
  }

  void staleSocket({int? localPort, double? ageSec, required String error}) {
    emit({
      'event': 'stale_socket',
      'localPort': ?localPort,
      'ageSec': ?_round2(ageSec),
      'error': error,
    });
  }

  void streamError({int? seq, required String error}) {
    emit({'event': 'stream_error', 'seq': ?seq, 'error': error});
  }

  /// Writes the last outbound request payload for the bench StallSentinel
  /// (`hang-*.json` replay, issue #1392 AC3). Authorization / cookie
  /// headers are redacted unless FA_CONN_PAYLOAD_KEEP_AUTH=1.
  void payloadSnapshot({
    required String method,
    required String url,
    required Map<String, String> headers,
    required String body,
  }) {
    if (!_enabled) return;
    final path = payloadSnapshotPath;
    if (path == null) return;
    final keepAuth = keepAuthInSnapshots || _keepAuth;
    final sanitized = <String, String>{
      for (final entry in headers.entries)
        entry.key: (keepAuth || !_sensitive(entry.key))
            ? entry.value
            : '**redacted**',
    };
    unawaited(
      File(path)
          .writeAsString(
            jsonEncode({
              'capturedAtSec': DateTime.now().millisecondsSinceEpoch / 1000.0,
              'method': method,
              'url': redactUrlForSnapshot(url),
              'headers': sanitized,
              'body': body,
            }),
            flush: true,
          )
          .then((_) {}, onError: (Object _) {}),
    );
  }

  void emit(Map<String, Object?> event) {
    if (!_enabled) return;
    final line = _connPrefix + jsonEncode(event);
    final sink = emitSink;
    if (sink != null) {
      sink(line);
      return;
    }
    stderr.writeln(line);
    final path = _traceFilePath;
    if (path != null) {
      unawaited(
        File(path)
            .writeAsString('$line\n', mode: FileMode.append)
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }
}

/// Provider HTTP client that reports every send/first-byte/through the
/// ConnTrace wire (see the library comment). Used only under
/// FA_CONN_DEBUG — the default path keeps the anonymous `http.Client()`.
final class TracedProviderClient extends http.BaseClient {
  TracedProviderClient({HttpClient? inner}) : _inner = inner ?? HttpClient() {
    _plain = IOClient(_inner);
  }

  final HttpClient _inner;

  /// Fallback transport for requests [send] cannot trace (multipart oauth
  /// posts): the SAME HttpClient, so the pool is shared and honest.
  late final IOClient _plain;

  /// local port -> first-seen record: the keep-alive reuse map.
  ///
  /// [poolSize] on the emitted events counts FIRST-SEEN ports, not live
  /// sockets: a socket the server closes silently between requests
  /// lingers here until a failing reuse evicts it (the [staleSocket]
  /// path), so over a long run the count drifts above the true pool.
  final Map<int, _PortRecord> _ports = {};
  int? _lastUsedPort;

  /// Origin of [_lastUsedPort]: stale-keep-alive attribution is only
  /// meaningful for the origin the pooled socket actually served.
  String? _lastUsedOrigin;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest baseRequest) async {
    if (baseRequest is! http.Request) {
      // Streamed/multipart requests: pass through untraced — tracing must
      // never break an auth flow (copilot oauth posts multipart).
      return _plain.send(baseRequest);
    }
    final request = baseRequest;
    final seq = ConnTrace.instance.nextSeq;
    final stopwatch = Stopwatch()..start();
    var reused = false;
    var localPort = 0;
    final origin = '${request.url.scheme}://${request.url.authority}';
    ConnTrace.instance.requestStart(
      seq: seq,
      method: request.method,
      url: request.url.toString(),
      // Fresh-vs-reused is only knowable once headers arrive; the
      // first_byte event carries the definitive flag.
      fresh: null,
    );
    ConnTrace.instance.payloadSnapshot(
      method: request.method,
      url: request.url.toString(),
      headers: request.headers,
      body: request.body,
    );
    HttpClientRequest? ioRequest;
    try {
      ioRequest = await _inner.openUrl(request.method, request.url);
    } on SocketException catch (error) {
      // The CONNECT phase never picked a pooled socket for THIS origin
      // (dart:io dials fresh): a refusal here is a connect failure, not a
      // stale keep-alive — blaming the previously pooled socket would
      // fabricate a stale-connection signal for every outage (issue
      // #1392 review, AC9's discrimination contract).
      ConnTrace.instance.connectFailed(error: error.message);
      throw http.ClientException(error.message, request.url);
    }
    try {
      // Send + first-byte phase: the pooled keep-alive socket the server
      // closed silently dies exactly here (issue #1392 AC9); failures are
      // attributed by [_blameSendFailure].
      ioRequest.followRedirects = request.followRedirects;
      ioRequest.maxRedirects = request.maxRedirects;
      request.headers.forEach(ioRequest.headers.set);
      ioRequest.contentLength = request.bodyBytes.length;
      ioRequest.add(request.bodyBytes);
      final ioResponse = await ioRequest.close();
      final info = ioResponse.connectionInfo;
      localPort = info?.localPort ?? 0;
      final firstSeen = _ports[localPort];
      if (localPort != 0) {
        if (firstSeen == null) {
          _ports[localPort] = _PortRecord(
            since: DateTime.now(),
            origin: origin,
          );
        } else {
          reused = true;
        }
        _lastUsedPort = localPort;
        _lastUsedOrigin = origin;
      }
      final firstByteSec = stopwatch.elapsedMicroseconds / 1e6;
      ConnTrace.instance.firstByte(
        seq: seq,
        wallSec: firstByteSec,
        fresh: !reused,
        localPort: localPort == 0 ? null : localPort,
        poolSize: _ports.length,
        connAgeSec: _ageOf(localPort),
      );
      final response = http.StreamedResponse(
        ioResponse,
        ioResponse.statusCode,
        // dart:io reports -1 (chunked/SSE) where package:http wants null.
        contentLength: ioResponse.contentLength < 0
            ? null
            : ioResponse.contentLength,
        request: request,
        headers: _headerMap(ioResponse.headers),
        isRedirect: ioResponse.isRedirect,
        persistentConnection: ioResponse.persistentConnection,
        reasonPhrase: ioResponse.reasonPhrase,
      );
      ConnTrace.instance.requestDone(
        seq: seq,
        statusCode: ioResponse.statusCode,
      );
      return response;
    } on SocketException catch (error) {
      _blameSendFailure(request.url, error.message, connectPhase: false);
      throw http.ClientException(error.message, request.url);
    } on HttpException catch (error) {
      // dart:io's "Connection closed before response" surfaces as
      // HttpException, not SocketException — same transport-failure class;
      // the traced client must never leak a dart:io exception type.
      _blameSendFailure(request.url, error.message, connectPhase: false);
      throw http.ClientException(error.message, request.url);
    } on http.ClientException catch (error) {
      // IOClient-style wrapped transport failures ("Connection closed
      // while receiving data") are the same transport-failure class.
      _blameSendFailure(request.url, error.message, connectPhase: false);
      rethrow;
    }
  }

  /// Attributes a send-phase transport failure WITHOUT fabricating stale
  /// connections (issue #1392 review): only a failure on a request whose
  /// origin matches a pooled socket we have actually used is the silent
  /// keep-alive close signature (AC9) — that socket is named and evicted.
  /// Anything else is recorded (connect_failed / stream_error) and the
  /// pool map is left alone.
  void _blameSendFailure(
    Uri url,
    String message, {
    required bool connectPhase,
  }) {
    final origin = '${url.scheme}://${url.authority}';
    final port = _lastUsedPort;
    if (!connectPhase && port != null && _lastUsedOrigin == origin) {
      ConnTrace.instance.staleSocket(
        localPort: port,
        ageSec: _ageOf(port),
        error: message,
      );
      _ports.remove(port);
      _lastUsedPort = null;
      _lastUsedOrigin = null;
      return;
    }
    if (connectPhase) {
      ConnTrace.instance.connectFailed(error: message);
    } else {
      ConnTrace.instance.streamError(error: message);
    }
  }

  /// First-seen pool entries (tests): see the [_ports] doc on why this is
  /// not the live-socket count.
  int get poolSizeForTest => _ports.length;

  /// The stale-keep-alive decision, exposed for the AC9 unit tests: a
  /// same-origin send-phase failure with a pooled socket must name and
  /// evict that socket; a fresh-connect refusal or a different-origin
  /// failure must not touch the pool.
  void blameSendFailureForTest(
    Uri url,
    String message, {
    bool connectPhase = false,
  }) => _blameSendFailure(url, message, connectPhase: connectPhase);

  double? _ageOf(int? port) {
    final record = port == null ? null : _ports[port];
    if (record == null) return null;
    return DateTime.now().difference(record.since).inMicroseconds / 1e6;
  }

  @override
  void close() {
    // BaseClient.close() is a no-op; without this the inner HttpClient —
    // the owner of the keep-alive pool — leaks for every traced-client
    // owner. force:false lets in-flight responses finish.
    _inner.close(force: false);
  }
}

/// First-seen record for a pooled local port.
class _PortRecord {
  _PortRecord({required this.since, required this.origin});

  final DateTime since;
  final String origin;
}

bool _flag(String? raw) {
  if (raw == null) return false;
  final value = raw.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes' || value == 'on';
}

bool _sensitive(String header) {
  final name = header.toLowerCase();
  return name == 'authorization' || name == 'cookie' || name == 'set-cookie';
}

double _round(double value) => double.parse(value.toStringAsFixed(3));

double? _round2(double? value) => value == null ? null : _round(value);

Map<String, String> _headerMap(HttpHeaders headers) {
  final map = <String, String>{};
  headers.forEach((name, values) => map[name] = values.join(', '));
  return map;
}

/// Call-side handle ([provider_common.dart] and tests): the seam picks
/// the real instance on VM/IO targets and the no-op on web.
ConnTrace get connTrace => ConnTrace.instance;
