@Tags(['io'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/chatgpt_oauth_server.dart';
import 'package:flutter_agent_harness/src/providers/chatgpt_oauth.dart';
import 'package:test/test.dart';

void main() {
  group('ChatGptOAuthLocalCallbackServer', () {
    test('completes with code and state on the callback', () async {
      final server = ChatGptOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 5));
      expect(url, startsWith('http://localhost:'));
      expect(url, endsWith('/auth/callback'));

      final uri = Uri.parse(
        url,
      ).replace(queryParameters: {'code': 'abc', 'state': 'xyz'});
      final requestFuture = _httpGet(uri);
      final callbackFuture = server.waitForCallback();
      final response = await requestFuture;
      final callback = await callbackFuture;

      expect(response.statusCode, 200);
      expect(response.body, contains('Authorized'));
      expect(callback, isNotNull);
      expect(callback!.code, 'abc');
      expect(callback.state, 'xyz');
      await server.close();
    });

    test('answers 400 with the error page when the code is missing', () async {
      final server = ChatGptOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 5));

      final requestFuture = _httpGet(Uri.parse(url));
      final callbackFuture = server.waitForCallback();
      final response = await requestFuture;
      final callback = await callbackFuture;

      expect(response.statusCode, 400);
      expect(response.body, contains('Authorization failed'));
      expect(response.body, contains('No authorization code received'));
      expect(callback, isNotNull);
      expect(callback!.code, isNull);
      await server.close();
    });

    test('answers 400 with the provider error description', () async {
      final server = ChatGptOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 5));

      final uri = Uri.parse(url).replace(
        queryParameters: {
          'error': 'access_denied',
          'error_description': 'user denied <the> consent',
        },
      );
      final response = await _httpGet(uri);

      expect(response.statusCode, 400);
      expect(response.body, contains('Authorization failed'));
      expect(response.body, contains('user denied &lt;the&gt; consent'));
      await server.close();
    });

    test('answers 404 for other paths', () async {
      final server = ChatGptOAuthLocalCallbackServer();
      final url = await server.start(timeout: const Duration(seconds: 5));

      final base = Uri.parse(url);
      final response = await _httpGet(base.replace(path: '/other'));
      expect(response.statusCode, 404);
      await server.close();
    });

    test('throws when both callback ports are occupied', () async {
      HttpServer first;
      try {
        first = await HttpServer.bind(InternetAddress.loopbackIPv4, 1455);
      } on Object {
        // Port busy in this environment; nothing meaningful to test.
        return;
      }
      HttpServer second;
      try {
        second = await HttpServer.bind(InternetAddress.loopbackIPv4, 1457);
      } on Object {
        await first.close();
        return;
      }
      final server = ChatGptOAuthLocalCallbackServer();
      await expectLater(server.start(), throwsStateError);
      await first.close();
      await second.close();
    });
  });

  group('runChatGptOAuthCliFlow', () {
    test('returns the exchanged credentials on a valid callback', () async {
      final statuses = <String>[];
      final driver = _FlowDriver();
      const canned = ChatGptOAuthCredentials(
        accessToken: 'at-canned',
        refreshToken: 'rt-canned',
        idToken: 'it-canned',
      );

      final flowFuture = runChatGptOAuthCliFlow(
        onStatus: (status) => driver.record(statuses, status),
        openBrowserFn: (_) async => false,
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async {
              expect(code, 'flow-code');
              expect(verifier, isNotEmpty);
              return canned;
            },
      );

      final state = await driver.authorizeState();
      final response = await driver.getCallback({
        'code': 'flow-code',
        'state': state,
      });
      expect(response.statusCode, 200);

      final result = await flowFuture;
      expect(result, same(canned));
      expect(statuses, contains(contains('listening for ChatGPT OAuth')));
      expect(statuses, contains(contains('could not open browser')));
      expect(statuses, contains('ChatGPT authorized'));
    });

    test('returns null on a state mismatch', () async {
      final statuses = <String>[];
      final driver = _FlowDriver();
      var exchangeCalled = false;

      final flowFuture = runChatGptOAuthCliFlow(
        onStatus: (status) => driver.record(statuses, status),
        openBrowserFn: (_) async => true,
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async {
              exchangeCalled = true;
              return const ChatGptOAuthCredentials(
                accessToken: 'a',
                refreshToken: 'r',
                idToken: 'i',
              );
            },
      );

      final response = await driver.getCallback({
        'code': 'flow-code',
        'state': 'not-the-issued-state',
      });
      expect(response.statusCode, 200);

      final result = await flowFuture;
      expect(result, isNull);
      expect(exchangeCalled, isFalse);
      expect(
        statuses,
        contains('browser opened; complete authorization with ChatGPT'),
      );
      expect(statuses, contains('ChatGPT authorization callback was invalid'));
    });

    test('returns null on a provider error callback', () async {
      final statuses = <String>[];
      final driver = _FlowDriver();

      final flowFuture = runChatGptOAuthCliFlow(
        onStatus: (status) => driver.record(statuses, status),
        openBrowserFn: (_) async => false,
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async => throw StateError('must not be called'),
      );

      final response = await driver.getCallback({
        'error': 'access_denied',
        'error_description': 'denied by user',
      });
      expect(response.statusCode, 400);

      final result = await flowFuture;
      expect(result, isNull);
      expect(
        statuses,
        contains('ChatGPT authorization failed: denied by user'),
      );
    });

    test('returns null when no callback arrives before the timeout', () async {
      final statuses = <String>[];

      final result = await runChatGptOAuthCliFlow(
        onStatus: statuses.add,
        openBrowserFn: (_) async => false,
        timeout: const Duration(milliseconds: 50),
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async => throw StateError('must not be called'),
      );

      expect(result, isNull);
      expect(
        statuses,
        contains(contains('no authorization callback received')),
      );
    });

    test('returns null when the token exchange fails', () async {
      final statuses = <String>[];
      final driver = _FlowDriver();

      final flowFuture = runChatGptOAuthCliFlow(
        onStatus: (status) => driver.record(statuses, status),
        openBrowserFn: (_) async => false,
        exchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async => throw StateError('boom'),
      );

      final state = await driver.authorizeState();
      await driver.getCallback({'code': 'flow-code', 'state': state});

      final result = await flowFuture;
      expect(result, isNull);
      expect(statuses, contains(contains('ChatGPT authorization failed: ')));
    });
  });
}

/// Tracks the URLs the flow reports via `onStatus` and drives the callback.
final class _FlowDriver {
  static const _listeningPrefix = 'listening for ChatGPT OAuth callback on ';
  static const _manualPrefix = 'open this URL manually: ';

  final _listening = Completer<String>();
  final _manualUrl = Completer<Uri>();

  void record(List<String> statuses, String status) {
    statuses.add(status);
    if (status.startsWith(_listeningPrefix) && !_listening.isCompleted) {
      _listening.complete(status.substring(_listeningPrefix.length));
    }
    if (status.startsWith(_manualPrefix) && !_manualUrl.isCompleted) {
      _manualUrl.complete(Uri.parse(status.substring(_manualPrefix.length)));
    }
  }

  /// Waits for the manual URL line and returns the issued `state` parameter.
  Future<String> authorizeState() async {
    final authUri = await _manualUrl.future.timeout(const Duration(seconds: 5));
    final state = authUri.queryParameters['state'];
    expect(state, isNotNull);
    return state!;
  }

  Future<_SimpleResponse> getCallback(Map<String, String> query) async {
    final url = await _listening.future.timeout(const Duration(seconds: 5));
    return _httpGet(Uri.parse(url).replace(queryParameters: query));
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
