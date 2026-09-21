// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, kIsWeb;
import 'package:test/test.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import 'package:fa/services/openrouter_oauth_coordinator.dart';

void main() {
  group('OpenRouterOAuthCoordinator', () {
    test('platformCallbackUrl returns the deep link on Android', () {
      // flutter test pins defaultTargetPlatform to android — the native
      // Android path goes through the registered deep-link scheme.
      expect(
        OpenRouterOAuthCoordinator.instance.platformCallbackUrl,
        'fah://oauth/openrouter',
      );
    });

    test('platformCallbackUrl uses custom scheme and web URLs', () {
      final custom = OpenRouterOAuthCoordinator(
        deepLinkScheme: 'yoclip',
        webCallbackUrl: 'https://yoclip.studio/oauth/openrouter.html',
        webAppCallbackUrl: 'https://yoclip.studio/app/index.html',
        nativeCallbackUrl: 'https://yoclip.studio/oauth/openrouter-native.html',
      );
      expect(custom.platformCallbackUrl, 'yoclip://oauth/openrouter');
      expect(custom.deepLinkScheme, 'yoclip');
      expect(
        custom.webCallbackUrl,
        'https://yoclip.studio/oauth/openrouter.html',
      );
      expect(custom.webAppCallbackUrl, 'https://yoclip.studio/app/index.html');
      expect(
        custom.nativeCallbackUrl,
        'https://yoclip.studio/oauth/openrouter-native.html',
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

    group('capture with an injected desktop decision (issue #702)', () {
      // The physical-platform check reads the real build host, so these
      // drive the Windows/Linux localhost-server flow through the
      // injectable predicate instead — on any OS.
      final uri = Uri.parse(
        'https://openrouter.ai/auth?code_challenge=abc&state=st',
      );

      test(
        'the desktop flow rewrites callback_url to the local server',
        () async {
          Uri? launchedUrl;
          final future = OpenRouterOAuthCoordinator.instance.capture(
            uri,
            usesLocalServerCapture: () => true,
            launchUrl: (url, {required mode}) async {
              launchedUrl = url;
              return true;
            },
          );

          while (OpenRouterOAuthCoordinator.instance.currentCallbackUrl ==
              null) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          final callbackUrl =
              OpenRouterOAuthCoordinator.instance.currentCallbackUrl!;

          // The browser sees the server URL as callback_url; every other
          // query parameter survives the rewrite.
          expect(launchedUrl!.queryParameters['callback_url'], callbackUrl);
          expect(launchedUrl!.queryParameters['code_challenge'], 'abc');
          expect(launchedUrl!.queryParameters['state'], 'st');

          final client = HttpClient();
          try {
            final request = await client.get(
              '127.0.0.1',
              Uri.parse(callbackUrl).port,
              '/?code=desktop-code',
            );
            final response = await request.close();
            expect(response.statusCode, 200);
          } finally {
            client.close();
          }

          expect(await future, 'desktop-code');
          expect(
            OpenRouterOAuthCoordinator.instance.currentCallbackUrl,
            isNull,
          );
        },
      );

      test(
        'a failed browser launch completes with null (documented)',
        () async {
          final code = await OpenRouterOAuthCoordinator.instance.capture(
            uri,
            usesLocalServerCapture: () => true,
            launchUrl: (_, {required mode}) async => false,
          );

          expect(code, isNull);
          // No localhost server is left bound after the failed launch.
          expect(
            OpenRouterOAuthCoordinator.instance.currentCallbackUrl,
            isNull,
          );
        },
      );

      test(
        'a failed deep-link-platform launch completes with null too',
        () async {
          final code = await OpenRouterOAuthCoordinator.instance.capture(
            uri,
            usesLocalServerCapture: () => false,
            launchUrl: (_, {required mode}) async => false,
          );

          expect(code, isNull);
        },
      );

      test('the default decision follows the physical platform', () {
        // On the test host this is a constant; the assertion pins it to
        // the dart:io check so an accidental change of the default (e.g.
        // to a target-platform lookup) cannot slip through unnoticed.
        expect(
          OpenRouterOAuthCoordinator.defaultUsesLocalServerCapture(),
          Platform.isWindows || Platform.isLinux,
        );
      });
    });

    test('platformCallbackUrl dispatches per platform', () {
      final coordinator = OpenRouterOAuthCoordinator(
        deepLinkScheme: 'yoclip',
        webCallbackUrl: 'https://yoclip.studio/oauth/openrouter.html',
        webAppCallbackUrl: 'https://yoclip.studio/app/index.html',
        nativeCallbackUrl: 'https://yoclip.studio/oauth/openrouter-native.html',
      );
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      String? nativeFor(TargetPlatform platform) {
        debugDefaultTargetPlatformOverride = platform;
        return coordinator.platformCallbackUrl;
      }

      // Windows/Linux start a lazy localhost server — no URL up front.
      expect(nativeFor(TargetPlatform.windows), isNull);
      expect(nativeFor(TargetPlatform.linux), isNull);
      // iOS/macOS return through the native HTTPS page, Android via the
      // registered deep-link scheme.
      expect(
        nativeFor(TargetPlatform.iOS),
        'https://yoclip.studio/oauth/openrouter-native.html',
      );
      expect(
        nativeFor(TargetPlatform.macOS),
        'https://yoclip.studio/oauth/openrouter-native.html',
      );
      expect(nativeFor(TargetPlatform.android), 'yoclip://oauth/openrouter');
      debugDefaultTargetPlatformOverride = null;
    });

    test('web callback URLs split mobile web from desktop web', () {
      final coordinator = OpenRouterOAuthCoordinator(
        deepLinkScheme: 'yoclip',
        webCallbackUrl: 'https://yoclip.studio/oauth/openrouter.html',
        webAppCallbackUrl: 'https://yoclip.studio/app/index.html',
      );
      // Mobile Safari/PWA cannot postMessage back — those return to the
      // app URL and read the code from the query string on startup.
      expect(
        coordinator.webCallbackUrlFor(TargetPlatform.iOS),
        'https://yoclip.studio/app/index.html',
      );
      expect(
        coordinator.webCallbackUrlFor(TargetPlatform.android),
        'https://yoclip.studio/app/index.html',
      );
      // Desktop web posts the code back from the popup page.
      expect(
        coordinator.webCallbackUrlFor(TargetPlatform.macOS),
        'https://yoclip.studio/oauth/openrouter.html',
      );
    });
  });
}
