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

  group('FanetClient.mintDapSession', () {
    test('POSTs with Bearer auth and parses the DAP session (200)', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'dapUrl': 'wss://dap.fa1.dev/ws',
              'agentName': 'agent-7',
              'clientSecret': 'sec-9',
              'env': {'FA_AGENT_NAME': 'agent-7'},
              'extra': 'ignored',
            }),
            200,
          );
        }),
      );

      final session = await client.mintDapSession(
        'net-1',
        sessionToken: 'tok-abc',
        scope: FanetDapScope.channel,
        channelId: 'ch-42',
        name: 'my-agent',
      );

      expect(session.dapUrl, 'wss://dap.fa1.dev/ws');
      expect(session.agentName, 'agent-7');
      expect(session.clientSecret, 'sec-9');
      expect(session.env, {'FA_AGENT_NAME': 'agent-7'});
      expect(captured!.method, 'POST');
      expect(
        captured!.url,
        Uri.parse('https://network.fa1.dev/api/networks/net-1/dap-sessions'),
      );
      expect(captured!.headers['authorization'], 'Bearer tok-abc');
      expect(jsonDecode(captured!.body), {
        'scope': 'channel',
        'channelId': 'ch-42',
        'name': 'my-agent',
      });
    });

    test('accepts 201 and omits optional body fields', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'dapUrl': 'wss://dap.fa1.dev/ws',
              'agentName': 'agent-1',
              'clientSecret': 'sec-1',
            }),
            201,
          );
        }),
      );

      final session = await client.mintDapSession(
        'net-1',
        sessionToken: 'tok',
        scope: FanetDapScope.network,
      );

      expect(session.env, isNull);
      expect(jsonDecode(captured!.body), {'scope': 'network'});
    });

    test('throws FanetApiException on 401', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('{"error":"unauthorized"}', 401),
        ),
      );

      await expectLater(
        client.mintDapSession(
          'net-1',
          sessionToken: 'expired',
          scope: FanetDapScope.network,
        ),
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

    test('throws FanetApiException on 404', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('not found', 404),
        ),
      );

      await expectLater(
        client.mintDapSession(
          'no-such-net',
          sessionToken: 'tok',
          scope: FanetDapScope.network,
        ),
        throwsA(
          isA<FanetApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });

  group('FanetClient.revokeDapSession', () {
    test('DELETEs with Bearer auth and accepts 204', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response('', 204);
        }),
      );

      await client.revokeDapSession(
        'net-1',
        sessionToken: 'tok-abc',
        agentName: 'agent-7',
      );

      expect(captured!.method, 'DELETE');
      expect(
        captured!.url,
        Uri.parse(
          'https://network.fa1.dev/api/networks/net-1/dap-sessions/agent-7',
        ),
      );
      expect(captured!.headers['authorization'], 'Bearer tok-abc');
    });

    test('URL-encodes the agent name in the path', () async {
      http.Request? captured;
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient((request) async {
          captured = request;
          return http.Response('', 204);
        }),
      );

      await client.revokeDapSession(
        'net-1',
        sessionToken: 'tok',
        agentName: 'agent/7',
      );

      expect(captured!.url.path, '/api/networks/net-1/dap-sessions/agent%2F7');
    });

    test('throws FanetApiException on non-204 status', () async {
      final client = FanetClient(
        baseUrl: 'https://network.fa1.dev',
        client: http_testing.MockClient(
          (request) async => http.Response('{"error":"not a member"}', 403),
        ),
      );

      await expectLater(
        client.revokeDapSession(
          'net-1',
          sessionToken: 'tok',
          agentName: 'agent-7',
        ),
        throwsA(
          isA<FanetApiException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having(
                (e) => e.bodyExcerpt,
                'bodyExcerpt',
                contains('not a member'),
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
