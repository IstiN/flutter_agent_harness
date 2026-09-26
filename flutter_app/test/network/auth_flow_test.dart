// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/auth_flow.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The canned `POST /api/oauth-proxy/initiate` response.
const initiateBody =
    '{"auth_url":"https://accounts.google.com/o/oauth2/auth?state=st-1&'
    'redirect_uri=https%3A%2F%2Fai-native.cloud%2Flogin%2Foauth2%2Fcode%2Fgoogle",'
    '"state":"st-1","expires_in":600}';

/// The canned `POST /api/oauth-proxy/exchange` response.
const exchangeBody =
    '{"accessToken":"at-1","refreshToken":"rt-1","expiresIn":3600,'
    '"refreshExpiresIn":86400,"tokenType":"Bearer"}';

void main() {
  group('NetworkAuthFlow', () {
    test('happy path: initiate → browser callback → exchange', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: initiateBody)
        ..respond(200, body: exchangeBody);
      final flow = NetworkAuthFlow(
        client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
      );

      Uri? launched;
      final tokens = await flow.signIn(
        provider: 'google',
        startReceiver: () async =>
            FakeOAuthReceiver(callbackUri: kFakeOAuthCallback),
        openUrl: (authUrl) async {
          launched = authUrl;
        },
      );

      // The initiate answer is what gets opened in the browser —
      // VERBATIM (its redirect_uri is the auth service's provider
      // callback; rewriting it is a Google redirect_uri_mismatch 400).
      expect(launched!.host, 'accounts.google.com');
      expect(
        launched!.queryParameters['redirect_uri'],
        'https://ai-native.cloud/login/oauth2/code/google',
      );
      expect(httpClient.requests[0].url.path, '/api/oauth-proxy/initiate');
      final initiateRequest =
          jsonDecode(httpClient.requests[0].body) as Map<String, Object?>;
      expect(initiateRequest, containsPair('provider', 'google'));
      // The loopback (real ephemeral port) is registered as
      // client_redirect_uri BEFORE the auth URL exists.
      expect(
        initiateRequest['client_redirect_uri'],
        'http://127.0.0.1:5555/callback',
      );
      // The exchange wires the callback code + the initiate state.
      expect(httpClient.requests[1].url.path, '/api/oauth-proxy/exchange');
      expect(jsonDecode(httpClient.requests[1].body), {
        'code': 'temp-1',
        'state': 'st-1',
      });
      expect(tokens.accessToken, 'at-1');
      expect(tokens.refreshToken, 'rt-1');
      expect(tokens.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test(
      'a state mismatch throws AuthFlowException and never exchanges',
      () async {
        final httpClient = FakeHttpClient()..respond(200, body: initiateBody);
        final flow = NetworkAuthFlow(
          client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
        );

        await expectLater(
          flow.signIn(
            provider: 'google',
            startReceiver: () async => FakeOAuthReceiver(
              callbackUri: Uri.parse(
                'http://127.0.0.1:5555/callback?code=temp-1&state=WRONG',
              ),
            ),
            openUrl: (_) async {},
          ),
          throwsA(
            isA<AuthFlowException>().having(
              (e) => e.message,
              'message',
              contains('state mismatch'),
            ),
          ),
        );
        expect(httpClient.requests, hasLength(1)); // initiate only
      },
    );

    test('a callback without a code throws AuthFlowException', () async {
      final httpClient = FakeHttpClient()..respond(200, body: initiateBody);
      final flow = NetworkAuthFlow(
        client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
      );

      await expectLater(
        flow.signIn(
          provider: 'github',
          startReceiver: () async => FakeOAuthReceiver(
            callbackUri: Uri.parse('http://127.0.0.1:5555/callback?state=st-1'),
          ),
          openUrl: (_) async {},
        ),
        throwsA(isA<AuthFlowException>()),
      );
      expect(httpClient.requests, hasLength(1));
    });

    test('a provider error callback surfaces the error description', () async {
      final httpClient = FakeHttpClient()..respond(200, body: initiateBody);
      final flow = NetworkAuthFlow(
        client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
      );

      await expectLater(
        flow.signIn(
          provider: 'google',
          startReceiver: () async => FakeOAuthReceiver(
            callbackUri: Uri.parse(
              'http://127.0.0.1:5555/callback?error=access_denied&'
              'error_description=Denied&state=st-1',
            ),
          ),
          openUrl: (_) async {},
        ),
        throwsA(
          isA<AuthFlowException>().having(
            (e) => e.message,
            'message',
            'Denied',
          ),
        ),
      );
      expect(httpClient.requests, hasLength(1));
    });

    test('an exchange failure surfaces as FaNetworkException', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: initiateBody)
        ..respond(
          400,
          body: '{"error":{"code":"invalid_grant","message":"bad code"}}',
        );
      final flow = NetworkAuthFlow(
        client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
      );

      await expectLater(
        flow.signIn(
          provider: 'google',
          startReceiver: () async =>
              FakeOAuthReceiver(callbackUri: kFakeOAuthCallback),
          openUrl: (_) async {},
        ),
        throwsA(
          isA<FaNetworkException>().having(
            (e) => e.message,
            'message',
            'bad code',
          ),
        ),
      );
    });
  });
}
