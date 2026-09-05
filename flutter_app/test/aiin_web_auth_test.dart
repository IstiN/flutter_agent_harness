import 'dart:async';
import 'dart:convert';

import 'package:fa/services/aiin_web_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  final jwt = _jwt(email: 'user@aiin.by');

  http.Client mockAiinBackend() => http_testing.MockClient((request) async {
        final host = request.url.host;
        final path = request.url.path;
        if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/initiate') {
          return http.Response(
            jsonEncode({
              'auth_url': 'https://auth.aiin.by/oauth2/authorization/google',
              'state': 'st-1',
            }),
            200,
          );
        }
        if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/exchange') {
          return http.Response(
            jsonEncode({
              'access_token': jwt,
              'refresh_token': 'rt-1',
              'token_type': 'Bearer',
            }),
            200,
          );
        }
        if (host == 'api.aiin.by' && path == '/v1/keys') {
          return http.Response(
            jsonEncode({
              'id': 'key-1',
              'prefix': 'sk-aiin-aaa',
              'key': 'sk-aiin-${'a' * 32}',
            }),
            201,
          );
        }
        return http.Response('not found', 404);
      });

  test('web connect: popup callback completes exchange + key registration',
      () async {
    final coordinator = AiinWebAuthCoordinator();
    final statuses = <String>[];
    final result = await coordinator.connect(
      provider: 'google',
      onStatus: statuses.add,
      client: mockAiinBackend(),
      openFn: () => true,
      navigateFn: (url) {
        // The popup navigates to the auth page; the hosted callback page
        // delivers the code back.
        scheduleMicrotask(
          () => coordinator.complete(code: 'c-1', state: 'st-1'),
        );
      },
    );
    expect(result, isNotNull);
    expect(result!.apiKey.raw, 'sk-aiin-${'a' * 32}');
    expect(result.email, 'user@aiin.by');
    expect(statuses.join('\n'), isNot(contains('sk-aiin-')));
  });

  test('web connect: a blocked popup cancels with a hint', () async {
    final coordinator = AiinWebAuthCoordinator();
    final statuses = <String>[];
    final result = await coordinator.connect(
      provider: 'google',
      onStatus: statuses.add,
      client: mockAiinBackend(),
      openFn: () => false,
    );
    expect(result, isNull);
    expect(statuses.join('\n'), contains('blocked the sign-in popup'));
  });

  test('web connect: a forged state is rejected', () async {
    final coordinator = AiinWebAuthCoordinator();
    final statuses = <String>[];
    final result = await coordinator.connect(
      provider: 'google',
      onStatus: statuses.add,
      client: mockAiinBackend(),
      openFn: () => true,
      navigateFn: (url) {
        scheduleMicrotask(
          () => coordinator.complete(code: 'c-1', state: 'forged'),
        );
      },
    );
    expect(result, isNull);
    expect(statuses.join('\n'), contains('state mismatch'));
  });

  test('web connect: closing the popup (null code) cancels', () async {
    final coordinator = AiinWebAuthCoordinator();
    final statuses = <String>[];
    final result = await coordinator.connect(
      provider: 'google',
      onStatus: statuses.add,
      client: mockAiinBackend(),
      openFn: () => true,
      navigateFn: (url) {
        scheduleMicrotask(() => coordinator.complete());
      },
    );
    expect(result, isNull);
    expect(statuses.join('\n'), contains('cancelled'));
  });
}

/// A minimal three-part JWT carrying an [email] claim.
String _jwt({String? email}) {
  String part(Object? json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final payload = email == null ? <String, dynamic>{} : {'email': email};
  return '${part({'alg': 'none'})}.${part(payload)}.sig';
}
