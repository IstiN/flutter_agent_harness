// Unit tests for the AIIN web auth coordinator: the popup opens
// synchronously with the HOSTED sign-in URL (client-generated state), the
// callback must echo that state back, then exchange + key registration
// run from the browser.
import 'dart:async';
import 'dart:convert';

import 'package:fa/services/aiin_web_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Mock AIIN backend serving exchange + key registration.
MockClient _mockBackend({int exchangeStatus = 200}) => MockClient(
      (request) async {
        final path = request.url.path;
        if (path == '/api/oauth-proxy/exchange') {
          if (exchangeStatus != 200) {
            return http.Response('boom', exchangeStatus);
          }
          return _json(const {
            'access_token': 'jwt-a.jwt-b.jwt-c',
            'refresh_token': 'refresh-1',
            'token_type': 'Bearer',
            'expires_in': 3600,
          });
        }
        if (path == '/v1/keys') {
          final keyValue = 'sk-aiin-' + ('a' * 32);
          return _json({
            'id': 'key-1',
            'prefix': 'sk-aiin-abc12345',
            'key': keyValue,
          }, 201);
        }
        return http.Response('not found', 404);
      },
    );

void main() {
  test('web connect: popup gets the hosted /login URL, callback state must '
      'match ours, exchange registers the key', () async {
    final coordinator = AiinWebAuthCoordinator();
    String? loginUrl;
    final result = await coordinator.connect(
      openFn: () => true,
      navigateFn: (url) {
        loginUrl = url;
        // The hosted page redirects back with OUR state.
        final state = Uri.parse(url).queryParameters['state']!;
        scheduleMicrotask(
          () => coordinator.complete(code: 'c-1', state: state),
        );
      },
      client: _mockBackend(),
    );
    expect(result, isNotNull);
    expect(result!.apiKey.raw, startsWith('sk-aiin-'));
    expect(result.tokens.accessToken, 'jwt-a.jwt-b.jwt-c');
    expect(result.email, isNull);
    final uri = Uri.parse(loginUrl!);
    expect(uri.host, 'auth.aiin.by');
    expect(uri.path, '/login');
    expect(uri.queryParameters['client_type'], 'web');
    expect(uri.queryParameters['client_redirect_uri'],
        'https://fa1.dev/oauth/aiin.html');
    expect(uri.queryParameters['state']!.length, greaterThanOrEqualTo(32));
    expect(coordinator.lastFailure, isNull);
  });

  test('web connect: a forged callback state is rejected', () async {
    final coordinator = AiinWebAuthCoordinator();
    final result = await coordinator.connect(
      openFn: () => true,
      navigateFn: (url) {
        scheduleMicrotask(
          () => coordinator.complete(code: 'c-1', state: 'forged'),
        );
      },
      client: _mockBackend(),
    );
    expect(result, isNull);
    expect(coordinator.lastFailure, 'state_mismatch');
  });

  test('web connect: blocked popup reports null', () async {
    final coordinator = AiinWebAuthCoordinator();
    final result = await coordinator.connect(
      openFn: () => false,
      navigateFn: (_) {},
    );
    expect(result, isNull);
    expect(coordinator.lastFailure, 'popup_blocked');
  });

  test('web connect: empty callback code means cancelled', () async {
    final coordinator = AiinWebAuthCoordinator();
    final result = await coordinator.connect(
      openFn: () => true,
      navigateFn: (url) {
        scheduleMicrotask(() => coordinator.complete());
      },
      client: _mockBackend(),
    );
    expect(result, isNull);
    expect(coordinator.lastFailure, 'cancelled');
  });

  test('web connect: a timeout with no callback falls back cleanly',
      () async {
    final coordinator = AiinWebAuthCoordinator(timeout: Duration.zero);
    final result = await coordinator.connect(
      openFn: () => true,
      navigateFn: (_) {},
      timeout: Duration.zero,
    );
    expect(result, isNull);
    expect(coordinator.lastFailure, 'timeout');
  });

  test('web connect: an exchange failure surfaces through lastFailure',
      () async {
    final coordinator = AiinWebAuthCoordinator();
    final result = await coordinator.connect(
      openFn: () => true,
      navigateFn: (url) {
        final state = Uri.parse(url).queryParameters['state']!;
        scheduleMicrotask(
          () => coordinator.complete(code: 'c-1', state: state),
        );
      },
      client: _mockBackend(exchangeStatus: 500),
    );
    expect(result, isNull);
    expect(coordinator.lastFailure, isNotNull);
  });
}
