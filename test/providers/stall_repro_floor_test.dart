// The stall repro floor (gh-1395 AC1/AC2/AC5): loopback dart:io kill
// scenarios against the REAL production stack
// (`sharedProviderHttpClient` → `sendProviderRequest` →
// `createSseIterator`), asserting the TIMING CLASS of every scenario —
// the regression floor that keeps the pool exoneration and the new
// stall instrumentation true as dart:http evolves.
//
// Complementary to PR #1396's 11-test instrument (the evidence artifact
// this card consumes): this floor pins the classes the ACs name —
// FIN ≈ fresh-conn ms, alive-but-silent = idle-timeout ± ε, retry port ≠
// original — PLUS the AC2 trace-line order (in-process structured + a
// child-process stderr check) and the AC5 eviction-knob invariance.
//
// No external network; every server is loopback on an ephemeral port.
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/providers/conn_trace.dart';
import 'package:flutter_agent_harness/src/providers/conn_trace_io.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart';
import 'package:flutter_agent_harness/src/providers/stall_sentinel.dart'
    show maybeEvictProviderPool, poolEvictionOverride;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

http.Request _request(Uri url) => http.Request('POST', url)
  ..headers['content-type'] = 'application/json'
  ..body = '{"model":"floor-1395","stream":true}';

/// The loopback lab: records the client-side port of every request and a
/// swappable handler per scenario.
final class Lab {
  Lab._(this._server);
  final HttpServer _server;
  final ports = <int>[];

  FutureOr<void> Function(HttpRequest request) handler = _serveFull;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/v1/chat');

  static Future<Lab> start({Duration? idleTimeout}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (idleTimeout != null) server.idleTimeout = idleTimeout;
    final lab = Lab._(server);
    server.listen((request) {
      lab.ports.add(request.connectionInfo?.remotePort ?? -1);
      unawaited(
        Future.sync(
          () => lab.handler(request),
        ).then((_) {}, onError: (Object _) {}),
      );
    }, onError: (Object _) {});
    return lab;
  }

  Future<void> shutdown() => _server.close(force: true);

  /// Kill class: healthy SSE exchange (2 events + [DONE]), keep-alive.
  static Future<void> _serveFull(HttpRequest request) async {
    request.response.headers.contentType = ContentType.parse(
      'text/event-stream',
    );
    request.response.add(utf8.encode('data: {"delta":"hello"}\n\n'));
    request.response.add(utf8.encode('data: [DONE]\n\n'));
    await request.response.close();
  }

  /// Kill class: headers + first event, then alive-but-silent forever.
  static Future<void> serveFirstEventThenHold(HttpRequest request) async {
    request.response.bufferOutput = false;
    request.response.headers.contentType = ContentType.parse(
      'text/event-stream',
    );
    request.response.add(utf8.encode('data: {"delta":"first"}\n\n'));
    await request.response.flush();
    await Completer<void>().future;
  }

  /// Kill class: accept, never answer (the connect-watchdog black hole).
  static Future<void> swallowForever(HttpRequest request) async {
    await Completer<void>().future;
  }
}

/// One streamed call through the production stack.
Future<({String kind, Duration total, String? error, int events})> streamedCall(
  Uri url, {
  Duration? idleTimeout,
}) async {
  final sw = Stopwatch()..start();
  http.StreamedResponse response;
  try {
    response = await sendProviderRequest(
      sharedProviderHttpClient(),
      _request(url),
      null,
    );
  } on TimeoutException catch (e) {
    return (
      kind: 'connect-watchdog',
      total: sw.elapsed,
      error: '$e',
      events: 0,
    );
  } catch (e) {
    return (kind: 'transport-error', total: sw.elapsed, error: '$e', events: 0);
  }
  final iterator = createSseIterator(response, null, idleTimeout: idleTimeout);
  var events = 0;
  var sawDone = false;
  while (true) {
    try {
      if (!await iterator.moveNext()) {
        return (
          kind: sawDone ? 'ok' : 'stream-eof',
          total: sw.elapsed,
          error: null,
          events: events,
        );
      }
      events++;
      if (iterator.current.data.trim() == '[DONE]') sawDone = true;
    } on TimeoutException catch (e) {
      return (
        kind: 'idle-watchdog',
        total: sw.elapsed,
        error: '$e',
        events: events,
      );
    } catch (e) {
      return (
        kind: 'transport-error',
        total: sw.elapsed,
        error: '$e',
        events: events,
      );
    }
  }
}

void main() {
  setUp(() {
    providerTimeoutsOverride = const ProviderTimeoutsOverride(
      connect: Duration(milliseconds: 800),
      streamIdle: Duration(milliseconds: 400),
    );
    providerConnectRetryBackoff = const Duration(milliseconds: 1);
  });
  tearDown(() {
    providerTimeoutsOverride = null;
  });

  group('AC1 — timing classes (the pool exoneration floor)', () {
    test(
      'baseline: the shared keep-alive client reuses ONE connection',
      () async {
        final lab = await Lab.start();
        addTearDown(lab.shutdown);
        for (var i = 0; i < 3; i++) {
          final o = await streamedCall(lab.url);
          expect(o.kind, 'ok', reason: 'call #$i');
          expect(o.total, lessThan(const Duration(milliseconds: 700)));
        }
        expect(
          lab.ports.toSet(),
          hasLength(1),
          reason: 'one TCP connection served all three',
        );
      },
    );

    test('stale FIN (server idle-kill): fresh connection in milliseconds — '
        'no watchdog window anywhere', () async {
      final lab = await Lab.start(
        idleTimeout: const Duration(milliseconds: 80),
      );
      addTearDown(lab.shutdown);
      final o1 = await streamedCall(lab.url);
      expect(o1.kind, 'ok');
      final p1 = lab.ports.single;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final o2 = await streamedCall(lab.url);
      expect(o2.kind, 'ok', reason: 'graceful eviction is invisible');
      expect(lab.ports.last, isNot(p1), reason: 'fresh socket after the FIN');
      expect(
        o2.total,
        lessThan(const Duration(milliseconds: 600)),
        reason: 'FIN ≈ fresh-conn ms — never a watchdog window (AC1)',
      );
    });

    test('alive-but-silent: the idle watchdog fires AT the override (± ε) — '
        'the bench quantization signature', () async {
      final lab = await Lab.start();
      addTearDown(lab.shutdown);
      lab.handler = Lab.serveFirstEventThenHold;
      final o = await streamedCall(lab.url);
      expect(o.kind, 'idle-watchdog');
      expect(
        o.events,
        greaterThanOrEqualTo(1),
        reason: 'the first event arrived before the silence',
      );
      expect(
        o.total.inMilliseconds,
        allOf(greaterThanOrEqualTo(350), lessThan(1400)),
        reason:
            'idle override is 400ms — the failure quantizes to it '
            '(AC1: alive-but-silent = idle-timeout ± ε)',
      );
    });

    test(
      'connect black hole: the transparent retry lands on a FRESH port',
      () async {
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          connect: Duration(milliseconds: 150),
        );
        final lab = await Lab.start();
        addTearDown(lab.shutdown);
        lab.handler = (request) {
          lab.handler = Lab._serveFull; // only the first request black-holes
          return Lab.swallowForever(request);
        };
        final o = await streamedCall(lab.url);
        expect(
          o.kind,
          'ok',
          reason: 'the connect-stall retry recovers the call',
        );
        expect(
          lab.ports.toSet(),
          hasLength(2),
          reason: 'AC1: the retry port ≠ the original (fresh connection)',
        );
        expect(o.total, lessThan(const Duration(milliseconds: 1200)));
      },
    );
  });

  group('AC2 — FA_CONN_DEBUG trace order', () {
    test('structured events in order: conn open (fresh) → first byte → '
        'idle watchdog FIRED (conn age, port)', () async {
      installProviderStallForensics(); // the io seams: observed client + stderr
      connTraceOverride = true;
      resetConnTraceForTest(); // fresh board
      resetSharedProviderHttpClient(); // rebuild the singleton WITH tracing
      addTearDown(() {
        connTraceOverride = null;
        resetConnTraceForTest();
        resetSharedProviderHttpClient();
      });
      final events = <ConnTraceEvent>[];
      connTraceSink = events.add;
      addTearDown(() => connTraceSink = null);

      final lab = await Lab.start();
      addTearDown(lab.shutdown);
      lab.handler = Lab.serveFirstEventThenHold;

      final o = await streamedCall(lab.url);
      expect(o.kind, 'idle-watchdog');
      await pumpEventQueue();

      expect(events.map((e) => e.kind).toList(), [
        ConnTraceKind.connOpen,
        ConnTraceKind.firstByte,
        ConnTraceKind.idleWatchdogFired,
        ConnTraceKind.stallDumped,
      ], reason: 'the pinned AC2 order');
      expect(events[0].line, startsWith('conn open (fresh, port '));
      expect(events[1].line, startsWith('first byte after '));
      expect(events[2].line, startsWith('idle watchdog FIRED after '));
      expect(events[2].line, contains('conn age '));
      expect(events[2].line, contains('port '));
      expect(
        events[2].port,
        lab.ports.single,
        reason: 'the watchdog line names the silent connection',
      );
    });

    test('child-process stderr carries the same lines in the same order '
        '(the stderr half of AC2)', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/providers/conn_trace_stderr_e2e.dart'],
        environment: {'FA_CONN_DEBUG': '1'},
      );
      // ignore: avoid_print
      print('stderr e2e exit=${result.exitCode}\n${result.stderr}');
      final lines = (result.stderr as String)
          .split('\n')
          .where((l) => l.contains('[conn-trace]'))
          .toList();
      expect(lines.length, greaterThanOrEqualTo(3));
      expect(lines[0], contains('conn open (fresh, port '));
      expect(lines[1], contains('first byte after '));
      expect(lines[2], contains('idle watchdog FIRED after '));
      expect(lines[2], contains('conn age '));
      expect(lines[2], contains('port '));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('AC5 — the pool-eviction hygiene knob', () {
    test('flag on: the eviction resets the shared client and logs; the '
        'repro classes are UNCHANGED (hygiene, not correctness)', () async {
      poolEvictionOverride = true;
      resetConnTraceForTest();
      resetSharedProviderHttpClient();
      final events = <ConnTraceEvent>[];
      connTraceSink = events.add;
      addTearDown(() {
        poolEvictionOverride = null;
        connTraceSink = null;
      });

      final oldClient = sharedProviderHttpClient();
      maybeEvictProviderPool(
        reason: 'idle stall',
        reset: resetSharedProviderHttpClient,
      );
      final newClient = sharedProviderHttpClient();
      expect(
        identical(oldClient, newClient),
        isFalse,
        reason: 'the knob actually resets the pool',
      );
      expect(events.map((e) => e.kind), contains(ConnTraceKind.poolEvicted));
      expect(
        events.lastWhere((e) => e.kind == ConnTraceKind.poolEvicted).line,
        'pool evicted (idle stall)',
      );

      // The floor scenarios behave identically with the knob enabled.
      final lab = await Lab.start();
      addTearDown(lab.shutdown);
      lab.handler = Lab.serveFirstEventThenHold;
      final stall = await streamedCall(lab.url);
      expect(stall.kind, 'idle-watchdog');
      lab.handler = Lab._serveFull;
      final healthy = await streamedCall(lab.url);
      expect(healthy.kind, 'ok');
      expect(healthy.total, lessThan(const Duration(milliseconds: 700)));
      expect(lab.ports.toSet().length, greaterThanOrEqualTo(1));
    });
  });
}
