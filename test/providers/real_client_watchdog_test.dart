// Regression for the CI core-shard red (run 36802277315, @db759aa): with a
// REAL IOClient the send future's runtime type parameter is package:http's
// internal IOStreamedResponse, and `.timeout` runtime-checks a
// value-returning onTimeout closure against that reified type — the connect
// watchdog died with "_TypeError: type '() => StreamedResponse' is not a
// subtype of type '(() => FutureOr<IOStreamedResponse>)?' of 'onTimeout'"
// before a single retry could happen. Fake BaseClients reify plain
// http.StreamedResponse and can never expose the mismatch, so this file
// talks to a real loopback black hole. Issue #1121 (retry surface).
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:test/test.dart';

/// A sent `http.Request` cannot be re-sent (production re-issues clones —
/// see `_reissue` in provider_common.dart); the test mirrors that.
http.Request _clone(http.Request request) =>
    http.Request(request.method, request.url)..body = request.body;

void main() {
  tearDown(() {
    providerTimeoutsOverride = null;
  });

  test('real IOClient + black-hole endpoint: the connect watchdog surfaces '
      'as the named TimeoutException, not a cast failure', () async {
    // Accept the request, never send headers.
    final blackHole = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSub = blackHole.listen((request) {});

    try {
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(milliseconds: 150),
      );
      final client = IOClient();
      final request = http.Request(
        'POST',
        Uri.parse('http://127.0.0.1:${blackHole.port}/v1/chat/completions'),
      )..body = '{"model":"m","stream":true}';

      // The retry budget (2 re-sends) is exercised for real here: three
      // stalled attempts, then the exhaustion error of record — the named
      // connect-watchdog TimeoutException, never the onTimeout cast error.
      await expectLater(
        sendWatchedProviderRequest(client, request, null),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('(connect watchdog)'),
              isNot(contains('StreamedResponse')),
            ),
          ),
        ),
      );
      client.close();
    } finally {
      await serverSub.cancel();
      await blackHole.close(force: true);
    }
  });

  // gh-1308 review thread 2 (the half-open keep-alive hypothesis): a
  // watchdog-cancelled zero-byte attempt must never hand its connection to
  // the replay. dart:io's pool never re-uses a connection with an in-flight
  // request, so the retry necessarily DIALS FRESH — this test pins that
  // contract at the shared-client seam: the replayed send arrives as a new
  // connection (distinct client port), the zero-byte socket stays
  // quarantined (its abandoned request never answers to pool it).
  test('a watchdog-cancelled zero-byte send replays on a FRESH connection '
      'of the SAME shared client — the dead socket is never re-used',
      () async {
    final seenClientPorts = <int>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSub = server.listen((request) async {
      seenClientPorts.add(request.connectionInfo!.remotePort);
      if (seenClientPorts.length == 1) {
        // The zero-byte hang: the request is accepted and NOTHING is ever
        // written back — the poisoned half-open entry from the ticket.
        return;
      }
      // Every later request answers normally (the endpoint recovered).
      request.response.headers.contentType = ContentType.text;
      request.response.write('ok');
      await request.response.close();
    });

    final client = IOClient();
    try {
      final source = CancelTokenSource();
      final request = http.Request(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'),
      )..body = '{"model":"m","stream":true}';

      // Attempt 1: the run-idle watchdog fires over the silent request —
      // the machine cancel aborts the watched send.
      final attempt = sendWatchedProviderRequest(client, request, source.token);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      source.cancel(
        RunIdleWatchdogFire('agent run produced no events for 480s'),
      );
      await expectLater(attempt, throwsA(isA<AbortedError>()));

      // Attempt 2 (the ladder's replay): the SAME client instance — only
      // the shared keep-alive pool stands between the attempts. A sent
      // http.Request is finalized by the client and cannot be re-sent, so
      // the replay rides a fresh clone (production's `_reissue` discipline).
      final replay = await sendWatchedProviderRequest(
        client,
        _clone(request),
        null,
      );
      expect(replay.statusCode, 200);
      expect(await replay.stream.bytesToString(), 'ok');

      // Two sends, two CONNECTIONS: the replay never landed on the
      // zero-byte socket that started it.
      expect(seenClientPorts, hasLength(2));
      expect(seenClientPorts[0], isNot(seenClientPorts[1]));
    } finally {
      // IOClient.close() force-closes the underlying HttpClient: the
      // abandoned zero-byte request never completes on its own.
      client.close();
      await serverSub.cancel();
      await server.close(force: true);
    }
  });
}
