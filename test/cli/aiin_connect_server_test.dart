import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpStatus;

import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// End-to-end tests for the AIIN loopback connect flow: a REAL
/// [AiinCallbackServer] binds an ephemeral port, the fake browser issues
/// the redirect over real HTTP, and a mock [http.Client] serves the AIIN
/// auth/api endpoints.
void main() {
  final jwt = aiinTestJwt(email: 'user@aiin.by');

  /// Builds the mock AIIN backend; records the registered redirect URI.
  (http.Client, Future<String> Function()) mockAiinBackend({
    int initiateStatus = 200,
    int exchangeStatus = 200,
  }) {
    var redirectUri = '';
    final redirectCaptured = Completer<String>();
    final client = http_testing.MockClient((request) async {
      final host = request.url.host;
      final path = request.url.path;
      if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/initiate') {
        redirectUri =
            (jsonDecode(request.body)
                as Map<String, dynamic>)['client_redirect_uri'] as String;
        redirectCaptured.complete(redirectUri);
        if (initiateStatus != 200) return http.Response('boom', initiateStatus);
        return http.Response(
          jsonEncode({
            'auth_url': 'https://auth.aiin.by/oauth2/authorization/google',
            'state': 'st-1',
            'expires_in': 900,
          }),
          200,
        );
      }
      if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/exchange') {
        if (exchangeStatus != 200) return http.Response('boom', exchangeStatus);
        return http.Response(
          jsonEncode({
            'access_token': jwt,
            'refresh_token': '[REDACTED:Sensitive Value]',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'refresh_expires_in': 2592000,
          }),
          200,
        );
      }
      if (host == 'api.aiin.by' && path == '/v1/keys') {
        return http.Response(
          jsonEncode({
            'id': 'key-1',
            'user_id': 'user-1',
            'prefix': 'sk-aiin-abc12345',
            'created_at': '2026-01-01T00:00:00Z',
            'key': 'sk-aiin-${List.filled(32, 'a').join()}',
          }),
          201,
        );
      }
      return http.Response('not found', 404);
    });
    return (client, () => redirectCaptured.future);
  }

  /// The fake browser: opens nothing, but fires the OAuth redirect at the
  /// real loopback server.
  Future<bool> Function(String) fakeBrowser(
    Future<String> Function() redirectUri, {
    String? code,
    String? state,
    String? error,
    String? errorDescription,
    String? pathOverride,
  }) {
    return (url) async {
      final callback = await redirectUri();
      final target = pathOverride != null
          ? 'http://127.0.0.1:${Uri.parse(callback).port}$pathOverride'
          : Uri.parse(callback).replace(queryParameters: {
              'code': ?code,
              'state': ?state,
              'error': ?error,
              'error_description': ?errorDescription,
            }).toString();
      final response = await http.get(Uri.parse(target));
      return response.statusCode == HttpStatus.ok;
    };
  }

  test('happy path: browser redirect -> exchange -> registered key', () async {
    final (client, redirectUri) = mockAiinBackend();
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      provider: 'google',
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(
        redirectUri,
        code: 'c-1',
        state: 'st-1',
      ),
      client: client,
    );
    expect(result, isNotNull);
    expect(result!.apiKey.raw, startsWith('sk-aiin-'));
    expect(result.apiKey.prefix, 'sk-aiin-abc12345');
    expect(result.email, 'user@aiin.by');
    expect(result.tokens.refreshToken, isNotEmpty);
    expect(statuses, contains('browser opened; sign in with your google '
        'account'));
    expect(statussJoined(statuses), isNot(contains('sk-aiin-')));
  });

  test('no browser: the URL is printed and the flow still completes',
      () async {
    final (client, redirectUri) = mockAiinBackend();
    final statuses = <String>[];
    final browser = fakeBrowser(redirectUri, code: 'c-1', state: 'st-1');
    final result = await runAiinConnectCliFlow(
      provider: 'google',
      onStatus: statuses.add,
      openBrowserFn: (url) async {
        // No browser available — the user opens the printed URL by hand,
        // which fires the same redirect.
        await browser(url);
        return false;
      },
      client: client,
    );
    expect(result, isNotNull);
    expect(statussJoined(statuses), contains('could not open browser'));
    expect(statussJoined(statuses), contains('open this URL manually'));
  });

  test('state mismatch rejects the callback', () async {
    final (client, redirectUri) = mockAiinBackend();
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      provider: 'google',
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(
        redirectUri,
        code: 'c-1',
        state: 'forged',
      ),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('state mismatch'));
  });

  test('provider error callback surfaces the description', () async {
    final (client, redirectUri) = mockAiinBackend();
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      provider: 'google',
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(
        redirectUri,
        error: 'access_denied',
        errorDescription: 'user said no',
      ),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('user said no'));
  });

  test('exchange failure reports the setup error', () async {
    final (client, redirectUri) = mockAiinBackend(exchangeStatus: 500);
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      provider: 'google',
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(redirectUri, code: 'c-1', state: 'st-1'),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('AIIN setup failed'));
  });

  test('initiate failure reports the sign-in error', () async {
    final (client, redirectUri) = mockAiinBackend(initiateStatus: 500);
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      provider: 'google',
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(redirectUri, code: 'c-1', state: 'st-1'),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('AIIN sign-in failed'));
  });

  test('the callback server answers non-callback paths with 404', () async {
    final server = AiinCallbackServer();
    final redirectUri = await server.start(timeout: const Duration(seconds: 5));
    final port = Uri.parse(redirectUri).port;
    final miss = await http.get(
      Uri.parse('http://127.0.0.1:$port/other'),
    );
    expect(miss.statusCode, HttpStatus.notFound);
    // The server stays alive for the real callback afterwards.
    final browser = fakeBrowser(() async => redirectUri,
        code: 'c-1', state: 'st-1');
    expect(await browser('unused'), isTrue);
    final callback = await server.waitForCallback();
    expect(callback, isNotNull);
    expect(callback!.succeeded, isTrue);
    await server.close();
  });
}

String statussJoined(List<String> statuses) => statuses.join('\n');

/// A minimal three-part JWT carrying an [email] claim.
String aiinTestJwt({String? email}) {
  String part(Object? json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final payload = email == null ? <String, dynamic>{} : {'email': email};
  return '${part({'alg': 'none'})}.${part(payload)}.sig';
}
