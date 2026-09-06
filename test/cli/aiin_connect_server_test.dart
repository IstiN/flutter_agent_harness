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
///
/// The flow opens the HOSTED AIIN sign-in page
/// (`/login?client_redirect_uri=...&state=...`) — the page runs the whole
/// OAuth round-trip on AIIN's side and redirects back to our loopback
/// with `code` + our state. The fake browser echoes both back.
void main() {
  final jwt = aiinTestJwt(email: 'user@aiin.by');

  /// Builds the mock AIIN backend serving the exchange + key endpoints.
  http.Client mockAiinBackend({int exchangeStatus = 200}) {
    final client = http_testing.MockClient((request) async {
      final host = request.url.host;
      final path = request.url.path;
      if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/exchange') {
        if (exchangeStatus != 200) return http.Response('boom', exchangeStatus);
        return http.Response(
          jsonEncode({
            'access_token': jwt,
            'refresh_token': 'refresh-${jwt.length}',
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
    return client;
  }

  /// The fake browser: opens nothing. Parses the state + redirect URI out
  /// of the hosted login page URL and fires the OAuth redirect at the
  /// real loopback server. [stateOverride] forges the state (mismatch
  /// tests); null error means a success redirect.
  Future<bool> Function(String) fakeBrowser({
    String? stateOverride,
    String? code,
    String? state,
    String? error,
    String? errorDescription,
  }) {
    return (url) async {
      final login = Uri.parse(url);
      final redirect =
          login.queryParameters['client_redirect_uri'] ?? '';
      final expectedState = stateOverride ?? login.queryParameters['state'];
      final target = Uri.parse(redirect).replace(queryParameters: {
        'code': ?code,
        'state': expectedState,
        'error': ?error,
        'error_description': ?errorDescription,
      }).toString();
      final response = await http.get(Uri.parse(target));
      return response.statusCode == HttpStatus.ok;
    };
  }

  test('happy path: browser redirect -> exchange -> registered key', () async {
    final client = mockAiinBackend();
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(code: 'c-1'),
      client: client,
    );
    expect(result, isNotNull);
    expect(result!.apiKey.raw, startsWith('sk-aiin-'));
    expect(result.apiKey.prefix, 'sk-aiin-abc12345');
    expect(result.email, 'user@aiin.by');
    expect(result.tokens.refreshToken, isNotEmpty);
    expect(statuses, contains('browser opened; sign in on the AIIN page'));
    expect(statussJoined(statuses), isNot(contains('sk-aiin-')));
  });

  test('the browser receives the hosted /login URL with our redirect and '
      'state embedded', () async {
    final client = mockAiinBackend();
    var loginUrl = '';
    await runAiinConnectCliFlow(
      onStatus: (_) {},
      openBrowserFn: (url) async {
        loginUrl = url;
        return fakeBrowser(code: 'c-1')(url);
      },
      client: client,
    );
    final uri = Uri.parse(loginUrl);
    expect(uri.host, 'auth.aiin.by');
    expect(uri.path, '/login');
    expect(uri.queryParameters['client_type'], 'desktop');
    expect(uri.queryParameters['environment'], 'prod');
    expect(
      uri.queryParameters['client_redirect_uri']!,
      startsWith('http://127.0.0.1:'),
    );
    // A fresh one-time CSRF state rides along.
    expect(uri.queryParameters['state']!.length, greaterThanOrEqualTo(32));
  });

  test('no browser: the URL is printed and the flow still completes',
      () async {
    final client = mockAiinBackend();
    final statuses = <String>[];
    final browser = fakeBrowser(code: 'c-1');
    final result = await runAiinConnectCliFlow(
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
    final client = mockAiinBackend();
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(code: 'c-1', stateOverride: 'forged'),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('state mismatch'));
  });

  test('provider error callback surfaces the description', () async {
    final client = mockAiinBackend();
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(
        error: 'access_denied',
        errorDescription: 'user said no',
      ),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('user said no'));
  });

  test('exchange failure reports the setup error', () async {
    final client = mockAiinBackend(exchangeStatus: 500);
    final statuses = <String>[];
    final result = await runAiinConnectCliFlow(
      onStatus: statuses.add,
      openBrowserFn: fakeBrowser(code: 'c-1'),
      client: client,
    );
    expect(result, isNull);
    expect(statussJoined(statuses), contains('AIIN setup failed'));
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
    final target = Uri.parse(redirectUri).replace(
      queryParameters: {'code': 'c-1', 'state': 'st-1'},
    );
    final response = await http.get(target);
    expect(response.statusCode, HttpStatus.ok);
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
