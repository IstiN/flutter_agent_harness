/// Tests for the fa_network REST client: join, DAP-session mint and revoke,
/// request wire shape, and error mapping.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/fanet/fanet_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('FanetClient.joinNetwork', () {
    test('POSTs the join body and returns the session token', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'sessionToken': 'tok-abc',
              'network': {'id': 'net-1'},
            }),
            200,
          );
        }),
      );

      final result = await client.joinNetwork(
        'net-1',
        password: 's3cret',
        displayName: 'Uladzimir',
      );

      expect(result.sessionToken, 'tok-abc');
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(
        captured!.url,
        Uri.parse('https://network.fa1.dev/api/networks/net-1/join'),
      );
      expect(captured!.headers['content-type'], contains('application/json'));
      expect(jsonDecode(captured!.body), {
        'password': 's3cret',
        'displayName': 'Uladzimir',
      });
    });

    test('omits displayName when not provided', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'sessionToken': 'tok'}), 200);
        }),
      );

      await client.joinNetwork('net-1', password: 'pw');

      expect(jsonDecode(captured!.body), {'password': 'pw'});
    });

    test('throws FanetApiException with status and body on 403', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('{"error":"wrong password"}', 403),
        ),
      );

      await expectLater(
        client.joinNetwork('net-1', password: 'bad'),
        throwsA(
          isA<FanetApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having(
                (e) => e.bodyExcerpt,
                'bodyExcerpt',
                contains('wrong password'),
              ),
        ),
      );
    });

    test('URL-encodes the network id in the path', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'sessionToken': 'tok'}), 200);
        }),
      );

      await client.joinNetwork('net/1', password: 'pw');

      expect(captured!.url.path, '/api/networks/net%2F1/join');
    });
  });

  group('FanetClient.enrollAgent', () {
    test('POSTs with Bearer auth and parses the enrollment (201)', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'name': 'ops-bot',
              'hubUrl': 'wss://hub.fa1.dev/ws',
              'clientSecret': 'sk_abc123',
              'enrolledAt': '2025-12-01T10:00:00Z',
              'note': 'store clientSecret now - never stored again',
              'extra': 'ignored',
            }),
            201,
          );
        }),
      );

      final enrollment = await client.enrollAgent(
        'net-1',
        token: 'owner-jwt',
        name: 'ops-bot',
      );

      expect(enrollment.name, 'ops-bot');
      expect(enrollment.hubUrl, 'wss://hub.fa1.dev/ws');
      expect(enrollment.clientSecret, 'sk_abc123');
      expect(enrollment.enrolledAt, '2025-12-01T10:00:00Z');
      expect(enrollment.note, 'store clientSecret now - never stored again');
      expect(captured!.method, 'POST');
      expect(
        captured!.url,
        Uri.parse('https://network.fa1.dev/api/networks/net-1/agents/enroll'),
      );
      expect(captured!.headers['authorization'], 'Bearer owner-jwt');
      expect(jsonDecode(captured!.body), {'name': 'ops-bot'});
    });

    test('URL-encodes the network id in the path', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'name': 'ops-bot',
              'hubUrl': 'wss://hub.fa1.dev/ws',
              'clientSecret': 'sk_abc123',
              'enrolledAt': '2025-12-01T10:00:00Z',
            }),
            201,
          );
        }),
      );

      await client.enrollAgent('net/1', token: 'jwt', name: 'ops-bot');

      expect(captured!.url.path, '/api/networks/net%2F1/agents/enroll');
    });

    test('throws FanetApiException on 200 (201 only)', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('{}', 200),
        ),
      );

      await expectLater(
        client.enrollAgent('net-1', token: 'jwt', name: 'ops-bot'),
        throwsA(
          isA<FanetApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
    });

    test(
      'throws FanetApiException on 400 (invalid_credentials name)',
      () async {
        final client = FanetClient(
          baseUrl: 'https://network.fa1.dev',
          client: http_testing.MockClient(
            (request) async =>
                http.Response('{"error":"invalid_credentials"}', 400),
          ),
        );

        await expectLater(
          client.enrollAgent('net-1', token: 'jwt', name: 'Bad_Name'),
          throwsA(
            isA<FanetApiException>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having(
                  (e) => e.bodyExcerpt,
                  'bodyExcerpt',
                  contains('invalid_credentials'),
                ),
          ),
        );
      },
    );

    test('throws FanetApiException on 401', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('{"error":"unauthorized"}', 401),
        ),
      );

      await expectLater(
        client.enrollAgent('net-1', token: 'expired', name: 'ops-bot'),
        throwsA(
          isA<FanetApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having(
                (e) => e.bodyExcerpt,
                'bodyExcerpt',
                contains('unauthorized'),
              ),
        ),
      );
    });

    test(
      'throws FanetApiException on 403 (member token is not enough)',
      () async {
        final client = FanetClient(
          baseUrl: 'https://network.fa1.dev',
          client: http_testing.MockClient(
            (request) async => http.Response('{"error":"forbidden"}', 403),
          ),
        );

        await expectLater(
          client.enrollAgent('net-1', token: 'member-token', name: 'ops-bot'),
          throwsA(
            isA<FanetApiException>()
                .having((e) => e.statusCode, 'statusCode', 403)
                .having(
                  (e) => e.bodyExcerpt,
                  'bodyExcerpt',
                  contains('forbidden'),
                ),
          ),
        );
      },
    );

    test('throws FanetApiException on 503 (hub unavailable)', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('{"error":"hub_unavailable"}', 503),
        ),
      );

      await expectLater(
        client.enrollAgent('net-1', token: 'jwt', name: 'ops-bot'),
        throwsA(
          isA<FanetApiException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having(
                (e) => e.bodyExcerpt,
                'bodyExcerpt',
                contains('hub_unavailable'),
              ),
        ),
      );
    });
  });

  group('FanetClient base URL handling', () {
    test('tolerates a trailing slash on baseUrl', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev/',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'sessionToken': 'tok'}), 200);
        }),
      );

      await client.joinNetwork('net-1', password: 'pw');

      expect(
        captured!.url,
        Uri.parse('https://network.fa1.dev/api/networks/net-1/join'),
      );
    });
  });
}
