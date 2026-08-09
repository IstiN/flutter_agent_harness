import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('PKCE generation', () {
    test('verifier uses only RFC 7636 characters', () {
      final verifier = generateOpenRouterCodeVerifier();
      expect(
        RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier),
        isTrue,
        reason: 'verifier: $verifier',
      );
    });

    test('challenge is base64url SHA-256 without padding', () {
      final verifier = generateOpenRouterCodeVerifier();
      final challenge = generateOpenRouterCodeChallenge(verifier);
      expect(challenge, isNot(contains('=')));
      expect(challenge, isNot(contains('+')));
      expect(challenge, isNot(contains('/')));

      final expected = base64UrlEncode(
        sha256.convert(utf8.encode(verifier)).bytes,
      ).replaceAll('=', '');
      expect(challenge, expected);
    });

    test('different verifiers produce different challenges', () {
      final a = generateOpenRouterCodeChallenge(
        generateOpenRouterCodeVerifier(),
      );
      final b = generateOpenRouterCodeChallenge(
        generateOpenRouterCodeVerifier(),
      );
      expect(a, isNot(b));
    });
  });

  group('buildOpenRouterAuthUrl', () {
    test('includes challenge, method, callback and label', () {
      final url = buildOpenRouterAuthUrl(
        codeChallenge: 'challenge123',
        callbackUrl: 'http://localhost:1234/',
        keyLabel: 'fah-cli',
      );
      expect(url.host, 'openrouter.ai');
      expect(url.path, '/auth');
      expect(url.queryParameters['code_challenge'], 'challenge123');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['callback_url'], 'http://localhost:1234/');
      expect(url.queryParameters['key_label'], 'fah-cli');
    });

    test('omits callback_url and key_label when null/empty', () {
      final url = buildOpenRouterAuthUrl(codeChallenge: 'challenge123');
      expect(url.queryParameters.containsKey('callback_url'), isFalse);
      expect(url.queryParameters.containsKey('key_label'), isFalse);
      expect(url.queryParameters['code_challenge_method'], 'S256');
    });
  });

  group('exchangeOpenRouterCode', () {
    test('returns key and sha256 hash on success', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), openRouterTokenEndpoint);
        expect(request.headers['Content-Type'], 'application/json');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['code'], 'auth-code');
        expect(body['code_verifier'], 'verifier');
        expect(body['code_challenge_method'], 'S256');
        return http.Response(jsonEncode({'key': 'sk-or-testkey'}), 200);
      });

      final result = await exchangeOpenRouterCode(
        'auth-code',
        codeVerifier: 'verifier',
        client: client,
        label: 'Fa',
      );
      expect(result.key, 'sk-or-testkey');
      expect(result.label, 'Fa');
      final expectedHash = await sha256Hex('sk-or-testkey');
      expect(result.keyHash, expectedHash);
      expect(result.settingsUrl, 'https://openrouter.ai/keys/$expectedHash');
    });

    test('throws ConfigException on 403 invalid code', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'Invalid code or code_verifier'}),
          403,
        ),
      );

      expect(
        () => exchangeOpenRouterCode(
          'bad-code',
          codeVerifier: 'verifier',
          client: client,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('403'),
          ),
        ),
      );
    });

    test('throws ConfigException when response body lacks key', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'unexpected': true}), 200),
      );

      expect(
        () => exchangeOpenRouterCode(
          'code',
          codeVerifier: 'verifier',
          client: client,
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('throws ConfigException on network failure', () async {
      final client = MockClient((_) async => throw Exception('network down'));

      expect(
        () => exchangeOpenRouterCode(
          'code',
          codeVerifier: 'verifier',
          client: client,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('sha256Hex', () {
    test('matches known SHA-256 hex', () async {
      final hash = await sha256Hex('hello');
      expect(
        hash,
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
    });
  });
}
