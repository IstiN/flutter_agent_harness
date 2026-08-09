// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:test/test.dart';

import 'package:fa/services/openrouter_oauth_coordinator.dart';

void main() {
  group('OpenRouterOAuthCoordinator', () {
    test('platformCallbackUrl is null on desktop tests', () {
      // Host tests run on macOS/Linux/Windows and must not claim to use a
      // mobile/web callback URL.
      expect(OpenRouterOAuthCoordinator.instance.platformCallbackUrl, isNull);
    });

    test('platformCallbackUrl uses custom scheme and web URL', () {
      final custom = OpenRouterOAuthCoordinator(
        deepLinkScheme: 'yoclip',
        webCallbackUrl: 'https://yoclip.studio/oauth/openrouter.html',
      );
      // On desktop tests the desktop branch still returns null.
      expect(custom.platformCallbackUrl, isNull);
      expect(custom.deepLinkScheme, 'yoclip');
      expect(
        custom.webCallbackUrl,
        'https://yoclip.studio/oauth/openrouter.html',
      );
    });

    test(
      'capture on desktop starts a localhost server and captures the code',
      () async {
        final uri = Uri.parse('https://openrouter.ai/auth?code_challenge=abc');
        final future = OpenRouterOAuthCoordinator.instance.capture(
          uri,
          launchUrl: (_, {required mode}) async => true,
        );

        // Wait for the server to bind.
        while (OpenRouterOAuthCoordinator.instance.currentCallbackUrl == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final callbackUrl =
            OpenRouterOAuthCoordinator.instance.currentCallbackUrl!;
        expect(callbackUrl, startsWith('http://127.0.0.1:'));
        expect(callbackUrl, endsWith('/'));

        // Simulate the OpenRouter redirect.
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('$callbackUrl?code=the-code'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          final body = await response.transform(utf8.decoder).join();
          expect(body, contains('Authorized'));
        } finally {
          client.close();
        }

        final code = await future;
        expect(code, 'the-code');
        expect(OpenRouterOAuthCoordinator.instance.currentCallbackUrl, isNull);
      },
    );

    test('complete fills a mobile/web completer', () async {
      final future = OpenRouterOAuthCoordinator.instance.capture(
        Uri.parse('https://openrouter.ai/auth?code_challenge=abc'),
        launchUrl: (_, {required mode}) async => true,
      );
      OpenRouterOAuthCoordinator.instance.complete('web-code');
      expect(await future, 'web-code');
      // On desktop this leaves a localhost server running until its timeout.
      // Clean it up explicitly.
      await OpenRouterOAuthCoordinator.instance.reset();
    }, skip: !kIsWeb);
  });
}
