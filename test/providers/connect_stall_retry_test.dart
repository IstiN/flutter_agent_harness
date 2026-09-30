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
/// 200 with an empty SSE body. Records every outbound request.
final class _StallClient extends http.BaseClient {
  _StallClient(this.stalls);

  final int stalls;

  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
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
  });
}
