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
}
