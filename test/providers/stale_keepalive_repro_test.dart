// Issue #1395 (ReproSuite, AC1) — empirical evidence reframing #1392's bench
// round-2 forensics: does the PROCESS-WIDE keep-alive client
// (`sharedProviderHttpClient`, lib/src/providers/provider_common.dart) stall
// for a watchdog window when the server kills idle keep-alive sockets, and
// does a watchdog abort+retry land on a FRESH connection?
//
// This file is an EMPIRICAL instrument, not a behavior spec: every test
// measures wall-clock classes and pins the observed mechanism with asserts
// that hold for the mechanism's outcome class. Server-side kills are
// simulated four ways, all validated against dart:io 3.13 semantics first:
//
//  1. GRACEFUL idle-kill  — `server.idleTimeout` closes idle keep-alive
//     conns (FIN), the classic server-side keep-alive expiry.
//  2. KILL-ON-ARRIVAL     — the request ARRIVES on the reused pooled conn,
//     then the server `response.detachSocket(writeHeaders: false)` +
//     `destroy()`s the socket without answering (RST). Deterministic proof
//     the pool DID hand out the stale socket (same remote port twice).
//  3. ALIVE-BUT-SILENT    — headers + first SSE event flushed
//     (`bufferOutput = false` — a bare `flush()` does NOT push the head),
//     then the handler holds forever: a healthy socket that stops talking.
//  4. HONEST EOF          — first event, then a clean `response.close()`:
//     the body ends mid-stream without [DONE] (the "stream ended without
//     finish_reason" truncation class).
//
// Not reachable through dart:io's HttpServer (documented limitation): a RST
// racing the pool take on an ALREADY dead-but-unprocessed conn, and a
// mid-body RST after headers were written — `detachSocket` throws "Headers
// already sent" once anything was written, and writing the response on a
// detached raw socket corrupts the pipeline. Those classes are bracketed by
// (2) + (4). A half-open socket (no FIN, no RST — NAT silently dropping) is
// not reproducible on loopback at all: loopback writes into a destroyed
// socket ALWAYS fail fast; see the findings note in the file-ending group.
//
// MockClient cannot test any of this (no socket pool) — a real loopback
// HttpServer on an ephemeral port is the whole point. No external network.
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Outcome of one logical provider call through the REAL production send
/// path: [sharedProviderHttpClient] + [sendProviderRequest] (connect
/// watchdog + connect-stall retry + redirect/validators) +
/// [createSseIterator] (idle watchdog).
final class CallOutcome {
  CallOutcome(
    this.kind,
    this.headersAfter,
    this.total, {
    this.events = 0,
    this.error,
  });

  /// 'ok' | 'transport-error@send' | 'transport-error@body' |
  /// 'connect-watchdog' | 'idle-watchdog' | 'stream-eof'
  final String kind;
  final Duration headersAfter;
  final Duration total;
  final int events;
  final String? error;

  @override
  String toString() =>
      '$kind headers=${headersAfter.inMilliseconds}ms '
      'total=${total.inMilliseconds}ms events=$events'
      '${error == null ? '' : ' error=${_oneLine(error!)}'}';
}

String _oneLine(String text) => text.split('\n').first;

/// Raw dart:http measurement (NO watchdog of ours): what the client library
/// does with a stale pooled socket all by itself.
Future<({String kind, Duration elapsed, String? error})> rawCall(
  Uri url, {
  Duration guard = const Duration(seconds: 4),
}) async {
  final sw = Stopwatch()..start();
  final request = _request(url);
  try {
    final response = await sharedProviderHttpClient()
        .send(request)
        .timeout(guard, onTimeout: () => throw TimeoutException('raw-guard'));
    await response.stream.drain<void>().timeout(
      guard,
      onTimeout: () => throw TimeoutException('raw-guard'),
    );
    return (kind: 'ok', elapsed: sw.elapsed, error: null);
  } on TimeoutException catch (e) {
    final hung = e.message == 'raw-guard';
    return (
      kind: hung ? 'HUNG-until-guard' : 'timeout: ${_oneLine('$e')}',
      elapsed: sw.elapsed,
      error: '$e',
    );
  } catch (e) {
    return (kind: 'error: ${e.runtimeType}', elapsed: sw.elapsed, error: '$e');
  }
}

http.Request _request(Uri url) => http.Request('POST', url)
  ..headers['content-type'] = 'application/json'
  ..headers['authorization'] = 'Bearer sk-repro-1392'
  ..body = '{"model":"repro-1392","stream":true}';

/// One logical streamed call through the production stack. The [idleTimeout]
/// defaults to the override-aware effective value (the same path adapters
/// take when they pass no test override).
Future<CallOutcome> streamedCall(
  Uri url, {
  Duration? idleTimeout,
  CancelToken? cancelToken,
}) async {
  final sw = Stopwatch()..start();
  http.StreamedResponse response;
  try {
    response = await sendProviderRequest(
      sharedProviderHttpClient(),
      _request(url),
      cancelToken,
    );
  } on TimeoutException catch (e) {
    return CallOutcome('connect-watchdog', sw.elapsed, sw.elapsed, error: '$e');
  } catch (e) {
    return CallOutcome(
      'transport-error@send',
      sw.elapsed,
      sw.elapsed,
      error: '$e',
    );
  }
  final headersAt = sw.elapsed;
  final iterator = createSseIterator(
    response,
    cancelToken,
    idleTimeout: idleTimeout,
  );
  var events = 0;
  var sawDone = false;
  while (true) {
    try {
      if (!await iterator.moveNext()) {
        // A body that ends after the [DONE] sentinel is the healthy end
        // (adapters finish with DoneEvent); an end WITHOUT it is the
        // truncation class ("stream ended without finish_reason").
        return CallOutcome(
          sawDone ? 'ok' : 'stream-eof',
          headersAt,
          sw.elapsed,
          events: events,
        );
      }
      events++;
      if (iterator.current.data.trim() == '[DONE]') sawDone = true;
    } on TimeoutException catch (e) {
      return CallOutcome(
        'idle-watchdog',
        headersAt,
        sw.elapsed,
        events: events,
        error: '$e',
      );
    } catch (e) {
      return CallOutcome(
        'transport-error@body',
        headersAt,
        sw.elapsed,
        events: events,
        error: '$e',
      );
    }
  }
}

/// One server-observed request: the client's LOCAL port (connection
/// identity — a pooled keep-alive reuse shows the same port twice).
final class Served {
  Served(this.remotePort, this.at);
  final int remotePort;
  final DateTime at;
}

/// Loopback HTTP lab: records every request's connection port, lets each
/// test swap the handler, and reports server-side connection counts.
final class LabServer {
  LabServer._(this._server);

  final HttpServer _server;
  final List<Served> served = [];

  /// Swappable per scenario; errors are swallowed (a killed connection
  /// failing mid-response must not take the test isolate down).
  FutureOr<void> Function(HttpRequest request) handler = serveFull;

  Uri get url => Uri.parse('http://127.0.0.1:$_port/v1/chat/completions');
  int get _port => _server.port;

  static Future<LabServer> start({Duration? idleTimeout}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (idleTimeout != null) server.idleTimeout = idleTimeout;
    final lab = LabServer._(server);
    server.listen((request) {
      final port = request.connectionInfo?.remotePort ?? -1;
      lab.served.add(Served(port, DateTime.now()));
      unawaited(
        Future.sync(
          () => lab.handler(request),
        ).then((_) {}, onError: (Object _) {}),
      );
    }, onError: (Object _) {});
    return lab;
  }

  List<int> get ports => [for (final s in served) s.remotePort];
  Set<int> get distinctPorts => ports.toSet();

  /// Server-side connection total (active + idle + closing) right now.
  int get totalConnections => _server.connectionsInfo().total;

  String describeConnections() {
    final info = _server.connectionsInfo();
    return 'server connections: total=${info.total} active=${info.active} '
        'idle=${info.idle} closing=${info.closing}';
  }

  Future<void> shutdown() async => _server.close(force: true);
}

// ---- server behaviors (the four kill classes) ----

/// A complete, healthy SSE exchange: 2 data events, keep-alive maintained.
Future<void> serveFull(HttpRequest request) async {
  request.response.headers.contentType = ContentType.parse('text/event-stream');
  request.response.add('data: {"delta":"hello"}\n\n'.codeUnits);
  request.response.add('data: [DONE]\n\n'.codeUnits);
  await request.response.close();
}

/// Kill class 2 — the request arrived on a REUSED pooled conn; RST it
/// without answering. `detachSocket` MUST run before any header write
/// (dart:io throws "Headers already sent" afterwards).
Future<void> swallowAndKill(HttpRequest request) async {
  final socket = await request.response.detachSocket(writeHeaders: false);
  socket.destroy();
}

/// Kill class 3 — healthy socket, headers + one event delivered, then
/// silence forever. `bufferOutput = false` is REQUIRED: a buffered
/// response's `flush()` alone does not push the head to the client.
Future<void> serveFirstEventThenHold(HttpRequest request) async {
  request.response.bufferOutput = false;
  request.response.headers.contentType = ContentType.parse('text/event-stream');
  request.response.add('data: {"delta":"first"}\n\n'.codeUnits);
  await request.response.flush();
  await Completer<void>().future; // socket stays open, forever silent
}

/// Kill class 4 — honest EOF right after the first event: the body ends
/// cleanly with no [DONE] (truncated-stream class).
Future<void> serveFirstEventThenEof(HttpRequest request) async {
  request.response.bufferOutput = false;
  request.response.headers.contentType = ContentType.parse('text/event-stream');
  request.response.add('data: {"delta":"first"}\n\n'.codeUnits);
  await request.response.close();
}

/// Black hole: accept the request, never answer, keep the socket open
/// (the connect-watchdog scenario).
Future<void> swallowForever(HttpRequest request) async {
  await Completer<void>().future;
}

/// Error strings replayed into the classifier/ladder tests below. Seeded
/// with the two canonical stale-socket wordings — the send-phase RST class
/// A2/A3 pin live, and the mid-body cut class the rest of the suite pins —
/// so D1 always exercises the classifier even when the recording scenarios
/// are filtered out via `--plain-name`/`--name`; live captures only ADD to
/// it.
final List<String> observedStaleErrors = <String>[
  'ClientException: Connection closed before full header was received',
  'ClientException: Connection closed while receiving data',
];

final _reproModel = Model(
  id: 'repro-1392',
  name: 'repro-1392',
  api: 'openai-completions',
  provider: 'repro',
  baseUrl: 'http://127.0.0.1:1',
  contextWindow: 1000,
  maxTokens: 100,
);

/// One construction point for scenario D's [AssistantMessage] carriers:
/// [raw] feeds [AssistantMessage.errorMessage]; [ok] switches the stop
/// reason to [StopReason.stop] for the success-path cases.
AssistantMessage errorMessageOf(String? raw, {bool ok = false}) =>
    AssistantMessage(
      content: const [],
      api: _reproModel.api,
      provider: _reproModel.provider,
      model: _reproModel.id,
      usage: Usage.zero,
      stopReason: ok ? StopReason.stop : StopReason.error,
      errorMessage: raw,
      timestamp: DateTime.now(),
    );

void main() {
  final savedSleeper = transientRetrySleeper;
  final savedNotice = transientRetryNotice;
  final savedBackoff = providerConnectRetryBackoff;

  setUp(() {
    // Short watchdogs THROUGH THE EXISTING SEAM (config override surface,
    // provider_common.dart): every real failure class fires in < 2s while
    // the 5-min production default would never be distinguishable from a
    // hang inside a test budget.
    providerTimeoutsOverride = const ProviderTimeoutsOverride(
      connect: Duration(milliseconds: 1500),
      streamIdle: Duration(milliseconds: 1200),
    );
    providerConnectRetryBackoff = const Duration(milliseconds: 1);
    transientRetrySleeper = (delay, token) async => true;
    transientRetryNotice = null;
  });
  tearDown(() {
    providerTimeoutsOverride = null;
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
    providerConnectRetryBackoff = savedBackoff;
  });

  test('baseline: the shared keep-alive client REUSES one connection for '
      'sequential requests (pool works as designed)', () async {
    final lab = await LabServer.start();
    addTearDown(lab.shutdown);
    final o1 = await streamedCall(lab.url);
    final o2 = await streamedCall(lab.url);
    final o3 = await streamedCall(lab.url);
    // ignore: avoid_print
    print('baseline: $o1 | $o2 | $o3 ports=${lab.ports}');
    expect(o1.kind, 'ok');
    expect(o2.kind, 'ok');
    expect(o3.kind, 'ok');
    // The whole point of the shared client: ONE TCP conn for 3 requests.
    expect(lab.distinctPorts, hasLength(1));
    expect(lab.served, hasLength(3));
    expect(o3.total, lessThan(const Duration(milliseconds: 500)));
  });

  group(
    'scenario A — stale reuse after the server kills an idle keep-alive',
    () {
      test('A1. GRACEFUL idle-kill (server.idleTimeout): next request gets a '
          'FRESH connection in milliseconds — dart:io evicts FIN\'d sockets, '
          'no watchdog involved', () async {
        final lab = await LabServer.start(
          idleTimeout: const Duration(milliseconds: 120),
        );
        addTearDown(lab.shutdown);
        final o1 = await streamedCall(lab.url);
        expect(o1.kind, 'ok');
        final p1 = lab.ports.single;

        // Idle long enough for the server to FIN the keep-alive conn AND
        // for the client's event loop to process the close.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        final o2 = await streamedCall(lab.url);
        // ignore: avoid_print
        print('A1: $o2 ports=${lab.ports}');
        expect(o2.kind, 'ok', reason: 'clean pool eviction must not error');
        expect(lab.ports.last, isNot(p1), reason: 'must be a fresh socket');
        // The class proof: faster than the 1500ms connect watchdog could
        // ever fire — this failure mode cannot cost a watchdog window.
        expect(
          o2.total,
          lessThan(const Duration(milliseconds: 500)),
          reason: 'fresh-connect cost is milliseconds, not a watchdog window',
        );
      });

      test(
        'A2. KILL-ON-ARRIVAL (deterministic stale reuse): the pooled socket '
        'IS handed out again, the server RSTs it, and the client surfaces a '
        'transport error in milliseconds — never a watchdog window',
        () async {
          final lab = await LabServer.start();
          addTearDown(lab.shutdown);
          var n = 0;
          lab.handler = (request) async {
            n++;
            // First request: healthy, keep-alive. Second: it ARRIVES on the
            // reused pooled conn — kill it. Third+: healthy again.
            if (n == 2) return swallowAndKill(request);
            return serveFull(request);
          };

          final o1 = await streamedCall(lab.url);
          expect(o1.kind, 'ok');
          final p1 = lab.ports.single;

          final o2 = await streamedCall(lab.url);
          // ignore: avoid_print
          print('A2: $o2 ports=${lab.ports}');
          // The kill happens AFTER the request bytes arrived on the pooled
          // conn — the pool provably REUSED the stale socket...
          expect(lab.ports, [
            p1,
            p1,
          ], reason: 'request #2 must land on the reused pooled conn');
          expect(
            o2.kind,
            anyOf('transport-error@send', 'transport-error@body'),
            reason: 'an unanswered, RST\'d conn is a transport failure',
          );
          observedStaleErrors.add(o2.error ?? '(none)');
          // ...and the class proof: the failure is IMMEDIATE (milliseconds),
          // far under the 1500ms connect watchdog — dart:io does not sit on
          // a dead loopback socket.
          expect(
            o2.total,
            lessThan(const Duration(milliseconds: 1200)),
            reason:
                'stale reuse fails fast on a closed socket; it cannot '
                'wait out a watchdog window',
          );

          // The dead conn is evicted on error: the next call is fresh + ok.
          final o3 = await streamedCall(lab.url);
          expect(o3.kind, 'ok');
          expect(lab.ports.last, isNot(p1));
        },
      );

      test('A3. RAW layer (no watchdog of ours): the same stale-reuse failure '
          'surfaces from package:http as an immediate exception — the client '
          'library does NOT transparently retry, and does NOT hang', () async {
        final lab = await LabServer.start();
        addTearDown(lab.shutdown);
        var n = 0;
        lab.handler = (request) async {
          n++;
          if (n == 2) return swallowAndKill(request);
          return serveFull(request);
        };
        final r1 = await rawCall(lab.url);
        expect(r1.kind, 'ok');
        final r2 = await rawCall(lab.url);
        // ignore: avoid_print
        print(
          'A3 raw: ${r1.kind}/${r1.elapsed.inMilliseconds}ms then '
          '${r2.kind}/${r2.elapsed.inMilliseconds}ms '
          'error=${r2.error == null ? null : _oneLine(r2.error!)} '
          'ports=${lab.ports}',
        );
        expect(
          lab.ports,
          hasLength(2),
          reason: 'request #2 reused the pooled conn (same port twice)',
        );
        expect(lab.distinctPorts, hasLength(1));
        expect(
          r2.kind,
          isNot('HUNG-until-guard'),
          reason:
              'dart:http detects the dead pooled socket by itself — '
              'no watchdog needed on loopback',
        );
        expect(
          r2.kind,
          startsWith('error:'),
          reason: 'no transparent retry exists: the raw send FAILS',
        );
        if (r2.error != null) observedStaleErrors.add(r2.error!);
        expect(
          r2.elapsed,
          lessThan(const Duration(milliseconds: 1500)),
          reason: 'immediate detection, not even the raw 4s guard',
        );
      });
    },
  );

  group('scenario B — watchdog fire and retry freshness', () {
    test('B1. ALIVE-BUT-SILENT after the first event: OUR idle watchdog fires '
        'at the override, the cancelled conn is NOT pooled back, and the '
        'next call rides a FRESH connection', () async {
      final lab = await LabServer.start();
      addTearDown(lab.shutdown);
      lab.handler = (request) {
        lab.handler = serveFull; // every request after the first: healthy
        return serveFirstEventThenHold(request);
      };

      final o1 = await streamedCall(lab.url);
      // ignore: avoid_print
      print('B1: $o1 then ${lab.describeConnections()}');
      expect(
        o1.kind,
        'idle-watchdog',
        reason:
            'a healthy-but-silent stream is exactly the idle '
            'watchdog\'s case',
      );
      expect(
        o1.events,
        greaterThanOrEqualTo(1),
        reason: 'the first event arrived before the silence',
      );
      // The watchdog actually WAITED (that is its cost when it is the
      // only detector — ~the override, never more), then fired.
      expect(
        o1.total,
        allOf(
          greaterThanOrEqualTo(const Duration(milliseconds: 200)),
          lessThan(const Duration(milliseconds: 2000)),
        ),
        reason:
            'idle-watchdog cost == the streamIdle override (1200ms here), '
            'the quantization #1395 reproduced at the 5min production default',
      );
      final p1 = lab.ports.single;

      final o2 = await streamedCall(lab.url);
      // ignore: avoid_print
      print('B1 retry: $o2 ports=${lab.ports}');
      expect(o2.kind, 'ok');
      expect(
        lab.ports.last,
        isNot(p1),
        reason:
            'the idle-watchdog cancel must destroy (not re-pool) '
            'the silent conn',
      );
      expect(o2.total, lessThan(const Duration(milliseconds: 500)));
    });

    test(
      'B2. HONEST EOF mid-stream: an ended-without-[DONE] body is detected '
      'as an IMMEDIATE clean end — not a watchdog wait, not an error',
      () async {
        final lab = await LabServer.start();
        addTearDown(lab.shutdown);
        lab.handler = serveFirstEventThenEof;
        final o1 = await streamedCall(lab.url);
        // ignore: avoid_print
        print('B2: $o1');
        expect(
          o1.kind,
          'stream-eof',
          reason:
              'the body simply ends: the truncation class adapters '
              'surface as "stream ended without finish_reason"',
        );
        expect(o1.events, greaterThanOrEqualTo(1));
        // Class proof: instant (< the 1200ms idle override would be needed
        // only if EOF were invisible — it is not).
        expect(
          o1.total,
          lessThan(const Duration(milliseconds: 900)),
          reason: 'EOF is delivered by the socket immediately',
        );
      },
    );

    test(
      'B3. BLACK HOLE at connect (headers never arrive): the connect '
      'watchdog fires, the transparent retry lands on a FRESH connection '
      '(new server-side port) — and the abandoned socket stays open',
      () async {
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          connect: Duration(milliseconds: 150),
        );
        final lab = await LabServer.start();
        addTearDown(lab.shutdown);
        lab.handler = (request) {
          lab.handler = serveFull; // only the FIRST request is swallowed
          return swallowForever(request);
        };

        final o1 = await streamedCall(lab.url);
        // ignore: avoid_print
        print('B3: $o1 ports=${lab.ports} ${lab.describeConnections()}');
        expect(
          o1.kind,
          'ok',
          reason:
              'the connect-stall retry (provider_common.dart '
              'sendWatchedProviderRequest) recovers the call',
        );
        expect(
          lab.served,
          hasLength(2),
          reason: 'original + one transparent re-send',
        );
        expect(
          lab.distinctPorts,
          hasLength(2),
          reason:
              'THE #1392 assertion: the retry opened a FRESH conn — '
              'the dead request\'s socket was never pooled, so the '
              're-send cannot land on it',
        );
        // The watchdog fired once (its cost) and the retry succeeded
        // immediately after: total ≈ override + ε.
        expect(
          o1.total,
          allOf(
            greaterThanOrEqualTo(const Duration(milliseconds: 140)),
            lessThan(const Duration(milliseconds: 2000)),
          ),
        );
        // Leak observation (documented, not asserted): the abandoned
        // first conn is still open server-side — package:http cannot
        // cancel a pending send, and the janitor only fires if headers
        // eventually arrive. server.close(force:true) at teardown reaps it.
        // ignore: avoid_print
        print('B3 aftermath: ${lab.describeConnections()}');
      },
    );
  });

  group('scenario C — pool growth under repeated server-side kills', () {
    test('C1. N sequential requests with GRACEFUL idle kills between them: '
        'one fresh conn per request, pool never leaks dead sockets', () async {
      final lab = await LabServer.start(
        idleTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(lab.shutdown);
      const n = 5;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        final o = await streamedCall(lab.url);
        expect(o.kind, 'ok', reason: 'request #$i');
        expect(
          o.total,
          lessThan(const Duration(milliseconds: 600)),
          reason: 'request #$i must not approach a watchdog window',
        );
        // Give the server time to FIN the idle conn (the kill under
        // test) before the next request.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      // ignore: avoid_print
      print(
        'C1: ${lab.ports} ${lab.describeConnections()} '
        'total=${sw.elapsed.inMilliseconds}ms',
      );
      expect(lab.served, hasLength(n));
      expect(
        lab.distinctPorts,
        hasLength(n),
        reason:
            'every request paid one fresh connect — dead conns '
            'evicted, pool SHRINKS under graceful kills (no leak, no '
            'growth)',
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final info = lab.describeConnections();
      // ignore: avoid_print
      print('C1 after idle: $info');
      expect(
        lab.totalConnections,
        lessThan(2),
        reason: 'no lingering conns once the server FINs them',
      );
    });

    test('C2. CYCLING kill-on-arrival (worst case: every pooled reuse dies): '
        'every failure is an instant transport error — the pool keeps '
        'working and never sees a watchdog window', () async {
      final lab = await LabServer.start();
      addTearDown(lab.shutdown);
      lab.handler = (request) {
        // Kill the FIRST arrival (on its fresh conn) and then every
        // REUSE of the served conn: arrivals alternate kill/serve, so
        // every other logical request rides a pooled socket the server
        // destroys on arrival.
        return lab.served.length.isOdd
            ? swallowAndKill(request)
            : serveFull(request);
      };
      final sw = Stopwatch()..start();
      final kinds = <String>[];
      for (var i = 0; i < 6; i++) {
        final o = await streamedCall(lab.url);
        kinds.add(o.kind);
        expect(
          o.total,
          lessThan(const Duration(milliseconds: 800)),
          reason: 'call #$i (${o.kind}) must stay in the instant class',
        );
      }
      // ignore: avoid_print
      print(
        'C2: $kinds ports=${lab.ports} '
        'total=${sw.elapsed.inMilliseconds}ms '
        '${lab.describeConnections()}',
      );
      // Arrivals: kill(fresh#1) serve(fresh#2) kill(reuse#2) serve(#3)
      // kill(reuse#3) serve(#4) — 3 instant stale/fresh kills + 3 healthy.
      expect(kinds.where((k) => k == 'ok'), hasLength(3));
      expect(
        kinds.where((k) => k.startsWith('transport-error')),
        hasLength(3),
        reason:
            'every conn the server kills on arrival fails — '
            'instantly, which is why a 6-call burst stays < 2s',
      );
      expect(
        lab.distinctPorts,
        hasLength(4),
        reason:
            '3 healthy fresh conns + 1 killed fresh conn; the two '
            'killed REUSES ride conns already counted',
      );
    });
  });

  group('scenario D — retry-ladder interplay (the #1392 recovery path)', () {
    test('D1. every stale-socket error observed above classifies as a '
        'TRANSIENT network failure — the ladder replays them', () {
      for (final raw in observedStaleErrors) {
        final message = errorMessageOf(raw);
        // ignore: avoid_print
        print(
          'D1 classify: ${isTransientNetworkError(message)} '
          '<- ${_oneLine(raw)}',
        );
        expect(
          isTransientNetworkError(message),
          isTrue,
          reason: 'the ladder must replay this class: $_oneLine(raw)',
        );
      }
      // And the counter-case: the idle watchdog's own wording does NOT
      // classify (documented policy) — it fails over at the roles layer,
      // not the transient ladder.
      expect(
        isTransientNetworkError(
          errorMessageOf(
            'TimeoutException: no events from the endpoint for 300s '
            '(stream idle timeout)',
          ),
        ),
        isFalse,
      );
    });

    test('D2. END-TO-END: the transient ladder replays a real stale-socket '
        'failure and the replay rides a FRESH connection', () async {
      final lab = await LabServer.start();
      addTearDown(lab.shutdown);
      // Kill the FIRST arriving request (on its fresh conn); serve
      // everything after.
      lab.handler = (request) {
        lab.handler = serveFull;
        return swallowAndKill(request);
      };

      var attempts = 0;
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) {
          attempts++;
          final stream = AssistantMessageEventStream();
          unawaited(() async {
            final outcome = await streamedCall(lab.url);
            if (outcome.kind == 'ok') {
              stream.push(
                DoneEvent(
                  reason: StopReason.stop,
                  message: errorMessageOf(null, ok: true),
                ),
              );
            } else {
              stream.push(
                ErrorEvent(
                  reason: StopReason.error,
                  error: errorMessageOf(outcome.error),
                ),
              );
            }
            stream.end();
          }());
          return stream;
        },
        maxAttempts: 3,
        delay: Duration.zero,
      );

      final sw = Stopwatch()..start();
      final events = await wrapped(
        _reproModel,
        const Context(messages: []),
      ).toList();
      // ignore: avoid_print
      print(
        'D2: attempts=$attempts ports=${lab.ports} '
        'elapsed=${sw.elapsed.inMilliseconds}ms '
        'final=${events.last.runtimeType}',
      );

      expect(attempts, 2, reason: 'exactly one replay');
      expect(
        events.last,
        isA<DoneEvent>(),
        reason: 'the ladder recovered the call',
      );
      expect(lab.served, hasLength(2));
      expect(
        lab.distinctPorts,
        hasLength(2),
        reason:
            'the replay connected FRESH (the dead conn was '
            'evicted on error, not re-pooled)',
      );
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'no watchdog window anywhere in the recovery',
      );
    });
  });
}
