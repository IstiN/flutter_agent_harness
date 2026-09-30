// IT-1..2 for issue #823: quota adapters against MockClient (AC2, E2, E3).
// OpenRouter = the one REAL documented endpoint (GET /api/v1/auth/key).
// CodeMie = dark until the endpoint is pinned (OQ1 lean (b)).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 6, 30);
  final captured = <http.Request>[];

  http_testing.MockClient mockClient(
    Object? Function(http.Request request) handler,
  ) => http_testing.MockClient((request) async {
    captured.add(request);
    final body = handler(request);
    if (body is http.Response) return body;
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });

  Future<String?> keyResolver() async => 'sk-or-test';

  group('IT-1 OpenRouter adapter (AC2)', () {
    setUp(captured.clear);

    test('parses the documented key response under data', () async {
      final client = mockClient(
        (request) => {
          'data': {
            'label': 'my-key',
            'usage': 48.2,
            'limit': 150,
            'limit_remaining': 101.8,
          },
        },
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.isUnknown, isFalse);
      final quota = result.quota!;
      expect(quota.used, 48.2);
      expect(quota.limit, 150);
      expect(quota.unit, QuotaUnit.currencyUsd);
      expect(quota.isUnmetered, isFalse);
      expect(quota.updatedAt, now);
      expect(quota.remaining, closeTo(101.8, 1e-9));
      expect(captured, hasLength(1));
      expect(
        captured.single.url.toString(),
        'https://openrouter.ai/api/v1/auth/key',
      );
      expect(captured.single.headers['Authorization'], 'Bearer sk-or-test');
    });

    test('parses a bare top-level payload (no data wrapper)', () async {
      final client = mockClient((request) => {'usage': 5, 'limit': 20});
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota!.used, 5);
      expect(result.quota!.limit, 20);
    });

    test('null limit means prepaid no cap, usage preserved', () async {
      final client = mockClient(
        (request) => {'data': {'usage': 12.5, 'limit': null}},
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      final quota = result.quota!;
      expect(quota.used, 12.5);
      expect(quota.limit, isNull);
      expect(quota.isUnmetered, isFalse);
      expect(formatQuotaUsedLimit(quota), r'$12.50/no cap');
    });

    test('null usage and null limit render unlimited', () async {
      final client = mockClient(
        (request) => {'data': {'usage': null, 'limit': null}},
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(formatQuotaUsedLimit(result.quota!), 'unlimited');
    });

    test('null limit_remaining derives remaining from limit - usage', () async {
      final client = mockClient(
        (request) => {
          'data': {'usage': 10, 'limit': 100, 'limit_remaining': null},
        },
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota!.remaining, 90);
    });

    test('401 degrades to unknown with a one-line reason (E3)', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('{"error":"bad key"}', 401),
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, 'HTTP 401');
    });

    test('429 and 5xx degrade to unknown, never throw', () async {
      final adapter429 = OpenRouterQuotaAdapter(
        client: http_testing.MockClient(
          (request) async => http.Response('rate limited', 429),
        ),
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final adapter500 = OpenRouterQuotaAdapter(
        client: http_testing.MockClient(
          (request) async => http.Response('boom', 500),
        ),
        resolveApiKey: keyResolver,
        now: () => now,
      );
      expect((await adapter429.fetch()).reason, 'HTTP 429');
      expect((await adapter500.fetch()).reason, 'HTTP 500');
    });

    test('HTML garbage degrades to unknown (E2)', () async {
      final client = http_testing.MockClient(
        (request) async =>
            http.Response('<html><body>proxy error</body></html>', 200),
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, contains('invalid response'));
    });

    test('non-numeric usage degrades to unknown, never renders null (E2)',
        () async {
      final client = mockClient(
        (request) => {'data': {'usage': 'lots', 'limit': 100}},
      );
      final adapter = OpenRouterQuotaAdapter(
        client: client,
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
    });

    test('missing api key skips the endpoint entirely', () async {
      final adapter = OpenRouterQuotaAdapter(
        client: mockClient((request) => {'data': {}}),
        resolveApiKey: () async => null,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, contains('no api key'));
      expect(captured, isEmpty);
    });

    test('client exceptions degrade to unknown', () async {
      final adapter = OpenRouterQuotaAdapter(
        client: http_testing.MockClient(
          (request) async => throw http.ClientException('socket closed'),
        ),
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
    });
  });

  group('IT-2 CodeMie adapter (dark until pinned, OQ1 lean b)', () {
    setUp(captured.clear);

    test('ships dark: null endpoint reports unknown, zero HTTP calls', () async {
      final adapter = CodeMieQuotaAdapter(
        client: mockClient((request) => <String, Object?>{}),
        resolveSessionCookie: () async => 'sso=cookie',
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, contains('not pinned'));
      expect(captured, isEmpty);
    });

    test('provisional parse: usage/limit/resetsAt payload shape', () async {
      final client = mockClient(
        (request) => {
          'usage': 12.5,
          'limit': 100,
          'resetsAt': DateTime.utc(2026, 10, 11).toIso8601String(),
        },
      );
      final adapter = CodeMieQuotaAdapter(
        client: client,
        resolveSessionCookie: () async => 'sso=cookie',
        limitsEndpoint: Uri.parse(
          'https://codemie.lab.epam.com/code-assistant-api/v1/quota',
        ),
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.isUnknown, isFalse);
      expect(result.quota!.used, 12.5);
      expect(result.quota!.limit, 100);
      expect(result.quota!.unit, QuotaUnit.currencyUsd);
      expect(result.quota!.resetsAt, DateTime.utc(2026, 10, 11));
      expect(captured.single.headers['Cookie'], 'sso=cookie');
    });

    test('null/absent payload fields degrade to unknown, never crash (E2)',
        () async {
      final adapter = CodeMieQuotaAdapter(
        client: http_testing.MockClient(
          (request) async => http.Response('<html>gateway</html>', 200),
        ),
        resolveSessionCookie: () async => 'sso=cookie',
        limitsEndpoint: Uri.parse('https://codemie.example/quota'),
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
    });

    test('missing session cookie skips the endpoint', () async {
      final adapter = CodeMieQuotaAdapter(
        client: mockClient((request) => <String, Object?>{}),
        resolveSessionCookie: () async => null,
        limitsEndpoint: Uri.parse('https://codemie.example/quota'),
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, contains('no session'));
      expect(captured, isEmpty);
    });

    test('401 degrades to unknown with a one-line reason (E3)', () async {
      final adapter = CodeMieQuotaAdapter(
        client: http_testing.MockClient(
          (request) async => http.Response('expired', 401),
        ),
        resolveSessionCookie: () async => 'sso=cookie',
        limitsEndpoint: Uri.parse('https://codemie.example/quota'),
        now: () => now,
      );
      expect((await adapter.fetch()).reason, 'HTTP 401');
    });

    test('client exceptions degrade to unknown, never throw', () async {
      final adapter = CodeMieQuotaAdapter(
        client: http_testing.MockClient(
          (request) async => throw http.ClientException('reset by peer'),
        ),
        resolveSessionCookie: () async => 'sso=cookie',
        limitsEndpoint: Uri.parse('https://codemie.example/quota'),
        now: () => now,
      );
      final result = await adapter.fetch();
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
    });

    test('QuotaAwareProvider contract surfaces the parsed quota', () async {
      final codemie = CodeMieQuotaAdapter(
        client: mockClient((request) => {'usage': 12.5, 'limit': 100}),
        resolveSessionCookie: () async => 'sso=cookie',
        limitsEndpoint: Uri.parse('https://codemie.example/quota'),
        now: () => now,
      );
      expect(await codemie.fetchQuota(), isNotNull);
      expect(await codemie.fetchQuota(forceRefresh: true), isNotNull);

      final openrouter = OpenRouterQuotaAdapter(
        client: mockClient(
          (request) => {'data': {'usage': 1, 'limit': 2}},
        ),
        resolveApiKey: keyResolver,
        now: () => now,
      );
      final viaContract = await openrouter.fetchQuota();
      expect(viaContract!.limit, 2);
    });
  });
}
