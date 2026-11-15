// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Real loopback handshake for the IO device transport (issue #2062
/// chunk 13): a live `HttpServer` upgrades a WebSocket, echoes a
/// `hello_ok` for the client's hello, and serves the two device REST
/// endpoints — exercising [IoConnectorTransport] and
/// [DeviceEnrollmentClient] end-to-end over `dart:io`.
///
/// Tagged `integration` (opens real loopback sockets): excluded from the
/// default test runs, executed with `dart test --tags integration`.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:test/test.dart';

void main() {
  group('IoConnectorTransport (loopback WS)', () {
    test('dial → hello → hello_ok round-trips through the adapter', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final upgraded = Completer<void>();
      unawaited(() async {
        final request = await server.first;
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((text) async {
          final hello = NetworkEnvelope.fromJson(jsonDecode(text as String));
          socket.add(
            jsonEncode(
              NetworkEnvelope(
                kind: NetworkEnvelopeKind.helloOk,
                msgId: 'ok-1',
                refId: hello.msgId,
                ts: rfc3339Timestamp(DateTime.now().toUtc()),
              ).toJson(),
            ),
          );
          await socket.close();
        });
        upgraded.complete();
      }());
      addTearDown(() => server.close(force: true));

      const transport = IoConnectorTransport();
      final socket = await transport.dial(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        'tk-loopback',
      );
      expect(socket.isOpen, isTrue);

      final replies = <NetworkEnvelope>[];
      final done = Completer<void>();
      final subscription = socket.frames.listen(
        (envelope) {
          replies.add(envelope);
          done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      addTearDown(subscription.cancel);

      await socket.send(_hello());
      await done.future.timeout(const Duration(seconds: 10));

      expect(replies, hasLength(1));
      expect(replies.first.kind, NetworkEnvelopeKind.helloOk);
      expect(replies.first.refId, 'm-1');
      await socket.close();
      await upgraded.future;
    });

    test('a refused upgrade (401) throws — the client retries with '
        'backoff', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final answered = Completer<void>();
      unawaited(() async {
        final request = await server.first;
        request.response.statusCode = 401;
        await request.response.close();
        answered.complete();
      }());
      addTearDown(() => server.close(force: true));

      const transport = IoConnectorTransport();
      await expectLater(
        transport.dial(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
          'tk-stale',
        ),
        throwsA(isA<Object>()),
      );
      await answered.future;
    });
  });

  group('DeviceEnrollmentClient (loopback REST)', () {
    test('enrollDevice + wsTicket over a real loopback server', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      unawaited(() async {
        await for (final request in server) {
          final auth = request.headers.value('authorization');
          if (request.uri.path == '/api/devices/enroll') {
            expect(auth, 'Bearer jwt-live');
            await _json(request, 200, {
              'deviceId': 'dev-live',
              'deviceToken': 'dt-live',
            });
          } else if (request.uri.path == '/api/ws-ticket') {
            expect(auth, 'Bearer dt-live');
            await _json(request, 200, {'ticket': 'tk-live'});
          } else {
            await _json(request, 404, {'error': 'unknown'});
          }
        }
      }());
      addTearDown(() => server.close(force: true));

      final client = DeviceEnrollmentClient();
      final enrollment = await client.enrollDevice(
        baseUrl: 'http://127.0.0.1:${server.port}',
        jwt: 'jwt-live',
      );
      expect(enrollment.deviceId, 'dev-live');
      expect(enrollment.deviceToken, 'dt-live');

      final ticket = await client.wsTicket(
        baseUrl: 'http://127.0.0.1:${server.port}',
        deviceToken: enrollment.deviceToken,
      );
      expect(ticket, 'tk-live');
    });

    test('a 4xx status surfaces as DeviceEnrollmentException', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final served = Completer<void>();
      unawaited(() async {
        final request = await server.first;
        await _json(request, 401, {
          'error': {'code': 'unauthorized'},
        });
        served.complete();
      }());
      addTearDown(() => server.close(force: true));

      final client = DeviceEnrollmentClient();
      await expectLater(
        client.enrollDevice(
          baseUrl: 'http://127.0.0.1:${server.port}',
          jwt: 'jwt-stale',
        ),
        throwsA(
          isA<DeviceEnrollmentException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      await served.future;
    });
  });
}

NetworkEnvelope _hello() => NetworkEnvelope(
  kind: NetworkEnvelopeKind.hello,
  msgId: 'm-1',
  ts: rfc3339Timestamp(DateTime.now().toUtc()),
  payload: {'deviceId': 'dev-loopback'},
);

Future<void> _json(HttpRequest request, int status, Object body) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}
