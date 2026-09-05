// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/src/providers/aiin_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

http.Client _client(
  Future<http.Response> Function(http.Request request) handler,
) => http_testing.MockClient((request) async {
  final response = await handler(request);
  return response;
});

void main() {
  group('fetchAiinOAuthProviders', () {
    test('GETs the oauth-proxy providers list', () async {
      Uri? captured;
      final client = _client((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode({
            'providers': ['google', 'github'],
            'client_types': ['web', 'mobile', 'desktop'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final providers = await fetchAiinOAuthProviders(client: client);
      expect(providers, ['google', 'github']);
      expect(captured, isNotNull);
      expect(captured!.host, 'auth.aiin.by');
      expect(captured!.path, '/api/oauth-proxy/providers');
    });

    test('tolerates a non-list providers field', () async {
      final client = _client(
        (_) async => http.Response(jsonEncode({'providers': null}), 200),
      );
      expect(await fetchAiinOAuthProviders(client: client), isEmpty);
    });
  });

  group('initiateAiinOAuth', () {
    test('POSTs the redirect URI and parses the auth URL + state', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode({
            'auth_url': 'https://accounts.google.com/o/oauth2/auth?x=1',
            'state': 'oauth_proxy_abc',
            'expires_in': 900,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final initiate = await initiateAiinOAuth(
        provider: 'google',
        redirectUri: 'http://127.0.0.1:4919/callback',
        client: client,
      );
      expect(initiate.authUrl, 'https://accounts.google.com/o/oauth2/auth?x=1');
      expect(initiate.state, 'oauth_proxy_abc');
      expect(initiate.expiresIn, 900);
      expect(bodies, hasLength(1));
      expect(bodies.single['provider'], 'google');
      expect(bodies.single['client_redirect_uri'], 'http://127.0.0.1:4919/callback');
      expect(bodies.single['client_type'], 'desktop');
      expect(bodies.single['environment'], 'prod');
    });

    test('surfaces provider errors as AiinAuthException', () async {
      final client = _client(
        (_) async => http.Response(
          jsonEncode({'error': 'invalid_provider', 'message': 'nope'}),
          400,
        ),
      );
      await expectLater(
        initiateAiinOAuth(
          provider: 'nope',
          redirectUri: 'http://127.0.0.1:1/callback',
          client: client,
        ),
        throwsA(
          isA<AiinAuthException>()
              .having((e) => e.code, 'code', 'invalid_provider')
              .having((e) => e.message, 'message', 'nope'),
        ),
      );
    });
  });

  group('exchangeAiinOAuthCode', () {
    test('POSTs code+state and parses the token response', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode({
            'access_token': 'acc',
            'refresh_token': 'ref',
            'token_type': 'Bearer',
            'expires_in': 900,
            'refresh_expires_in': 1209600,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final tokens = await exchangeAiinOAuthCode(
        code: 'temp-code',
        state: 'oauth_proxy_abc',
        client: client,
      );
      expect(tokens.accessToken, 'acc');
      expect(tokens.refreshToken, 'ref');
      expect(tokens.expiresIn, 900);
      expect(tokens.refreshExpiresIn, 1209600);
      expect(bodies.single['code'], 'temp-code');
      expect(bodies.single['state'], 'oauth_proxy_abc');
    });

    test('maps state mismatch to invalid_grant', () async {
      final client = _client(
        (_) async => http.Response(
          jsonEncode({'error': 'invalid_grant', 'message': 'state mismatch'}),
          401,
        ),
      );
      await expectLater(
        exchangeAiinOAuthCode(code: 'c', state: 's', client: client),
        throwsA(
          isA<AiinAuthException>().having((e) => e.code, 'code', 'invalid_grant'),
        ),
      );
    });
  });

  group('createAiinApiKey', () {
    test('POSTs the Bearer JWT to /v1/keys and returns the raw key', () async {
      final requests = <http.Request>[];
      final client = _client((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'key-1',
            'user_id': 'u1',
            'prefix': 'sk-aiin-abcd',
            'created_at': '2026-01-01T00:00:00Z',
            'key': 'sk-aiin-deadbeefdeadbeefdeadbeefdeadbeef',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });
      final key = await createAiinApiKey(
        accessToken: 'acc',
        client: client,
      );
      expect(key.raw, 'sk-aiin-deadbeefdeadbeefdeadbeefdeadbeef');
      expect(key.id, 'key-1');
      expect(key.prefix, 'sk-aiin-abcd');
      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), 'https://api.aiin.by/v1/keys');
      expect(requests.single.headers['Authorization'], 'Bearer acc');
    });

    test('surfaces llm_access_denied with the service message', () async {
      final client = _client(
        (_) async => http.Response(
          jsonEncode({
            'error': 'llm_access_denied',
            'message': 'user has no LLM product access',
          }),
          403,
        ),
      );
      await expectLater(
        createAiinApiKey(accessToken: 'acc', client: client),
        throwsA(
          isA<AiinAuthException>()
              .having((e) => e.code, 'code', 'llm_access_denied')
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });
  });

  group('aiinJwtEmail', () {
    test('decodes the email claim from the payload', () {
      final payload = base64Url.encode(
        utf8.encode(jsonEncode({'email': 'user@example.com', 'sub': 'u1'})),
      );
      final token = 'header.$payload.signature';
      expect(aiinJwtEmail(token), 'user@example.com');
    });

    test('returns null for tokens without an email or malformed JWTs', () {
      final payload = base64Url.encode(utf8.encode(jsonEncode({'sub': 'u1'})));
      expect(aiinJwtEmail('header.$payload.signature'), isNull);
      expect(aiinJwtEmail('not-a-jwt'), isNull);
    });
  });

  group('isAiinBaseUrl', () {
    test('matches the API and auth hosts only at their domains', () {
      expect(isAiinBaseUrl('https://api.aiin.by/v1'), isTrue);
      expect(isAiinBaseUrl('https://api.aiin.by'), isTrue);
      expect(isAiinBaseUrl('https://auth.aiin.by/api/oauth-proxy/providers'), isTrue);
      expect(isAiinBaseUrl('https://evil.example/u?x=api.aiin.by'), isFalse);
      expect(isAiinBaseUrl('https://api.aiin.by.evil.example/v1'), isFalse);
      expect(isAiinBaseUrl('https://openrouter.ai/api/v1'), isFalse);
    });
  });

  group('error mapping', () {
    test('non-JSON error bodies still produce an AiinAuthException', () async {
      final client = _client((_) async => http.Response('gateway timeout', 504));
      await expectLater(
        fetchAiinOAuthProviders(client: client),
        throwsA(
          isA<AiinAuthException>()
              .having((e) => e.statusCode, 'statusCode', 504)
              .having((e) => e.message, 'message', contains('504')),
        ),
      );
    });
  });
}
