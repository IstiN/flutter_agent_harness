// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:test/test.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import 'package:fa/services/openrouter_oauth_coordinator.dart';

void main() {
  group('OpenRouterOAuthCoordinator', () {
    test('platformCallbackUrl matches the host platform', () {
      // Host tests run on macOS/Linux/Windows. Windows/Linux use a localhost
      // server (null here); macOS uses the HTTPS native callback URL.
      final url = OpenRouterOAuthCoordinator.instance.platformCallbackUrl;
      if (Platform.isMacOS) {
        expect(url, 'https://fa1.dev/oauth/openrouter.html?scheme=fah');
      } else {
        expect(url, isNull);
      }
    });

    test('platformCallbackUrl uses custom scheme and web URLs', () {
      final custom = OpenRouterOAuthCoordinator(
        deepLinkScheme: 'yoclip',
        webCallbackUrl: 'https://yoclip.studio/oauth/openrouter.html',
        webAppCallbackUrl: 'https://yoclip.studio/app/index.html',
        nativeCallbackUrl:
            'https://yoclip.studio/oauth/openrouter.html?scheme=yoclip',
      );
      // On desktop tests the desktop branch still returns null for
      // Windows/Linux; macOS gets the native callback URL.
      if (Platform.isMacOS) {
        expect(
          custom.platformCallbackUrl,
          'https://yoclip.studio/oauth/openrouter.html?scheme=yoclip',
        );
      } else {
        expect(custom.platformCallbackUrl, isNull);
      }
      expect(custom.deepLinkScheme, 'yoclip');
      expect(
        custom.webCallbackUrl,
        'https://yoclip.studio/oauth/openrouter.html',
      );
      expect(custom.webAppCallbackUrl, 'https://yoclip.studio/app/index.html');
      expect(
        custom.nativeCallbackUrl,
        'https://yoclip.studio/oauth/openrouter.html?scheme=yoclip',
      );
    });

    test(
      'capture on Windows/Linux starts a localhost server and captures the code',
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
      skip: !Platform.isWindows && !Platform.isLinux,
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

    test(
      'capture on macOS launches the auth URL and waits for a deep link',
      () async {
        final uri = Uri.parse('https://openrouter.ai/auth?code_challenge=abc');
        var launched = false;
        final future = OpenRouterOAuthCoordinator.instance.capture(
          uri,
          launchUrl: (url, {required mode}) async {
            launched = true;
            expect(url.toString(), uri.toString());
            expect(mode, LaunchMode.externalApplication);
            return true;
          },
        );
        // Give the async launch a moment to run.
        await Future<void>.delayed(Duration.zero);
        expect(launched, isTrue);
        expect(OpenRouterOAuthCoordinator.instance.currentCallbackUrl, isNull);
        OpenRouterOAuthCoordinator.instance.complete('deep-link-code');
        expect(await future, 'deep-link-code');
      },
      skip: !Platform.isMacOS,
    );
  });
}
