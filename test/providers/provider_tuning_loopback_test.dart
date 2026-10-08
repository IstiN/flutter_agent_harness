// Issue #1398 — the tuning knobs against a REAL loopback endpoint (the
// #1396 harness pattern): per-provider stream-idle + connect watchdogs
// resolve per request URL through the production seams
// (`sendProviderRequest` / `createSseIterator`), and the dual retry
// budgets separate connection-class from stream-class spend.
//
// No external network; servers bind 127.0.0.1 on ephemeral ports.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Answers the request with SSE HEADERS plus one COMMENT line, then holds
/// the connection open silently forever (the alive-but-silent class). The
/// comment pushes the head (`bufferOutput = false` + a bare `flush()` does
/// NOT push it — dart:io semantics, see the #1396 harness findings); the
/// SSE decoder drops comments, so the EVENT stream stays silent — exactly
/// what the event-level idle watchdog measures.
Future<HttpServer> _bindSilentAfterHeaders() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.listen((HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.headers.set('cache-control', 'no-cache');
      request.response.write(': ping\n\n');
      await request.response.flush();
      await Completer<void>().future; // hold: never another EVENT
    }).asFuture<void>(),
  );
  return server;
}

/// Accepts the TCP connection and NEVER answers headers (connect black
/// hole).
Future<HttpServer> _bindBlackHole() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(
    server.listen((HttpRequest request) async {
      await Completer<void>().future; // hold: no headers ever
    }).asFuture<void>(),
  );
  return server;
}

http.Request _post(Uri url) => http.Request('POST', url)
  ..headers['content-type'] = 'application/json'
  ..headers['authorization'] = 'Bearer sk-tuning-1398'
  ..body = '{"model":"tuning-1398","stream":true}';

void main() {
  group('AC1/IT — per-provider stream-idle watchdog on the wire', () {
    test(
      'registered entry fires at ~1.5s; unregistered host stays default',
      () async {
        providerTuningRegistry.clear();
        providerTimeoutsOverride = null;
        addTearDown(providerTuningRegistry.clear);
        final silent = await _bindSilentAfterHeaders();
        addTearDown(silent.close);
        providerTuningRegistry.register(
          name: 'glm-relay',
          baseUrl: 'http://127.0.0.1:${silent.port}',
          streamIdle: const Duration(milliseconds: 1500),
        );

        final url = Uri.parse('http://127.0.0.1:${silent.port}/v1/chat');
        final response = await sendProviderRequest(
          sharedProviderHttpClient(),
          _post(url),
          null,
        );
        expect(response.statusCode, 200);
        final iterator = createSseIterator(response, null);
        final sw = Stopwatch()..start();
        // The moveNext THROWS the idle TimeoutException — the awaited future
        // carries the error (a guard timeout catches a never-firing watchdog).
        await expectLater(
          iterator.moveNext().timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError('idle watchdog never fired'),
          ),
          throwsA(isA<TimeoutException>()),
        );
        final elapsed = sw.elapsed;
        expect(
          elapsed,
          greaterThan(const Duration(milliseconds: 1200)),
          reason: 'fired too early: $elapsed',
        );
        expect(
          elapsed,
          lessThan(const Duration(seconds: 4)),
          reason: 'fired too late (the 300s default leaked?): $elapsed',
        );

        // The second provider on the same run (no entry) resolves to the
        // default — asserted on the resolution seam, never by waiting 300s.
        expect(
          providerStreamIdleTimeoutForUrl(
            Uri.parse('http://127.0.0.1:1/v1/chat'),
          ),
          providerStreamIdleTimeout,
        );
        expect(
          providerStreamIdleTimeoutForUrl(url),
          const Duration(milliseconds: 1500),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('AC1/IT — per-provider connect watchdog on the wire', () {
    test(
      'entry budget kills the black hole early; default stays 180s',
      () async {
        providerTuningRegistry.clear();
        providerTimeoutsOverride = null;
        addTearDown(providerTuningRegistry.clear);
        final hole = await _bindBlackHole();
        addTearDown(hole.close);
        providerTuningRegistry.register(
          name: 'black-hole-relay',
          baseUrl: 'http://127.0.0.1:${hole.port}',
          connect: const Duration(milliseconds: 400),
        );

        final sw = Stopwatch()..start();
        await expectLater(
          sendProviderRequest(
            sharedProviderHttpClient(),
            _post(Uri.parse('http://127.0.0.1:${hole.port}/v1/chat')),
            null,
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => '$e',
              'message',
              contains('connect watchdog'),
            ),
          ),
        );
        final elapsed = sw.elapsed;
        expect(elapsed, greaterThan(const Duration(milliseconds: 300)));
        // The entry budget applies PER ATTEMPT and the in-place connect-stall
        // retry runs providerConnectRetries + 1 of them (3 × 0.4s + 1s + 2s
        // backoff ≈ 4.2s) — the point is the 180s default did NOT leak.
        expect(
          elapsed,
          lessThan(const Duration(seconds: 8)),
          reason: 'the 180s default leaked into the entry URL: $elapsed',
        );
        // The seam helpers agree; the unregistered URL keeps the default.
        expect(
          providerConnectTimeoutForUrl(
            Uri.parse('http://127.0.0.1:${hole.port}/v1/chat'),
          ),
          const Duration(milliseconds: 400),
        );
        expect(
          providerConnectTimeoutForUrl(Uri.parse('http://127.0.0.1:1/v1/chat')),
          effectiveProviderConnectTimeout,
        );
      },
    );
  });

  group('AC3/IT — dual budgets over loopback failure classes', () {
    test('connect-class kills spend connectionRetries only; the idle-class '
        'stall still draws the full stream budget', () async {
      providerTuningRegistry.clear();
      providerTimeoutsOverride = null;
      addTearDown(providerTuningRegistry.clear);
      // A CLOSED loopback port: every connect is refused instantly (the
      // connect-class kill — zero response bytes) without paying watchdog
      // waits; the watchdog-level classification lives in the connect IT.
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();
      final silent = await _bindSilentAfterHeaders();
      addTearDown(silent.close);
      providerTuningRegistry.register(
        name: 'silent',
        baseUrl: 'http://127.0.0.1:${silent.port}',
        streamIdle: const Duration(milliseconds: 300),
      );
      final ledger = RetryBudgetLedger();

      // Five consecutive connect-class kills: the first four draw the
      // connection budget, the fifth is REFUSED (budget exhausted).
      final classifications = <bool>[];
      for (var attempt = 0; attempt < 5; attempt++) {
        await expectLater(
          sendProviderRequest(
            sharedProviderHttpClient(),
            _post(Uri.parse('http://127.0.0.1:$deadPort/v1/chat')),
            null,
          ),
          throwsA(isA<Exception>()),
        );
        // The kill carried ZERO response bytes → connection-class.
        classifications.add(ledger.tryConsume(RetryBudgetClass.connection));
      }
      expect(classifications, [true, true, true, true, false]);
      expect(ledger.used(RetryBudgetClass.stream), 0);

      // The subsequent idle-class stall draws from the untouched stream
      // budget — the connection storm never ate it.
      final response = await sendProviderRequest(
        sharedProviderHttpClient(),
        _post(Uri.parse('http://127.0.0.1:${silent.port}/v1/chat')),
        null,
      );
      final iterator = createSseIterator(response, null);
      await expectLater(iterator.moveNext(), throwsA(isA<TimeoutException>()));
      expect(ledger.tryConsume(RetryBudgetClass.stream), isTrue);
      expect(ledger.used(RetryBudgetClass.connection), 4);
      expect(ledger.used(RetryBudgetClass.stream), 1);
      // E5: the terminal story carries both counters.
      expect(ledger.terminalStory(), contains('connection 4/4'));
      expect(ledger.terminalStory(), contains('stream 1/3'));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('AC6/REG — empty registry keeps byte-identical defaults', () {
    test(
      'resolution falls straight through to the untouched getters',
      () async {
        providerTuningRegistry.clear();
        providerTimeoutsOverride = null;
        addTearDown(providerTuningRegistry.clear);
        final url = Uri.parse('http://127.0.0.1:1/v1/chat');
        expect(
          providerConnectTimeoutForUrl(url),
          effectiveProviderConnectTimeout,
        );
        expect(
          providerStreamIdleTimeoutForUrl(url),
          effectiveProviderStreamIdleTimeout,
        );
        final resolved = resolveProviderTimeouts(url: url);
        expect(resolved.connect, providerConnectTimeout);
        expect(resolved.streamIdle, providerStreamIdleTimeout);
        expect(resolved.connectSourceLabel, 'default');
        expect(resolved.streamIdleSourceLabel, 'default');
      },
    );
  });
}
