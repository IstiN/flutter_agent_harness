// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/github_oauth_web_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('buildGithubOauthAuthorizeUrl', () {
    test('targets the github.com authorize endpoint with the defaults', () {
      final uri = buildGithubOauthAuthorizeUrl(clientId: 'cid');
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.path, '/login/oauth/authorize');
      expect(uri.queryParameters['client_id'], 'cid');
      // The fa1.dev callback page shows the one-time code for pasting back.
      expect(uri.queryParameters['redirect_uri'], githubOauthWebRedirectUri);
      expect(uri.queryParameters['scope'], 'public_repo');
      expect(uri.queryParameters.containsKey('state'), isFalse);
    });

    test('forwards a custom redirect, state and scope set', () {
      final uri = buildGithubOauthAuthorizeUrl(
        clientId: 'cid',
        redirectUri: 'http://localhost:53681/oauth/callback',
        state: 's3cret',
        scopes: const ['public_repo', 'gist'],
      );
      expect(uri.queryParameters['redirect_uri'],
          'http://localhost:53681/oauth/callback');
      expect(uri.queryParameters['state'], 's3cret');
      expect(uri.queryParameters['scope'], 'public_repo gist');
    });
  });

  group('exchangeGithubOauthCode', () {
    test('posts the code exchange and returns the access token', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'access_token': 'ghs_fresh-token',
            'token_type': 'bearer',
            'scope': 'public_repo',
          }),
          200,
        );
      });

      final token = await exchangeGithubOauthCode(
        clientId: 'cid',
        code: 'one-time-code',
        clientSecret: 'test-app-secret',
        redirectUri: 'http://localhost:53681/oauth/callback',
        httpClient: client,
      );

      expect(token, 'ghs_fresh-token');
      final request = captured!;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://github.com/login/oauth/access_token',
      );
      expect(request.headers['Accept'], 'application/json');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body, {
        'client_id': 'cid',
        'code': 'one-time-code',
        'client_secret': 'test-app-secret',
        'redirect_uri': 'http://localhost:53681/oauth/callback',
      });
    });

    test('omits an absent secret and the redirect when default', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'access_token': 'tok'}),
          200,
        );
      });

      await exchangeGithubOauthCode(
        clientId: 'cid',
        code: 'abc',
        httpClient: client,
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.containsKey('client_secret'), isFalse);
      expect(body['redirect_uri'], githubOauthWebRedirectUri);
    });

    test('maps the GitHub error payload onto GithubApiException', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'error': 'bad_verification_code',
              'error_description':
                  'The code passed is incorrect or expired.',
            }),
            200,
          ));

      await expectLater(
        exchangeGithubOauthCode(
          clientId: 'cid',
          code: 'stale',
          httpClient: client,
        ),
        throwsA(
          isA<GithubApiException>()
              .having((e) => e.statusCode, 'statusCode', 200)
              .having(
                (e) => e.message,
                'message',
                'The code passed is incorrect or expired.',
              ),
        ),
      );
    });

    test('non-2xx responses throw with the status code', () async {
      final client = MockClient(
        (request) async => http.Response('nope', 503),
      );

      await expectLater(
        exchangeGithubOauthCode(
          clientId: 'cid',
          code: 'abc',
          httpClient: client,
        ),
        throwsA(
          isA<GithubApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('a 2xx body without a token field throws', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode({'surprise': 1}), 200),
      );

      await expectLater(
        exchangeGithubOauthCode(
          clientId: 'cid',
          code: 'abc',
          httpClient: client,
        ),
        throwsA(isA<GithubApiException>()),
      );
    });
  });
}
