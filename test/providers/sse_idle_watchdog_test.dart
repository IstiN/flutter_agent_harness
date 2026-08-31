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
        await expectLater(iterator.moveNext(), throwsA(isA<TimeoutException>()));
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
        controller.add(
          utf8.encode('data: {"delta":$ticks}\n\n'),
        );
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
}
