// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fa/services/openrouter_oauth_callback.dart';

/// Drives one HTTP GET against [url] and returns (status, body).
Future<(int, String)> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body);
  } finally {
    client.close();
  }
}

void main() {
  // The loopback callback server binds real sockets, so every test owns its
  // server and closes it in teardown — no shared state between tests.
  late OpenRouterOAuthCallbackServer server;
  late String url;

  setUp(() async {
    server = OpenRouterOAuthCallbackServer();
    url = await server.start(timeout: const Duration(seconds: 30));
    addTearDown(server.close);
  });

  group('OpenRouterOAuthCallbackServer', () {
    test('start binds loopback and serves the callback URL', () {
      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, endsWith('/'));
      expect(server.callbackUrl, url);
    });

    test('callbackUrl is null before start', () {
      expect(OpenRouterOAuthCallbackServer().callbackUrl, isNull);
    });

    test('waitForCode before start completes with null', () async {
      expect(await OpenRouterOAuthCallbackServer().waitForCode(), isNull);
    });

    test(
      'a code callback completes waitForCode and serves the success page',
      () async {
        final code = server.waitForCode();
        final (status, body) = await _get('$url?code=the-auth-code');

        expect(status, 200);
        expect(body, contains('<title>Authorized</title>'));
        expect(body, contains('You can close this tab'));
        expect(await code, 'the-auth-code');
        // The server closes itself after the code is captured.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(server.callbackUrl, isNull);
      },
    );

    test('an error callback completes with null and names the error', () async {
      final code = server.waitForCode();
      final (status, body) = await _get('$url?error=access_denied');

      expect(status, 200);
      expect(body, contains('<title>Authorization failed</title>'));
      expect(body, contains('access_denied'));
      expect(await code, isNull);
    });

    test('error_description is preferred over the bare error code', () async {
      final code = server.waitForCode();
      final (_, body) = await _get(
        '$url?error=access_denied'
        '&error_description=The+user+denied+the+request',
      );

      expect(body, contains('The user denied the request'));
      expect(body, isNot(contains('>access_denied<')));
      expect(await code, isNull);
    });

    test('an error description is HTML-escaped in the failure page', () async {
      final code = server.waitForCode();
      final (_, body) = await _get(
        '$url?error=x&error_description=%3Cscript%3Ealert(1)%3C%2Fscript%3E',
      );

      expect(body, contains('&lt;script&gt;'));
      expect(body, isNot(contains('<script>')));
      expect(await code, isNull);
    });

    test(
      'a callback with neither code nor error answers 400 with guidance',
      () async {
        final code = server.waitForCode();
        final (status, body) = await _get(url);

        expect(status, 400);
        expect(body, contains('Authorization failed'));
        expect(body, contains('Missing authorization code'));
        // The completer stays pending for the timeout — the miss must not
        // complete the capture with a bogus value.
        expect(
          await code.timeout(
            const Duration(milliseconds: 100),
            onTimeout: () => 'still-pending',
          ),
          'still-pending',
        );
      },
    );

    test(
      'empty-valued params count as missing (empty code is not a code)',
      () async {
        final code = server.waitForCode();
        final (status, _) = await _get('$url?code=&error=');

        expect(status, 400);
        expect(
          await code.timeout(
            const Duration(milliseconds: 100),
            onTimeout: () => 'still-pending',
          ),
          'still-pending',
        );
      },
    );

    test('the timeout completes waitForCode with null and closes', () async {
      final timedOut = OpenRouterOAuthCallbackServer();
      final url2 = await timedOut.start(
        timeout: const Duration(milliseconds: 50),
      );
      final sw = Stopwatch()..start();
      expect(await timedOut.waitForCode(), isNull);
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 40)));
      expect(timedOut.callbackUrl, isNull);
      // The port is released: a bind on the same port succeeds. The
      // server close is async — retry a few times so a slow CI runner
      // does not flake on the kernel still holding the socket.
      final port = Uri.parse(url2).port;
      HttpServer? rebound;
      for (var attempt = 0; attempt < 10 && rebound == null; attempt++) {
        try {
          rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(rebound, isNotNull, reason: 'port $port still held after close');
      await rebound!.close();
    });

    test('starting again rebinds and closes the previous socket', () async {
      final firstPort = Uri.parse(url).port;

      final secondUrl = await server.start();

      expect(Uri.parse(secondUrl).port, isNot(firstPort));
      expect(server.callbackUrl, secondUrl);
      // The first server's port is free again.
      await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        firstPort,
      ).then((s) => s.close());
    });

    test(
      'a code arriving after a captured code does not resurrect the flow',
      () async {
        final code = server.waitForCode();
        await _get('$url?code=first-code');
        expect(await code, 'first-code');

        // A second redirect hits a closed server — the socket fails loudly
        // instead of silently handing out another code.
        await expectLater(
          _get('$url?code=second-code'),
          throwsA(isA<Exception>()),
        );
      },
    );
  });
}
