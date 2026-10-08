// Bench ConnTrace tests (issue #1392 bench round 3, AC2/AC9) — the
// structured FA_CONN forensics; the gh-1395 seam/wrap tests live in
// conn_trace_test.dart.
//
// The wire contract: every provider HTTP lifecycle event becomes one
// `FA_CONN {json}` line — on stderr (via [ConnTrace.emitSink] here) and in
// `FA_CONN_TRACE_FILE` — so a bench stall is diagnosable from the live run
// log. AC9's discrimination sequence (first byte -> idle-watchdog -> retry,
// plus the stale keep-alive socket line) runs against REAL loopback
// servers: fakes reify plain http.StreamedResponse and can never exercise
// the dart:io connectionInfo the traced client reports.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/providers/conn_trace_bench_io.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

List<Map<String, Object?>> _events(List<String> lines) => lines
    .where((line) => line.startsWith('FA_CONN '))
    .map(
      (line) => Map<String, Object?>.from(
        jsonDecode(line.substring('FA_CONN '.length)) as Map,
      ),
    )
    .toList();

http.Request _post(String url) => http.Request('POST', Uri.parse(url))
  ..headers['content-type'] = 'application/json'
  ..headers['authorization'] = 'Bearer sk-test'
  ..body = '{"model":"m","stream":true}';

/// A keep-alive HTTP server that answers every request with a
/// content-length response (the shape dart:io pools the socket for).
Future<HttpServer> _keepAliveServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.set('content-type', 'text/event-stream');
    request.response.add(utf8.encode('data: {"ok":true}\n\n'));
    await request.response.close();
  });
  return server;
}

void main() {
  final savedShared = providerHttpClientFactory;
  tearDownAll(() => providerHttpClientFactory = savedShared);

  group('ConnTrace line contract (UT)', () {
    test('every event renders as one FA_CONN json line', () {
      final lines = <String>[];
      connTrace.resetForTest();
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.enable();

      connTrace.requestStart(
        seq: 1,
        method: 'POST',
        url: 'https://x/y',
        fresh: null,
      );
      connTrace.firstByte(
        seq: 1,
        wallSec: 213.0,
        fresh: true,
        localPort: 54321,
        poolSize: 2,
        connAgeSec: 912.0,
      );
      connTrace.idleWatchdogFired(
        idleSec: 300.0,
        connAgeSec: 912.0,
        localPort: 54321,
      );
      connTrace.retryScheduled(
        attempt: 1,
        delaySec: 2.0,
        reason: 'connect stall',
      );

      final events = _events(lines);
      expect(events, hasLength(4));
      expect(events[0]['event'], 'request_start');
      expect(events[0]['fresh'], isNull);
      expect(events[1]['event'], 'first_byte');
      expect(events[1]['slow'], isTrue, reason: '213s > the 120s slow flag');
      expect(events[1]['wallSec'], 213.0);
      expect(events[1]['fresh'], isTrue);
      expect(events[1]['localPort'], 54321);
      expect(events[2]['event'], 'idle_watchdog_fired');
      expect(events[2]['idleSec'], 300.0);
      expect(events[2]['connAgeSec'], 912.0);
      expect(events[2]['localPort'], 54321);
      expect(events[3]['event'], 'retry');
      expect(events[3]['attempt'], 1);
    });

    test('first byte under 120s is not flagged slow', () {
      final lines = <String>[];
      connTrace.resetForTest();
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.enable();
      connTrace.firstByte(seq: 1, wallSec: 0.4, fresh: false);
      expect(_events(lines).single['slow'], isFalse);
    });

    test('disabled instance emits nothing', () {
      final lines = <String>[];
      connTrace.resetForTest();
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.firstByte(seq: 1, wallSec: 900.0, fresh: true);
      expect(lines, isEmpty);
      expect(connTrace.enabled, isFalse);
    });
  });

  group('ConnTrace payload snapshot (AC3 input)', () {
    test('writes the outbound payload with Authorization redacted', () async {
      connTrace.resetForTest();
      connTrace.emitSink = (_) {};
      addTearDown(connTrace.resetForTest);
      connTrace.enable();
      final dir = await Directory.systemTemp.createTemp('fa-conn-test');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/snapshot.json';
      connTrace.payloadSnapshotPath = path;
      connTrace.keepAuthInSnapshots = false;

      connTrace.payloadSnapshot(
        method: 'POST',
        url: 'https://api.z.ai/v1/chat/completions',
        headers: {
          'authorization': 'Bearer sk-secret',
          'content-type': 'application/json',
        },
        body: '{"model":"m"}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final payload = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(payload['method'], 'POST');
      expect(payload['headers']['authorization'], '**redacted**');
      expect(payload['headers']['content-type'], 'application/json');
      expect(payload['body'], '{"model":"m"}');
    });
  });

  group('TracedProviderClient (real loopback)', () {
    test('first request fresh, second reused on the same local port', () async {
      connTrace.resetForTest();
      final lines = <String>[];
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.enable();

      final server = await _keepAliveServer();
      addTearDown(server.close);
      final client = connTrace.tracedClient()!;
      final url = 'http://127.0.0.1:${server.port}/v1/chat';

      for (var i = 0; i < 2; i++) {
        final response = await client.send(_post(url));
        await response.stream.drain<void>();
      }
      final events = _events(lines);
      final first = events.firstWhere((e) => e['event'] == 'first_byte');
      final second = events.where((e) => e['event'] == 'first_byte').last;
      expect(first['fresh'], isTrue, reason: 'a brand-new connection');
      expect(second['fresh'], isFalse, reason: 'keep-alive reuse');
      expect(second['localPort'], first['localPort']);
      expect(first['poolSize'], 1);
      expect(second['connAgeSec'], isNotNull);
      // The events also landed through the sink in order.
      expect(events.map((e) => e['event']).toList(), [
        'request_start',
        'first_byte',
        'request_done',
        'request_start',
        'first_byte',
        'request_done',
      ]);
    });

    test(
      'AC9 sequence: first_byte, then idle watchdog, then retry, in order',
      () async {
        connTrace.resetForTest();
        final lines = <String>[];
        connTrace.emitSink = lines.add;
        addTearDown(connTrace.resetForTest);
        connTrace.enable();
        final savedOverride = providerTimeoutsOverride;
        addTearDown(() => providerTimeoutsOverride = savedOverride);
        providerTimeoutsOverride = const ProviderTimeoutsOverride(
          streamIdle: Duration(milliseconds: 120),
          connect: Duration(milliseconds: 150),
        );
        final savedBackoff = providerConnectRetryBackoff;
        addTearDown(() => providerConnectRetryBackoff = savedBackoff);
        providerConnectRetryBackoff = const Duration(milliseconds: 1);

        // Leg A: headers arrive, then the endpoint goes silent mid-stream —
        // the class-B signature. The idle watchdog must NAME the idle span
        // and the current connection.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final sub = server.listen((request) async {
          request.response.headers.set('content-type', 'text/event-stream');
          request.response.add(utf8.encode(': hello\n\n'));
          await request.response.flush();
          // ...then never another byte.
        });
        addTearDown(sub.cancel);
        final client = connTrace.tracedClient()!;
        final response = await client.send(
          _post('http://127.0.0.1:${server.port}/v1'),
        );
        final iterator = createSseIterator(response, null);
        await expectLater(
          iterator.moveNext(),
          throwsA(isA<TimeoutException>()),
        );
        await iterator.cancel();

        // Leg B: a black hole (accepted, never answered) drives the connect
        // watchdog and its bounded transparent retry.
        final blackHole = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final blackHoleSub = blackHole.listen((_) {});
        addTearDown(blackHole.close);
        addTearDown(blackHoleSub.cancel);
        try {
          await sendWatchedProviderRequest(
            client,
            _post('http://127.0.0.1:${blackHole.port}/v1'),
            null,
          );
          fail('expected the connect watchdog TimeoutException');
        } on TimeoutException {
          // the contract of record (issue #1121)
        }

        final events = _events(lines);
        final order = events.map((e) => e['event']).toList();
        final firstByte = order.indexOf('first_byte');
        final idle = order.indexOf('idle_watchdog_fired');
        final retry = order.indexOf('retry');
        expect(firstByte, greaterThanOrEqualTo(0));
        expect(idle, greaterThan(firstByte));
        expect(retry, greaterThan(idle));
        // The mid-stream replay layer (TransientRetryStream) may transparently
        // re-issue the stalled request — producing a second idle fire before
        // the error surfaces. That watchdog-retry cycle is EXACTLY the
        // mechanism the card wants made visible; assert on every fire.
        final idleEvents = events
            .where((e) => e['event'] == 'idle_watchdog_fired')
            .toList(growable: false);
        expect(idleEvents, isNotEmpty);
        for (final idleEvent in idleEvents) {
          expect(idleEvent['idleSec'], 0.12);
          expect(
            idleEvent['localPort'],
            isNotNull,
            reason: 'the connection carrying the response is named',
          );
          expect(idleEvent['connAgeSec'], isNotNull);
        }
        final retryEvents = events.where((e) => e['event'] == 'retry').toList();
        expect(retryEvents, isNotEmpty);
        expect(retryEvents.first['attempt'], greaterThanOrEqualTo(1));
        expect(
          events.any((e) => e['event'] == 'connect_watchdog_fired'),
          isTrue,
        );
      },
    );

    test('AC9b: a send-phase failure on a REUSED same-origin socket emits '
        'stale_socket naming + evicting it', () async {
      connTrace.resetForTest();
      final lines = <String>[];
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.enable();

      // Request 1 seeds the pool map with a real keep-alive socket.
      final server = await _keepAliveServer();
      addTearDown(server.close);
      final client = connTrace.tracedClient()!;
      final good = Uri.parse('http://127.0.0.1:${server.port}/v1');
      final r1 = await client.send(_post(good.toString()));
      await r1.stream.drain<void>();
      final port1 =
          (_events(
                lines,
              ).where((e) => e['event'] == 'first_byte').single)['localPort']
              as int;
      expect(port1, isNotNull);

      // The silent keep-alive close dies on the NEXT request that reuses
      // the socket (issue #1392 AC9): same origin + send phase => the
      // pooled socket is named (local port + age) and evicted. Driven via
      // the decision hook — a real server that RSTs mid-reuse races
      // dart:io's transparent reconnect and cannot be pinned
      // deterministically.
      (client as TracedProviderClient).blameSendFailureForTest(
        good,
        'Connection closed while sending',
      );
      final stale = _events(
        lines,
      ).where((e) => e['event'] == 'stale_socket').toList();
      expect(stale, hasLength(1));
      expect(stale.single['localPort'], port1);
      expect(stale.single['ageSec'], isNotNull);
      // Evicted: the pool snapshot must stop counting the dead socket.
      expect(client.poolSizeForTest, 0);
    });

    test('AC9b hardening: a fresh-connect refusal is connect_failed, '
        'never a stale_socket — the pool is left alone', () async {
      connTrace.resetForTest();
      final lines = <String>[];
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.enable();

      // Seed the pool with a healthy socket, then fail a fresh connect to
      // a DIFFERENT origin (a freshly-closed port) — exactly the
      // misattribution case: the old code named the healthy pooled socket
      // as stale and evicted it.
      final server = await _keepAliveServer();
      addTearDown(server.close);
      final client = connTrace.tracedClient()!;
      final r1 = await client.send(_post('http://127.0.0.1:${server.port}/v1'));
      await r1.stream.drain<void>();
      final port1 =
          (_events(
                lines,
              ).where((e) => e['event'] == 'first_byte').single)['localPort']
              as int;

      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      await expectLater(
        client.send(_post('http://127.0.0.1:$deadPort/v1')),
        throwsA(isA<http.ClientException>()),
      );
      final kinds = _events(lines).map((e) => e['event']).toList();
      expect(
        kinds,
        contains('connect_failed'),
        reason: 'a refused fresh connect is a connect failure',
      );
      expect(
        kinds,
        isNot(contains('stale_socket')),
        reason: 'a fresh connect never touched the pooled socket',
      );
      // The healthy pooled socket survives the misattribution fix.
      final ok = await client.send(_post('http://127.0.0.1:${server.port}/v1'));
      await ok.stream.drain<void>();
      final reused =
          (_events(lines).where((e) => e['event'] == 'first_byte').last) as Map;
      expect(
        reused['fresh'],
        isFalse,
        reason: 'the pooled socket was NOT evicted',
      );
      expect(reused['localPort'], port1);
    });

    test('AC9b: same-origin endpoint-down after a pooled reuse emits '
        'stale_socket — dart:io dials lazily, so the pooled socket is '
        'what died', () async {
      connTrace.resetForTest();
      final lines = <String>[];
      connTrace.emitSink = lines.add;
      addTearDown(connTrace.resetForTest);
      connTrace.enable();

      // Closed in-body (no addTearDown): the second close would throw.
      final server = await _keepAliveServer();
      final port = server.port;
      final client = connTrace.tracedClient()!;
      final r1 = await client.send(_post('http://127.0.0.1:$port/v1'));
      await r1.stream.drain<void>();
      await server.close();

      await expectLater(
        client.send(_post('http://127.0.0.1:$port/v1')),
        throwsA(isA<http.ClientException>()),
      );
      // HttpClient.openUrl is lazy: the request writes into the POOLED
      // socket, which the server just closed — the textbook silent
      // keep-alive close, correctly named and evicted (same origin).
      final stale = _events(
        lines,
      ).where((e) => e['event'] == 'stale_socket').toList();
      expect(stale, hasLength(1));
      expect(stale.single['localPort'], isNotNull);
    });

    test('blame hook: a cross-origin send-phase failure never evicts the '
        'pooled socket', () {
      connTrace.resetForTest();
      addTearDown(connTrace.resetForTest);
      connTrace.enable();
      final client = connTrace.tracedClient()! as TracedProviderClient;
      client.blameSendFailureForTest(
        Uri.parse('http://127.0.0.1:1/v1'),
        'boom',
      );
      expect(client.poolSizeForTest, 0);
    });
  });

  group('sharedProviderHttpClient under tracing', () {
    test(
      'tracing on yields the traced client from the shared accessor',
      () async {
        connTrace.resetForTest();
        connTrace.emitSink = (_) {};
        addTearDown(() {
          connTrace.resetForTest();
          debugResetSharedProviderHttpClient();
        });
        connTrace.enable();
        providerHttpClientFactory = null;
        final client = sharedProviderHttpClient();
        expect(client, isA<TracedProviderClient>());
        // The default path (tracing off) keeps the plain client.
        connTrace.resetForTest();
        debugResetSharedProviderHttpClient();
        providerHttpClientFactory = null;
        final plain = sharedProviderHttpClient();
        expect(plain, isNot(isA<TracedProviderClient>()));
      },
    );
  });
}
