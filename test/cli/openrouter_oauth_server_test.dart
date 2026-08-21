@Tags(['io'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/openrouter_oauth_server.dart';
import 'package:flutter_agent_harness/src/providers/openrouter_oauth.dart';
import 'package:test/test.dart';

void main() {
  group('OpenRouterOAuthLocalCallbackServer', () {
    test('binds to 127.0.0.1 on an ephemeral port', () async {
      final server = OpenRouterOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 1));
      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, endsWith('/'));
      await server.close();
    });

    test('captures the authorization code from the callback', () async {
      final server = OpenRouterOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 5));

      final uri = Uri.parse(
        url,
      ).replace(queryParameters: {'code': 'test-auth-code-123'});
      final requestFuture = _httpGet(uri);

      final codeFuture = server.waitForCode();
      final response = await requestFuture;
      final code = await codeFuture;

      expect(code, 'test-auth-code-123');
      expect(response.statusCode, 200);
      expect(response.body, contains('Authorized'));
      await server.close();
    });

    test('completes with null on timeout', () async {
      final server = OpenRouterOAuthLocalCallbackServer();
      await server.start(timeout: const Duration(milliseconds: 50));
      final code = await server.waitForCode();
      expect(code, isNull);
    });

    test('completes with null on explicit error parameter', () async {
      final server = OpenRouterOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 5));

      final uri = Uri.parse(url).replace(
        queryParameters: {
          'error': 'access_denied',
          'error_description': 'user denied',
        },
      );
      final requestFuture = _httpGet(uri);

      final codeFuture = server.waitForCode();
      final response = await requestFuture;
      final code = await codeFuture;

      expect(code, isNull);
      expect(response.statusCode, 200);
      expect(response.body, contains('Authorization failed'));
      expect(response.body, contains('user denied'));
      await server.close();
    });

    test('returns 400 when code is missing', () async {
      final server = OpenRouterOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 1));

      final response = await _httpGet(Uri.parse(url));
      expect(response.statusCode, 400);
      expect(response.body, contains('Missing authorization code'));
      await server.close();
    });
  });

  group('runOpenRouterOAuthCliFlow', () {
    test(
      'exchanges code and returns key when browser callback fires',
      () async {
        final statuses = <String>[];
        String? callbackUrl;

        final result = await runOpenRouterOAuthCliFlow(
          onStatus: (status) {
            statuses.add(status);
            if (status.startsWith('listening for OAuth callback on')) {
              callbackUrl = status
                  .split('listening for OAuth callback on ')
                  .last;
            }
          },
          openBrowserFn: (url) async {
            final cb = callbackUrl;
            expect(cb, isNotNull);
            // Simulate the browser redirecting back with a code.
            final callbackUri = Uri.parse(
              cb!,
            ).replace(queryParameters: {'code': 'simulated-code'});
            // Fire-and-forget GET to the callback server.
            unawaited(_httpGet(callbackUri));
            return true;
          },
          exchangeFn:
              ({
                required String code,
                required String codeVerifier,
                String? label,
              }) async {
                expect(code, 'simulated-code');
                expect(codeVerifier, isNotEmpty);
                expect(label, 'Fa');
                return const OpenRouterOAuthKey(
                  key: 'sk-or-mocked',
                  label: 'Fa',
                );
              },
        );

        expect(result, isNotNull);
        expect(result!.key, 'sk-or-mocked');
        expect(statuses, contains(contains('listening for OAuth callback on')));
        expect(statuses, contains(contains('authorization code received')));
        expect(statuses, contains('OpenRouter authorized'));
      },
    );
  });
}

Future<_SimpleResponse> _httpGet(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return _SimpleResponse(response.statusCode, body);
  } finally {
    client.close();
  }
}

final class _SimpleResponse {
  _SimpleResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}
