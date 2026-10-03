// Issue #1121: a provider request that NEVER received a byte (the connect
// watchdog fired on a stalled endpoint) is retried in place with bounded
// backoff instead of aborting the whole run — 3/38 bench tasks died that
// way on run 36742787166. Mid-stream silence follows the idle-watchdog
// path (createSseIterator) and is NOT retried at the connect layer.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A client whose `send` stalls forever (endpoint accepted the connection
/// but never sends headers) for the first [stalls] calls, then answers
/// 200 with an empty SSE body. [lateFirstAnswer] overrides the first send
/// with a custom late-completing future (the slow-but-alive endpoint).
/// Records every outbound request.
final class _StallClient extends http.BaseClient {
  _StallClient(this.stalls, {this.lateFirstAnswer});

  final int stalls;

  final Future<http.StreamedResponse> Function()? lateFirstAnswer;

  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    if (requests.length == 1 && lateFirstAnswer != null) {
      return lateFirstAnswer!();
    }
    if (requests.length <= stalls) {
      return Completer<http.StreamedResponse>().future;
    }
    return Future.value(
      http.StreamedResponse(
        Stream.value(utf8.encode('')),
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
  }
}

http.Request _post(String url) => http.Request('POST', Uri.parse(url))
  ..headers['content-type'] = 'application/json'
  ..headers['authorization'] = 'Bearer sk-test'
  ..body = '{"model":"m","stream":true}';

void main() {
  final savedSleeper = transientRetrySleeper;
  final savedNotice = transientRetryNotice;
  final savedBackoff = providerConnectRetryBackoff;
  setUp(() {
    providerTimeoutsOverride = const ProviderTimeoutsOverride(
      connect: Duration(milliseconds: 20),
    );
    providerConnectRetryBackoff = const Duration(milliseconds: 1);
  });
  tearDown(() {
    providerTimeoutsOverride = null;
    transientRetrySleeper = savedSleeper;
    transientRetryNotice = savedNotice;
    providerConnectRetryBackoff = savedBackoff;
  });

  group('connect-stall retry (issue #1121)', () {
    test('happy path: one send, no retry, no notice', () async {
      final notices = <String>[];
      transientRetryNotice = (a, m, d, r) => notices.add('$a/$m $r');
      final client = _StallClient(0);

      final response = await sendProviderRequest(
        client,
        _post('https://api.example.com/v1/chat/completions'),
        null,
      );

      expect(response.statusCode, 200);
      expect(client.requests, hasLength(1));
      expect(notices, isEmpty);
    });

    test(
      'stalls twice then answers: retried transparently to success',
      () async {
        final notices = <Object?>[];
        transientRetryNotice = (a, m, d, r) => notices.add([a, m, d, r]);
        final client = _StallClient(2);

        final response = await sendProviderRequest(
          client,
          _post('https://api.example.com/v1/chat/completions'),
          null,
        );

        // 2 retries after the stalled first attempt — the CONNECT budget
        // (2 retries / 3 attempts), not a roles-failover attempt.
        expect(response.statusCode, 200);
        expect(client.requests, hasLength(3));
        // The identical payload is re-sent: body bytes, method, target and
        // the identity-bearing headers survive every _reissue clone (issue
        // #1121 review round 1 — pin the safety argument).
        final sent = client.requests.cast<http.Request>().toList();
        for (final resend in sent.skip(1)) {
          expect(resend.bodyBytes, sent.first.bodyBytes);
          expect(resend.method, sent.first.method);
          expect(resend.url, sent.first.url);
          expect(
            resend.headers['content-type'],
            sent.first.headers['content-type'],
          );
          expect(
            resend.headers['authorization'],
            sent.first.headers['authorization'],
          );
        }
        expect(notices, hasLength(2));
        expect(notices[0], [
          1,
          3,
          isA<Duration>(),
          'connect stall: no response bytes',
        ]);
        expect(notices[1], [
          2,
          3,
          isA<Duration>(),
          'connect stall: no response bytes',
        ]);
      },
    );

    test(
      'exhaustion: 2 retries then the same watchdog error as before',
      () async {
        final notices = <String>[];
        transientRetryNotice = (a, m, d, r) => notices.add('$a/$m');
        final client = _StallClient(999);

        await expectLater(
          sendProviderRequest(
            client,
            _post('https://api.example.com/v1/chat/completions'),
            null,
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              contains('(connect watchdog)'),
            ),
          ),
        );
        // 1 original + exactly the bounded 2 retries, then the identical
        // named watchdog TimeoutException surfaces.
        expect(client.requests, hasLength(3));
        expect(notices, ['1/3', '2/3']);
      },
    );

    test('mid-stream silence is NOT retried at the connect layer', () async {
      // 200 arrives (bytes!), then the body goes silent forever: the idle
      // watchdog owns this failure downstream, the connect layer must not
      // re-send (a replay would duplicate an in-flight generation).
      final body = StreamController<List<int>>(); // never fed, never closed
      final client = _StallClient(0);
      final response = await sendProviderRequest(
        client,
        _post('https://api.example.com/v1/chat/completions'),
        null,
      );
      final iterator = createSseIterator(
        http.StreamedResponse(
          body.stream,
          response.statusCode,
          headers: response.headers,
        ),
        null,
        idleTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        iterator.moveNext(),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('stream idle timeout'),
          ),
        ),
      );
      expect(client.requests, hasLength(1));
      await body.close();
    });

    test(
      'cancel during the backoff sleep aborts instead of retrying',
      () async {
        final source = CancelTokenSource();
        final client = _StallClient(999);
        // Backoff 200ms so the window between the watchdog (20ms) and the
        // retry is wide: the cancel lands at 40ms, mid-backoff-sleep.
        providerConnectRetryBackoff = const Duration(milliseconds: 200);
        Future<void>.delayed(const Duration(milliseconds: 40), source.cancel);

        await expectLater(
          sendProviderRequest(
            client,
            _post('https://api.example.com/v1/chat/completions'),
            source.token,
          ),
          throwsA(isA<CancelledException>()),
        );
        expect(client.requests, hasLength(1));
      },
    );
    test(
      'a LATE answer to an abandoned attempt is announced and detached',
      () async {
        final notices = <List<Object?>>[];
        transientRetryNotice = (a, m, d, r) => notices.add([a, m, d, r]);
        // First send answers 60ms in (watchdog fires at 20ms): the slow-but-
        // alive endpoint case. The late response must be announced on the
        // retry surface and its body detached, while the retry proceeds.
        final lateSubscribed = Completer<void>();
        final client = _StallClient(
          0,
          lateFirstAnswer: () {
            final body = StreamController<List<int>>(
              onListen: lateSubscribed.complete,
            );
            return Future<http.StreamedResponse>.delayed(
              const Duration(milliseconds: 60),
              () => http.StreamedResponse(
                body.stream,
                200,
                headers: {'content-type': 'text/event-stream'},
              ),
            );
          },
        );

        final response = await sendProviderRequest(
          client,
          _post('https://api.example.com/v1/chat/completions'),
          null,
        );
        expect(response.statusCode, 200);
        expect(client.requests, hasLength(2)); // orphan + retry both sent
        // The late answer lands ~40ms after the response returned — wait for
        // the janitor to take the body over before reading the notices.
        await lateSubscribed.future;
        final orphan = notices.firstWhere((n) => n[2] == Duration.zero);
        expect(orphan[0], 0); // labels the abandoned attempt, not a retry
        expect(orphan[1], providerConnectRetries + 1);
        expect(orphan[3], contains('answered late'));
        final retry = notices.firstWhere((n) => n[2] != Duration.zero);
        expect(retry[0], 1);
        expect(retry[3], 'connect stall: no response bytes');
      },
    );
  });
}
