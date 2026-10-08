// ConnTrace line-format contracts (gh-1395 AC2, UT half): the exact stderr
// line shapes a scripted alive-but-silent request produces, the structured
// event record, and the E4 zero-overhead guarantee when FA_CONN_DEBUG is
// off. The in-order IT against a real loopback server lives in
// stall_repro_floor_test.dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/providers/conn_trace.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A controllable fake client: records sends, answers with a scripted
/// streamed response.
final class FakeProviderClient extends http.BaseClient {
  FakeProviderClient(this._respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _respond;
  final sends = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends.add(request);
    return _respond(request);
  }

  @override
  void close() {}
}

http.Request _post(Uri url, {String body = '{"model":"t","stream":true}'}) {
  return http.Request('POST', url)
    ..headers['content-type'] = 'application/json'
    ..headers['authorization'] = 'Bearer sk-test-1395'
    ..body = body;
}

http.StreamedResponse _sseResponse(Stream<List<int>> body) {
  return http.StreamedResponse(
    body.asBroadcastStream(),
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

void main() {
  group('line-format contract (UT)', () {
    test('conn open (fresh, port P)', () {
      final line = connOpenLine(fresh: true, port: 54321);
      expect(line, 'conn open (fresh, port 54321)');
    });

    test('conn open (reused, port P)', () {
      expect(
        connOpenLine(fresh: false, port: 54321),
        'conn open (reused, port 54321)',
      );
      expect(connOpenLine(fresh: false, port: null), 'conn open (reused)');
    });

    test('first byte after Ns', () {
      expect(
        firstByteLine(const Duration(milliseconds: 420)),
        'first byte after 0.42s',
      );
      expect(
        firstByteLine(const Duration(milliseconds: 2500)),
        'first byte after 2.50s',
      );
    });

    test('idle watchdog FIRED after Ns (conn age, port P)', () {
      expect(
        idleWatchdogFiredLine(
          idleTimeout: const Duration(seconds: 300),
          connAge: const Duration(milliseconds: 3400),
          port: 54321,
        ),
        'idle watchdog FIRED after 300s (conn age 3.40s, port 54321)',
      );
      // Without connection forensics (unwrapped client) the line degrades
      // but still names the stall.
      expect(
        idleWatchdogFiredLine(idleTimeout: const Duration(seconds: 300)),
        'idle watchdog FIRED after 300s',
      );
    });

    test('connect watchdog line is DISTINCT from the idle line (E1)', () {
      final connect = connectWatchdogFiredLine(
        connectTimeout: const Duration(seconds: 180),
      );
      expect(connect, 'connect watchdog FIRED after 180s (no response bytes)');
      expect(connect, isNot(contains(idleWatchdogFiredLineKeyword)));
    });
  });

  group('structured events', () {
    setUp(() {
      resetConnTraceForTest();
    });

    test('traced client emits conn open + first byte as structured events '
        'and lines', () async {
      connTraceOverride = true;
      final controller = StreamController<List<int>>();
      final events = <ConnTraceEvent>[];
      connTraceSink = events.add;

      final client = connTraceWrapProviderClient(
        FakeProviderClient((request) async {
          // A fresh connection opens DURING the send (the observed
          // connectionFactory leg is IT-tested against a real loopback
          // server; here the note simulates its completion).
          connObserverNote(
            port: 40001,
            openedAfter: const Duration(seconds: 1),
          );
          controller.add(utf8.encode('data: {"delta":"first"}\n\n'));
          return _sseResponse(controller.stream);
        }),
        canInstallObserver: false,
      );

      final response = await client.send(
        _post(Uri.parse('https://gw.test/v1')),
      );
      await response.stream.first;
      await pumpEventQueue();

      expect(events.map((e) => e.kind), [
        ConnTraceKind.connOpen,
        ConnTraceKind.firstByte,
      ]);
      expect(events.first.line, 'conn open (fresh, port 40001)');
      expect(events.last.line, startsWith('first byte after '));
      // Recorded onto the in-memory board too (bench/LatencyMeter consume
      // via the sink; the board is the process-local fallback).
      expect(connTraceEvents, hasLength(2));
      connTraceSink = null;
    });

    test('request registry maps a response to its outbound payload '
        '(sentinel lookup)', () async {
      connTraceOverride = false;
      final client = connTraceWrapProviderClient(
        FakeProviderClient(
          (request) async => _sseResponse(
            Stream.value(utf8.encode('data: {"delta":"x"}\n\n')),
          ),
        ),
        canInstallObserver: false,
      );
      final request = _post(Uri.parse('https://gw.test/v1'));
      final response = await client.send(request);
      final record = stallRequestRecordFor(response);
      expect(record, isNotNull);
      expect(record!.url, request.url);
      expect(utf8.decode(record.bodyBytes!), '{"model":"t","stream":true}');
      // Authorization is held for the dump but never rendered raw by the
      // dump formatter.
      expect(record.headers['authorization'], 'Bearer sk-test-1395');
    });

    test('E4: FA_CONN_DEBUG off — zero trace overhead: the SAME response '
        'object is returned unwrapped and nothing is recorded', () async {
      connTraceOverride = false;
      resetConnTraceForTest();
      final innerResponse = _sseResponse(
        Stream.value(utf8.encode('data: {}\n\n')),
      );
      final client = connTraceWrapProviderClient(
        FakeProviderClient((request) async => innerResponse),
        canInstallObserver: false,
      );
      final response = await client.send(
        _post(Uri.parse('https://gw.test/v1')),
      );
      expect(
        identical(response, innerResponse),
        isTrue,
        reason: 'no stream wrapping, no timer churn when tracing is off',
      );
      await pumpEventQueue();
      expect(connTraceEvents, isEmpty);
    });
  });
}
