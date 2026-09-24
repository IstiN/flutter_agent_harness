import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

http.StreamedResponse _responseFromBytes(Stream<List<int>> bytes) {
  return http.StreamedResponse(
    bytes,
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

final _connectionClosed = http.ClientException(
  'Connection closed while receiving data',
  Uri.parse('https://api.z.ai/api/coding/paas/v4/chat/completions'),
);

void main() {
  group('createSseIterator idle watchdog', () {
    test('heartbeat comment bytes do NOT reset the idle timer', () async {
      // A brain-dead gateway that keep-alives `: ping` comments forever but
      // never sends a content event used to hold the turn hostage: the old
      // byte-level watchdog reset on every heartbeat. The watchdog now
      // measures EVENT-level silence — comments are dropped by the decoder.
      final controller = StreamController<List<int>>();
      final timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        controller.add(utf8.encode(': ping\n\n'));
      });
      final iterator = createSseIterator(
        _responseFromBytes(controller.stream),
        null,
        idleTimeout: const Duration(milliseconds: 120),
      );
      final sw = Stopwatch()..start();
      try {
        await expectLater(
          iterator.moveNext(),
          throwsA(isA<TimeoutException>()),
        );
        // ~120ms of true event silence, not the >1s the byte-level reset
        // would have allowed.
        expect(sw.elapsedMilliseconds, lessThan(1000));
      } finally {
        timer.cancel();
        await controller.close();
      }
    });

    test('real events keep the stream alive', () async {
      final controller = StreamController<List<int>>();
      var ticks = 0;
      Timer.periodic(const Duration(milliseconds: 40), (t) {
        ticks++;
        controller.add(utf8.encode('data: {"delta":$ticks}\n\n'));
        if (ticks == 5) {
          t.cancel();
          unawaited(controller.close());
        }
      });
      final iterator = createSseIterator(
        _responseFromBytes(controller.stream),
        null,
        idleTimeout: const Duration(milliseconds: 150),
      );
      var events = 0;
      while (await iterator.moveNext()) {
        events++;
      }
      expect(events, 5);
    });

    test('silence on a dead connection still times out', () async {
      final controller = StreamController<List<int>>(); // never emits
      final iterator = createSseIterator(
        _responseFromBytes(controller.stream),
        null,
        idleTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(iterator.moveNext(), throwsA(isA<TimeoutException>()));
      await controller.close();
    });
  });

  // Issue #921: '[CLI] Fa crashing during low internet connection'.
  // The async* SseDecoder cannot finish cancelling while it is suspended
  // awaiting input, so after the SSE iteration is abandoned (idle watchdog,
  // abort) the byte pipeline stays attached to the socket. A flaky link's
  // late failure arriving in that window used to find a handlerless chain
  // and escaped to the root zone: 'fa crashed: ClientException: Connection
  // closed while receiving data'. Every abandonment must swallow it.
  group('createSseIterator post-abandonment errors (issue #921)', () {
    Future<bool> runGuarded(Future<void> Function() body) async {
      var escaped = false;
      await runZonedGuarded(body, (_, _) => escaped = true);
      // Let any late zone delivery surface before the caller asserts.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return escaped;
    }

    test('idle-watchdog timeout then dying link does not crash', () async {
      // The field shape: the endpoint goes silent, the watchdog fires and
      // abandons the stream (it does NOT cancel the cancel token), then the
      // link reports its failure.
      final controller = StreamController<List<int>>(); // never emits
      final iterator = createSseIterator(
        _responseFromBytes(controller.stream),
        null,
        idleTimeout: const Duration(milliseconds: 60),
      );
      final escaped = await runGuarded(() async {
        await expectLater(
          iterator.moveNext(),
          throwsA(isA<TimeoutException>()),
        );
        controller.addError(_connectionClosed);
        unawaited(controller.close());
      });
      expect(
        escaped,
        isFalse,
        reason:
            'post-timeout transport errors must '
            'be swallowed, not crash the process',
      );
    });

    test('cancel mid-stream then dying link does not crash', () async {
      final controller = StreamController<List<int>>();
      final iterator = createSseIterator(
        _responseFromBytes(controller.stream),
        null,
        idleTimeout: const Duration(seconds: 30),
      );
      final escaped = await runGuarded(() async {
        final moveNext = iterator.moveNext();
        controller.add(utf8.encode('data: {"delta":1}\n\n'));
        expect(await moveNext, isTrue);
        // Abandon mid-stream; inject the transport failure while the
        // async* chain's cancellation is still settling.
        final cancelFuture = iterator.cancel();
        controller.addError(_connectionClosed);
        unawaited(controller.close());
        await cancelFuture;
      });
      expect(
        escaped,
        isFalse,
        reason:
            'post-cancel transport errors must '
            'be swallowed, not crash the process',
      );
    });

    test('token abort still swallows the connection-closed error', () async {
      // Preserved behavior (documented on createSseIterator): the abort
      // path's injected connection-closed error is swallowed.
      final source = CancelTokenSource();
      final controller = StreamController<List<int>>();
      final iterator = createSseIterator(
        _responseFromBytes(controller.stream),
        source.token,
        idleTimeout: const Duration(seconds: 30),
      );
      final escaped = await runGuarded(() async {
        final moveNext = iterator.moveNext();
        controller.add(utf8.encode('data: {"delta":1}\n\n'));
        expect(await moveNext, isTrue);
        source.cancel();
        // The abort path force-closes the client right after; the dying
        // socket's error must stay swallowed.
        controller.addError(_connectionClosed);
        unawaited(controller.close());
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      expect(escaped, isFalse);
    });
  });
}
