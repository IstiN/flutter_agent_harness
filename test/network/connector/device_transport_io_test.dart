// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the IO device transport (issue #2062 chunk 13):
/// enrollment + ticket through an in-memory `http.testing` MockClient and
/// the socket-adapter state machine over a fake duplex — NO real sockets
/// here (the loopback WS handshake lives in
/// `test/integration/device_transport_ws_test.dart`, tagged integration).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

NetworkEnvelope _hello() => NetworkEnvelope(
  kind: NetworkEnvelopeKind.hello,
  msgId: 'm-1',
  ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
  payload: {'deviceId': 'dev-1'},
);

/// An in-memory duplex the adapter tests drive: the test feeds [feed],
/// reads [written], and can end the peer side.
final class FakeDuplex implements ConnectorTextDuplex {
  final _inbound = StreamController<String>.broadcast();
  final written = <String>[];
  var shutdowns = 0;
  var _shutdown = false;

  @override
  Stream<String> get inbound => _inbound.stream;

  @override
  Future<void> write(String text) async {
    if (_shutdown) throw StateError('duplex closed');
    written.add(text);
  }

  @override
  Future<void> shutdown() async {
    _shutdown = true;
    shutdowns++;
    await _inbound.close();
  }

  /// The peer sends one text frame.
  void feed(String text) => _inbound.add(text);

  /// The peer closes its side (clean).
  Future<void> end() => _inbound.close();
}

void main() {
  group('DeviceEnrollmentClient.enrollDevice', () {
    DeviceEnrollmentClient clientFor(
      Future<http.Response> Function(http.Request) handler,
    ) => DeviceEnrollmentClient(
      httpClient: MockClient((request) async => await handler(request)),
    );

    test('posts to /api/devices/enroll with the JWT bearer and parses '
        'the identity pair', () async {
      http.Request? captured;
      final client = clientFor((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'deviceId': 'dev-42',
            'deviceToken': 'dt-secret',
            'personalNetwork': {'id': 'net-p'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final enrollment = await client.enrollDevice(
        baseUrl: 'https://network.fa1.dev/',
        jwt: 'jwt-1',
      );

      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(
        captured!.url.toString(),
        'https://network.fa1.dev/api/devices/enroll',
      );
      expect(captured!.headers['authorization'], 'Bearer jwt-1');
      expect(enrollment.deviceId, 'dev-42');
      expect(enrollment.deviceToken, 'dt-secret');
      // Never leak the token through toString.
      expect(enrollment.toString(), isNot(contains('dt-secret')));
    });

    test('401 maps to a typed exception carrying the status code', () async {
      final client = clientFor((_) async => http.Response('unauthorized', 401));
      await expectLater(
        client.enrollDevice(baseUrl: 'https://x', jwt: 'jwt'),
        throwsA(
          isA<DeviceEnrollmentException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('unauthorized')),
        ),
      );
    });

    test('400 maps to the same typed exception', () async {
      final client = clientFor(
        (_) async => http.Response('{"error":"bad request"}', 400),
      );
      await expectLater(
        client.enrollDevice(baseUrl: 'https://x', jwt: 'jwt'),
        throwsA(
          isA<DeviceEnrollmentException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    test('a network-level error maps to the typed exception without a '
        'status', () async {
      final client = DeviceEnrollmentClient(
        httpClient: MockClient(
          (request) async => throw http.ClientException('offline'),
        ),
      );
      await expectLater(
        client.enrollDevice(baseUrl: 'https://x', jwt: 'jwt'),
        throwsA(
          isA<DeviceEnrollmentException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message', contains('offline')),
        ),
      );
    });

    test('a malformed success body (missing fields) is an exception', () async {
      final client = clientFor(
        (_) async => http.Response(jsonEncode({'deviceId': 'only-id'}), 200),
      );
      await expectLater(
        client.enrollDevice(baseUrl: 'https://x', jwt: 'jwt'),
        throwsA(
          isA<DeviceEnrollmentException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    });

    test(
      'accepts a flat personalNetworkId when the nested id is empty',
      () async {
        http.Request? captured;
        final client = clientFor((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'deviceId': 'dev-flat',
              'deviceToken': 'dt-flat',
              'personalNetwork': {'id': ''},
              'personalNetworkId': 'net-flat',
            }),
            200,
          );
        });

        final enrollment = await client.enrollDevice(
          baseUrl: 'https://x',
          jwt: 'jwt',
          name: 'workstation',
          platform: 'macos',
        );

        expect(enrollment.personalNetworkId, 'net-flat');
        expect(jsonDecode(captured!.body), {
          'name': 'workstation',
          'platform': 'macos',
        });
      },
    );

    test(
      'returns a null personal network when neither shape has an id',
      () async {
        final client = clientFor(
          (_) async => http.Response(
            jsonEncode({
              'deviceId': 'dev-none',
              'deviceToken': 'dt-none',
              'personalNetwork': 'not-an-object',
              'personalNetworkId': '',
            }),
            200,
          ),
        );

        final enrollment = await client.enrollDevice(
          baseUrl: 'https://x',
          jwt: 'jwt',
        );

        expect(enrollment.deviceId, 'dev-none');
        expect(enrollment.personalNetworkId, isNull);
      },
    );
  });

  group('DeviceEnrollmentClient.wsTicket', () {
    test('posts to /api/ws-ticket with the deviceToken bearer and returns '
        'the ticket', () async {
      http.Request? captured;
      final client = DeviceEnrollmentClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'ticket': 'tk-1'}), 200);
        }),
      );

      final ticket = await client.wsTicket(
        baseUrl: 'https://network.fa1.dev',
        deviceToken: 'dt-1',
      );

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/api/ws-ticket');
      expect(captured!.headers['authorization'], 'Bearer dt-1');
      expect(ticket, 'tk-1');
    });

    test('accepts the bare JSON-string ticket form', () async {
      final client = DeviceEnrollmentClient(
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode('tk-bare'), 200),
        ),
      );
      expect(
        await client.wsTicket(baseUrl: 'https://x', deviceToken: 'dt'),
        'tk-bare',
      );
    });

    test('401 maps to the typed exception', () async {
      final client = DeviceEnrollmentClient(
        httpClient: MockClient((_) async => http.Response('expired', 401)),
      );
      await expectLater(
        client.wsTicket(baseUrl: 'https://x', deviceToken: 'dt'),
        throwsA(
          isA<DeviceEnrollmentException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test('a ticket-less success body is an exception', () async {
      final client = DeviceEnrollmentClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        client.wsTicket(baseUrl: 'https://x', deviceToken: 'dt'),
        throwsA(isA<DeviceEnrollmentException>()),
      );
    });
  });

  group('DeviceEnrollmentClient.patchRoster', () {
    test('sends typed merge entries with device-token auth', () async {
      http.Request? captured;
      final client = DeviceEnrollmentClient(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'patched': 'dev-42'}), 200);
        }),
      );

      await client.patchRoster(
        baseUrl: 'https://network.fa1.dev/',
        deviceId: 'dev-42',
        deviceToken: 'device-secret',
        agents: const [
          DeviceRosterAgent(
            name: 'mailbox-1',
            state: 'busy',
            exposed: true,
            dmPub: 'pub-1',
          ),
        ],
        sessions: const [
          DeviceRosterSession(
            id: 'session-1',
            state: 'wake-on-DM',
            networks: ['personal-1'],
            title: 'Release plan',
            path: '/work/flutter_agent',
            lastActivity: '2026-11-12T09:00:00.000Z',
          ),
        ],
      );

      expect(captured, isNotNull);
      expect(captured!.method, 'PATCH');
      expect(
        captured!.url.toString(),
        'https://network.fa1.dev/api/devices/dev-42/roster',
      );
      expect(captured!.headers['authorization'], 'Bearer device-secret');
      expect(captured!.headers['content-type'], 'application/json');
      expect(jsonDecode(captured!.body), {
        'agents': [
          {
            'name': 'mailbox-1',
            'state': 'busy',
            'exposed': true,
            'dmPub': 'pub-1',
          },
        ],
        'sessions': [
          {
            'id': 'session-1',
            'state': 'wake-on-DM',
            'networks': ['personal-1'],
            'title': 'Release plan',
            'path': '/work/flutter_agent',
            'lastActivity': '2026-11-12T09:00:00.000Z',
          },
        ],
      });
    });
  });

  group('ConnectorSocketAdapter', () {
    test(
      'decodes inbound JSON into envelopes and skips malformed text',
      () async {
        final duplex = FakeDuplex();
        final logs = <String>[];
        final socket = ConnectorSocketAdapter(duplex: duplex, onLog: logs.add);
        final received = <NetworkEnvelope>[];
        final subscription = socket.frames.listen(received.add);

        duplex.feed(jsonEncode(_hello().toJson()));
        duplex.feed('not json at all');
        duplex.feed(jsonEncode({'v': 1, 'kind': 'bogus_kind', 'msgId': 'x'}));
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received.first.kind, NetworkEnvelopeKind.hello);
        expect(received.first.msgId, 'm-1');
        expect(logs, hasLength(2));
        expect(logs.first, contains('malformed'));
        expect(socket.isOpen, isTrue);
        await subscription.cancel();
        await socket.close();
      },
    );

    test('sends envelopes as wire JSON through the duplex', () async {
      final duplex = FakeDuplex();
      final socket = ConnectorSocketAdapter(duplex: duplex);

      await socket.send(_hello());

      expect(duplex.written, hasLength(1));
      final decoded = NetworkEnvelope.fromJson(
        jsonDecode(duplex.written.first),
      );
      expect(decoded.msgId, 'm-1');
      expect(decoded.kind, NetworkEnvelopeKind.hello);
      await socket.close();
    });

    test(
      'send after close throws StateError (PairedClient semantics)',
      () async {
        final duplex = FakeDuplex();
        final socket = ConnectorSocketAdapter(duplex: duplex);
        await socket.close();

        expect(socket.isOpen, isFalse);
        await expectLater(socket.send(_hello()), throwsStateError);
        expect(duplex.written, isEmpty);
      },
    );

    test(
      'close is idempotent and shuts the duplex down exactly once',
      () async {
        final duplex = FakeDuplex();
        final socket = ConnectorSocketAdapter(duplex: duplex);
        await socket.close();
        await socket.close();
        await socket.close();

        expect(duplex.shutdowns, 1);
      },
    );

    test('the peer closing its side flips isOpen and completes the frames '
        'stream', () async {
      final duplex = FakeDuplex();
      final socket = ConnectorSocketAdapter(duplex: duplex);
      final done = Completer<void>();
      socket.frames.listen((_) {}, onDone: done.complete);

      await duplex.end();
      await done.future;

      expect(socket.isOpen, isFalse);
      // A late close still settles cleanly (idempotent).
      await socket.close();
      expect(duplex.shutdowns, 1);
    });

    test('send fails after the peer side ended the socket', () async {
      final duplex = FakeDuplex();
      final socket = ConnectorSocketAdapter(duplex: duplex);
      await duplex.end();
      await Future<void>.delayed(Duration.zero);

      expect(socket.isOpen, isFalse);
      await expectLater(socket.send(_hello()), throwsStateError);
    });
  });
}
