import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpStatus;

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
      final redirect = login.queryParameters['client_redirect_uri'] ?? '';
      final expectedState = stateOverride ?? login.queryParameters['state'];
      final target = Uri.parse(redirect)
          .replace(
            queryParameters: {
              'code': ?code,
              'state': expectedState,
              'error': ?error,
              'error_description': ?errorDescription,
            },
          )
          .toString();
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

  test('onCallback fires when the callback lands (the mobile auth-session '
      'sheet dismisses here)', () async {
    var dismissed = false;
    final result = await runAiinConnectCliFlow(
      onStatus: (_) {},
      openBrowserFn: fakeBrowser(code: 'c-1'),
      client: mockAiinBackend(),
      onCallback: () => dismissed = true,
    );
    expect(result, isNotNull);
    expect(dismissed, isTrue);
  });

  test(
    'onCallback also fires on the timeout (a stale sheet closes too)',
    () async {
      var dismissed = false;
      final result = await runAiinConnectCliFlow(
        onStatus: (_) {},
        openBrowserFn: (url) async => true, // opened, never redirected
        client: mockAiinBackend(),
        timeout: const Duration(milliseconds: 100),
        onCallback: () => dismissed = true,
      );
      expect(result, isNull);
      expect(dismissed, isTrue);
    },
  );

  test('an open failure surfaces ahead of the callback timeout', () async {
    // The flow must rethrow the open failure promptly instead of waiting
    // out the (deliberately huge) callback timeout.
    await expectLater(
      runAiinConnectCliFlow(
        onStatus: (_) {},
        openBrowserFn: (url) => throw StateError('no surface'),
        client: mockAiinBackend(),
        timeout: const Duration(minutes: 5), // must NOT be waited out
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('open failure stalled until the callback timeout'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('cancelWhenOpenSettles: the sheet closing without a callback is a '
      'user cancel, not a timeout wait', () async {
    await expectLater(
      runAiinConnectCliFlow(
        onStatus: (_) {},
        openBrowserFn: (url) async => true, // sheet opens...
        // ...and closes by the user without ever redirecting.
        client: mockAiinBackend(),
        timeout: const Duration(minutes: 5), // must NOT be waited out
        cancelWhenOpenSettles: true,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('surface cancel stalled until the callback timeout'),
      ),
      throwsA(isA<AiinSurfaceClosedException>()),
    );
  });

  test('cancelWhenOpenSettles: a landed callback still wins over the '
      'sheet closing', () async {
    final result = await runAiinConnectCliFlow(
      onStatus: (_) {},
      openBrowserFn: fakeBrowser(code: 'c-1'),
      client: mockAiinBackend(),
      cancelWhenOpenSettles: true,
    );
    expect(result, isNotNull);
    expect(result!.apiKey.raw, startsWith('sk-aiin-'));
  });

  test('gh-1044 AC9: the intercepted callback wins the race against the '
      'same-resolution open settle', () async {
    // The mobile wrapper's exact wiring: the intercepted completer is fed
    // from the SAME sheet resolution that resolves `opened`, completed
    // synchronously before the wrapper's `return true`. A Dart async
    // `return` completes its future SYNCHRONOUSLY (VM
    // `_returnAsyncNotFuture` → `_completeWithValue`) while
    // `Completer.complete` defers its listeners to a LATER microtask — an
    // open-settle cancel evaluated in that cascade would always judge the
    // intercepted callback pending and steal the race from a URL sitting
    // in the very next microtask. Regression guard: with an intercepted
    // channel present, the open settle never cancels.
    final intercepted = Completer<String?>();
    final statuses = <String>[];
    final result =
        await runAiinConnectCliFlow(
          onStatus: statuses.add,
          openBrowserFn: (url) async {
            final login = Uri.parse(url);
            final redirect = Uri.parse(
              login.queryParameters['client_redirect_uri']!,
            );
            intercepted.complete(
              redirect
                  .replace(
                    queryParameters: {
                      'code': 'c-1044',
                      'state': login.queryParameters['state']!,
                    },
                  )
                  .toString(),
            );
            return true;
          },
          interceptedCallback: () => intercepted.future,
          cancelWhenOpenSettles: true,
          client: mockAiinBackend(),
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the intercepted callback lost the race'),
        );
    expect(result, isNotNull);
    expect(result!.email, 'user@aiin.by');
    expect(
      statuses,
      contains(
        'AIIN redirect intercepted by the sign-in sheet (callback URL '
        'returned to the flow)',
      ),
    );
  });

  test(
    'gh-1044 AC9: the sheet settling without an intercepted URL is a '
    'user cancel (the intercepted channel is the single cancel signal)',
    () async {
      final intercepted = Completer<String?>();
      await expectLater(
        runAiinConnectCliFlow(
          onStatus: (_) {},
          openBrowserFn: (url) async {
            intercepted.complete(null); // the sheet closed with no callback
            return true;
          },
          interceptedCallback: () => intercepted.future,
          cancelWhenOpenSettles: true,
          client: mockAiinBackend(),
          timeout: const Duration(minutes: 5), // must NOT be waited out
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the intercepted null did not cancel the flow'),
        ),
        throwsA(isA<AiinSurfaceClosedException>()),
      );
    },
  );

  test('gh-1044 AC9: a failing intercepted channel surfaces its error ahead '
      'of the callback timeout (same contract as an open failure)', () async {
    // The intercepted completer is the sheet's single completion
    // channel — when the CHANNEL itself fails (the native call throws,
    // e.g. a PlatformException), the flow must rethrow promptly instead
    // of waiting out the (deliberately huge) callback timeout. The
    // mobile wrapper maps the rethrown error onto its visible-failure
    // contract (AC4).
    final intercepted = Completer<String?>();
    await expectLater(
      runAiinConnectCliFlow(
        onStatus: (_) {},
        openBrowserFn: (url) async {
          intercepted.completeError(StateError('auth channel failed'));
          return true;
        },
        interceptedCallback: () => intercepted.future,
        client: mockAiinBackend(),
        timeout: const Duration(minutes: 5), // must NOT be waited out
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the intercepted-channel error stalled the flow'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('gh-1044 AC9: callbackHost localhost advertises the redirect the '
      'sheet can intercept', () async {
    var loginUrl = '';
    await runAiinConnectCliFlow(
      onStatus: (_) {},
      openBrowserFn: (url) async {
        loginUrl = url;
        return true; // never redirected — the timeout settles the flow
      },
      callbackHost: 'localhost',
      client: mockAiinBackend(),
      timeout: const Duration(milliseconds: 100),
    );
    final redirect = Uri.parse(
      Uri.parse(loginUrl).queryParameters['client_redirect_uri']!,
    );
    expect(redirect.host, 'localhost');
    expect(redirect.scheme, 'http');
  });

  test('the fallback leg also answers on the IPv6 loopback (review: '
      'a localhost redirect may resolve to ::1)', () async {
    final server = AiinCallbackServer();
    final redirectUri = await server.start(timeout: const Duration(seconds: 5));
    final port = Uri.parse(redirectUri).port;
    final callback = server.waitForCallback();
    try {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://[::1]:$port/callback?code=c-v6&state=s'),
      );
      final response = await request.close();
      await response.drain<void>();
      client.close();
    } finally {
      // The server closes itself on the callback; the await below keeps
      // the test honest about the result.
    }
    final result = await callback;
    expect(result?.code, 'c-v6');
  });

  test('AiinCallback.fromRedirectUrl parses the intercepted redirect', () {
    final callback = AiinCallback.fromRedirectUrl(
      'http://localhost:54321/callback?code=c-9&state=s-9',
    );
    expect(callback.code, 'c-9');
    expect(callback.state, 's-9');
    expect(callback.succeeded, isTrue);

    final failed = AiinCallback.fromRedirectUrl(
      'http://localhost:54321/callback?error=access_denied'
      '&error_description=user+denied',
    );
    expect(failed.succeeded, isFalse);
    expect(failed.error, 'access_denied');

    // A non-URL yields an empty, failed callback — never a throw.
    expect(AiinCallback.fromRedirectUrl('not a uri').succeeded, isFalse);
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

  test('no browser: the URL is printed and the flow still completes', () async {
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
    final miss = await http.get(Uri.parse('http://127.0.0.1:$port/other'));
    expect(miss.statusCode, HttpStatus.notFound);
    // The server stays alive for the real callback afterwards.
    final target = Uri.parse(
      redirectUri,
    ).replace(queryParameters: {'code': 'c-1', 'state': 'st-1'});
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
