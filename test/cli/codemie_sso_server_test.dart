@Tags(['io'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/codemie_sso_server.dart';
import 'package:test/test.dart';

/// Builds a base64-encoded callback `token` carrying [cookies].
String _tokenCookie(Map<String, String> cookies) =>
    base64.encode(utf8.encode(jsonEncode({'cookies': cookies})));

/// A JWT-shaped string whose payload encodes [exp] (seconds epoch).
String _jwt({required int exp}) {
  final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256'})));
  final payload = base64Url.encode(utf8.encode(jsonEncode({'exp': exp})));
  return '$header.$payload.signature';
}

void main() {
  group('CodeMieSsoCallbackServer', () {
    test('completes with the token on a valid callback', () async {
      final server = CodeMieSsoCallbackServer();
      final port = await server.start(timeout: const Duration(seconds: 5));
      expect(port, greaterThan(0));

      final token = _tokenCookie({'codemie_access_token': 'abc'});
      final response = await _httpGet(
        Uri.parse('http://127.0.0.1:$port/?token=$token'),
      );
      final callback = await server.waitForToken();

      expect(response.statusCode, 200);
      expect(response.body, contains('Authorized'));
      expect(callback, token);
      await server.close();
    });

    test('answers 400 when the token is missing', () async {
      final server = CodeMieSsoCallbackServer();
      final port = await server.start(timeout: const Duration(seconds: 5));

      final response = await _httpGet(Uri.parse('http://127.0.0.1:$port/'));

      expect(response.statusCode, 400);
      expect(response.body, contains('Authorization failed'));
      expect(response.body, contains('No token parameter'));
      await server.close();
    });

    test('answers 400 when the token is empty', () async {
      final server = CodeMieSsoCallbackServer();
      final port = await server.start(timeout: const Duration(seconds: 5));

      final response = await _httpGet(
        Uri.parse('http://127.0.0.1:$port/?token='),
      );

      expect(response.statusCode, 400);
      await server.close();
    });

    test('keeps waiting on a tokenless hit (favicon)', () async {
      final server = CodeMieSsoCallbackServer();
      final port = await server.start(timeout: const Duration(seconds: 5));

      await _httpGet(Uri.parse('http://127.0.0.1:$port/favicon.ico'));

      // The completer should NOT have fired — give it a moment to settle.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // waitForToken will hang since no token arrived; verify it's still
      // pending by racing it against a short timeout.
      Object? raceResult;
      try {
        raceResult = await server.waitForToken().timeout(
          const Duration(milliseconds: 50),
        );
      } on TimeoutException {
        raceResult = '__still_waiting__';
      }
      expect(raceResult, '__still_waiting__');
      await server.close();
    });

    test('returns null on timeout', () async {
      final server = CodeMieSsoCallbackServer();
      await server.start(timeout: const Duration(milliseconds: 50));

      final token = await server.waitForToken();
      expect(token, isNull);
      await server.close();
    });
  });

  group('runCodeMieSsoCliFlow', () {
    test('returns credentials on a valid callback', () async {
      final statuses = <String>[];
      final driver = _CodeMieFlowDriver();
      final jwt = _jwt(
        exp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      );
      final token = _tokenCookie({'codemie_access_token': jwt});

      final flowFuture = runCodeMieSsoCliFlow(
        codeMieUrl: 'https://codemie.example.com',
        onStatus: (s) => driver.record(statuses, s),
        openBrowserFn: (_) async => false,
      );

      final response = await driver.hitCallback(token);
      expect(response.statusCode, 200);

      final result = await flowFuture;
      expect(result, isNotNull);
      expect(result!.authToken, contains('codemie_access_token=$jwt'));
      expect(result.apiUrl, contains('code-assistant-api'));
      expect(statuses, contains(contains('listening for the CodeMie SSO')));
      expect(statuses, contains('CodeMie authorized'));
    });

    test('returns null when browser opens successfully', () async {
      final statuses = <String>[];
      final driver = _CodeMieFlowDriver();
      final jwt = _jwt(
        exp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      );
      final token = _tokenCookie({'codemie_access_token': jwt});

      final flowFuture = runCodeMieSsoCliFlow(
        codeMieUrl: 'https://codemie.example.com',
        onStatus: (s) => driver.record(statuses, s),
        openBrowserFn: (_) async => true,
      );

      await driver.hitCallback(token);
      await flowFuture;

      expect(
        statuses,
        contains('browser opened; complete the CodeMie sign-in'),
      );
    });

    test('emits the cannot-open-browser status', () async {
      final statuses = <String>[];
      final driver = _CodeMieFlowDriver();
      final jwt = _jwt(
        exp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      );
      final token = _tokenCookie({'codemie_access_token': jwt});

      final flowFuture = runCodeMieSsoCliFlow(
        codeMieUrl: 'https://codemie.example.com',
        onStatus: (s) => driver.record(statuses, s),
        openBrowserFn: (_) async => false,
      );

      await driver.hitCallback(token);
      await flowFuture;

      expect(
        statuses,
        contains(contains('could not open browser automatically')),
      );
      expect(statuses, contains(contains('open this URL manually:')));
    });

    test(
      'succeeds with non-access-token cookies (cookie-based auth)',
      () async {
        final statuses = <String>[];
        final driver = _CodeMieFlowDriver();
        // A valid base64 JSON with cookies but no codemie_access_token —
        // the new cookie-based auth accepts any cookie set.
        final token = _tokenCookie({'_oauth2_proxy': 'proxy-val'});

        final flowFuture = runCodeMieSsoCliFlow(
          codeMieUrl: 'https://codemie.example.com',
          onStatus: (s) => driver.record(statuses, s),
          openBrowserFn: (_) async => false,
        );

        await driver.hitCallback(token);
        final result = await flowFuture;

        expect(result, isNotNull);
        expect(result!.authToken, contains('_oauth2_proxy=proxy-val'));
      },
    );

    test('returns null on a malformed token', () async {
      final statuses = <String>[];
      final driver = _CodeMieFlowDriver();

      final flowFuture = runCodeMieSsoCliFlow(
        codeMieUrl: 'https://codemie.example.com',
        onStatus: (s) => driver.record(statuses, s),
        openBrowserFn: (_) async => false,
      );

      // Send a raw (non-base64) token that decodeCodeMieSsoToken will reject.
      await driver.hitCallback('!!!not-base64!!!');
      final result = await flowFuture;

      expect(result, isNull);
      expect(statuses, anyElement(contains('CodeMie SSO failed')));
    });
  });
}

/// Tracks the SSO callback URL from `onStatus` lines and drives the HTTP GET.
final class _CodeMieFlowDriver {
  static const _listeningPrefix =
      'listening for the CodeMie SSO callback on port ';

  final _port = Completer<int>();

  void record(List<String> statuses, String status) {
    statuses.add(status);
    if (status.startsWith(_listeningPrefix) && !_port.isCompleted) {
      final portStr = status.substring(_listeningPrefix.length);
      _port.complete(int.parse(portStr));
    }
  }

  Future<_SimpleResponse> hitCallback(String token) async {
    final port = await _port.future.timeout(const Duration(seconds: 5));
    return _httpGet(
      Uri.parse('http://127.0.0.1:$port/?token=${Uri.encodeComponent(token)}'),
    );
  }
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
