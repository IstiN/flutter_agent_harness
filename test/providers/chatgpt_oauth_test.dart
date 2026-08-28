import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('PKCE generation', () {
    test('verifier uses only RFC 7636 characters', () {
      final verifier = generateChatGptPkceVerifier();
      expect(
        RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier),
        isTrue,
        reason: 'verifier: $verifier',
      );
    });

    test('challenge is base64url SHA-256 without padding', () {
      final verifier = generateChatGptPkceVerifier();
      final challenge = generateChatGptPkceChallenge(verifier);
      final expected = base64UrlEncode(
        sha256.convert(utf8.encode(verifier)).bytes,
      ).replaceAll('=', '');
      expect(challenge, expected);
    });

    test('state is base64url and unique per call', () {
      final a = generateChatGptState();
      final b = generateChatGptState();
      expect(a, isNot(b));
      expect(a, isNot(contains('=')));
      expect(a, isNot(contains('+')));
      expect(a, isNot(contains('/')));
    });
  });

  group('buildChatGptAuthorizeUrl', () {
    test('carries the Codex CLI client parameters', () {
      final url = buildChatGptAuthorizeUrl(
        redirectUri: 'http://127.0.0.1:1455/auth/callback',
        codeChallenge: 'challenge123',
        state: 'state-abc',
      );
      expect(url.host, 'auth.openai.com');
      expect(url.path, '/oauth/authorize');
      final params = url.queryParameters;
      expect(params['response_type'], 'code');
      expect(params['client_id'], chatGptOAuthClientId);
      expect(params['redirect_uri'], 'http://127.0.0.1:1455/auth/callback');
      expect(params['code_challenge'], 'challenge123');
      expect(params['code_challenge_method'], 'S256');
      expect(params['state'], 'state-abc');
      expect(params['originator'], 'codex_cli_rs');
      expect(params['codex_cli_simplified_flow'], 'true');
      expect(params['scope'], contains('offline_access'));
    });
  });

  group('ChatGptOAuthCredentials', () {
    test('encode/decode roundtrip keeps every field', () {
      const credentials = ChatGptOAuthCredentials(
        accessToken: 'at',
        refreshToken: 'rt',
        idToken: 'it',
        accountId: 'acc',
      );
      final decoded = ChatGptOAuthCredentials.decode(credentials.encode());
      expect(decoded.accessToken, 'at');
      expect(decoded.refreshToken, 'rt');
      expect(decoded.idToken, 'it');
      expect(decoded.accountId, 'acc');
      expect(decoded.expiresAt, isNull);
    });

    test('encode/decode roundtrip keeps expiresAt', () {
      final credentials = ChatGptOAuthCredentials(
        accessToken: 'at',
        refreshToken: 'rt',
        idToken: 'it',
        expiresAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final decoded = ChatGptOAuthCredentials.decode(credentials.encode());
      expect(decoded.expiresAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('decode tolerates a legacy blob without expires_at', () {
      final decoded = ChatGptOAuthCredentials.decode(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'id_token': 'it',
        }),
      );
      expect(decoded.expiresAt, isNull);
    });

    test('decode parses an int expires_at as UTC', () {
      final decoded = ChatGptOAuthCredentials.decode(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'id_token': 'it',
          'expires_at': 1767225600000,
        }),
      );
      expect(
        decoded.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1767225600000, isUtc: true),
      );
    });

    test('decode derives the account id from the id_token JWT', () {
      final payload = base64Url.encode(
        utf8.encode(
          jsonEncode({
            'https://api.openai.com/auth': {'chatgpt_account_id': 'jwt-acc'},
          }),
        ),
      );
      final jwt = 'header.$payload.signature';
      final decoded = ChatGptOAuthCredentials.decode(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'id_token': jwt,
        }),
      );
      expect(decoded.accountId, 'jwt-acc');
    });

    test('decode rejects malformed blobs', () {
      expect(() => ChatGptOAuthCredentials.decode('[]'), throwsFormatException);
      expect(
        () => ChatGptOAuthCredentials.decode('{"access_token":""}'),
        throwsFormatException,
      );
    });
  });

  group('needsRefresh', () {
    final expiry = DateTime.utc(2026, 1, 2, 3, 4, 5);
    ChatGptOAuthCredentials withExpiry(DateTime? expiresAt) =>
        ChatGptOAuthCredentials(
          accessToken: 'at',
          refreshToken: 'rt',
          idToken: 'it',
          expiresAt: expiresAt,
        );

    test('is false when expiresAt is null', () {
      expect(withExpiry(null).needsRefresh(expiry), isFalse);
    });

    test('is true when now is at or past expiry', () {
      expect(withExpiry(expiry).needsRefresh(expiry), isTrue);
    });

    test('is true within the skew window', () {
      expect(
        withExpiry(expiry)
            .needsRefresh(expiry.subtract(const Duration(seconds: 30))),
        isTrue,
      );
    });

    test('is false well before expiry', () {
      expect(
        withExpiry(expiry)
            .needsRefresh(expiry.subtract(const Duration(days: 1))),
        isFalse,
      );
    });
  });

  group('token endpoint', () {
    test('exchange posts a form body and parses all tokens', () async {
      final client = http_testing.MockClient((request) async {
        expect(request.url.host, 'auth.openai.com');
        expect(request.url.path, '/oauth/token');
        expect(
          request.headers['content-type'],
          contains('application/x-www-form-urlencoded'),
        );
        final body = Uri.splitQueryString(request.body);
        expect(body['grant_type'], 'authorization_code');
        expect(body['code'], 'the-code');
        expect(body['code_verifier'], 'the-verifier');
        expect(body['client_id'], chatGptOAuthClientId);
        return http.Response(
          jsonEncode({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'id_token': 'it-1',
          }),
          200,
        );
      });

      final credentials = await exchangeChatGptAuthorizationCode(
        code: 'the-code',
        redirectUri: 'http://127.0.0.1:1455/auth/callback',
        codeVerifier: 'the-verifier',
        client: client,
      );
      expect(credentials.accessToken, 'at-1');
      expect(credentials.refreshToken, 'rt-1');
      expect(credentials.expiresAt, isNull);
    });

    test('exchange parses expires_in into a future expiresAt', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(
          jsonEncode({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'id_token': 'it-1',
            'expires_in': 3600,
          }),
          200,
        ),
      );
      final credentials = await exchangeChatGptAuthorizationCode(
        code: 'the-code',
        redirectUri: 'http://127.0.0.1:1455/auth/callback',
        codeVerifier: 'the-verifier',
        client: client,
      );
      final now = DateTime.now().toUtc();
      expect(credentials.expiresAt, isNotNull);
      expect(credentials.expiresAt!.isAfter(now), isTrue);
      expect(
        credentials.expiresAt!.isBefore(now.add(const Duration(minutes: 61))),
        isTrue,
      );
    });

    test(
      'refresh posts JSON and keeps the old refresh token when absent',
      () async {
        final client = http_testing.MockClient((request) async {
          expect(request.headers['content-type'], contains('application/json'));
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['grant_type'], 'refresh_token');
          expect(body['refresh_token'], 'rt-old');
          return http.Response(jsonEncode({'access_token': 'at-new'}), 200);
        });

        final oldExpiry = DateTime.utc(2026, 1, 2, 3, 4, 5);
        final old = ChatGptOAuthCredentials(
          accessToken: 'at-old',
          refreshToken: 'rt-old',
          idToken: 'it-old',
          accountId: 'acc-1',
          expiresAt: oldExpiry,
        );
        final refreshed = await refreshChatGptCredentials(old, client: client);
        expect(refreshed.accessToken, 'at-new');
        expect(refreshed.refreshToken, 'rt-old');
        expect(refreshed.idToken, 'it-old');
        expect(refreshed.accountId, 'acc-1');
        expect(refreshed.expiresAt, oldExpiry);
      },
    );

    test('an error response raises ConfigException with the reason', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description': 'code expired',
          }),
          400,
        ),
      );
      expect(
        () => exchangeChatGptAuthorizationCode(
          code: 'x',
          redirectUri: 'y',
          codeVerifier: 'z',
          client: client,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('code expired'),
          ),
        ),
      );
    });

    test('a network failure wraps into ConfigException', () async {
      final client = http_testing.MockClient(
        (request) async => throw http.ClientException('network down'),
      );
      expect(
        () => exchangeChatGptAuthorizationCode(
          code: 'x',
          redirectUri: 'y',
          codeVerifier: 'z',
          client: client,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('ChatGPT OAuth token request failed'),
          ),
        ),
      );
    });

    test('a missing access_token raises ConfigException', () async {
      final client = http_testing.MockClient(
        (request) async =>
            http.Response(jsonEncode({'refresh_token': 'rt'}), 200),
      );
      expect(
        () => exchangeChatGptAuthorizationCode(
          code: 'x',
          redirectUri: 'y',
          codeVerifier: 'z',
          client: client,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('no access_token'),
          ),
        ),
      );
    });
  });
}
