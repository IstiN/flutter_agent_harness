// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_ui/fa_ui.dart';

/// The url_launcher seam: the button opens the browser through the plugin's
/// method channel, so tests stub it (and record every launch).
const _launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_launcherChannel, null);
  });

  void stubLaunch(WidgetTester tester, bool launched, List<Uri> launchedUrls) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _launcherChannel,
      (call) async {
        expect(call.method, 'launch');
        expect(call.arguments['useWebView'], isNotNull);
        launchedUrls.add(Uri.parse(call.arguments['url'] as String));
        return launched;
      },
    );
  }

  Future<OpenRouterOAuthButton> pumpButton(
    WidgetTester tester, {
    OpenRouterOAuthCaptureCallback? onCapture,
    Future<OpenRouterOAuthKey> Function(
      String code, {
      required String codeVerifier,
    })?
    exchange,
    ValueChanged<String>? onSuccess,
  }) async {
    final button = OpenRouterOAuthButton(
      onCapture: onCapture,
      exchange: exchange,
      onSuccess: onSuccess,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: button)));
    return button;
  }

  group('OpenRouterOAuthButton', () {
    testWidgets(
      'onCapture receives the authorization URL and exchanges the code',
      (tester) async {
        String? captured;
        String? exchangedCode;
        String? successKey;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: OpenRouterOAuthButton(
                callbackUrl: 'https://fa1.dev/oauth/openrouter.html',
                onCapture: (authUrl) async {
                  captured = authUrl.toString();
                  return 'captured-code';
                },
                exchange: (code, {required codeVerifier}) async {
                  exchangedCode = code;
                  return const OpenRouterOAuthKey(key: 'fake-key');
                },
                onSuccess: (key) => successKey = key,
              ),
            ),
          ),
        );

        await tester.tap(find.byType(OpenRouterOAuthButton));
        await tester.pumpAndSettle();

        expect(captured, isNotNull);
        expect(captured, contains('code_challenge='));
        expect(captured, contains('code_challenge_method=S256'));
        expect(
          captured,
          contains(
            'callback_url=https%3A%2F%2Ffa1.dev%2Foauth%2Fopenrouter.html',
          ),
        );
        expect(exchangedCode, 'captured-code');
        expect(successKey, 'fake-key');
      },
    );

    testWidgets('the headless flow opens the browser and pastes the code', (
      tester,
    ) async {
      final launchedUrls = <Uri>[];
      stubLaunch(tester, true, launchedUrls);
      String? exchangedCode;
      String? successKey;

      await pumpButton(
        tester,
        exchange: (code, {required codeVerifier}) async {
          exchangedCode = code;
          return const OpenRouterOAuthKey(key: 'pasted-key');
        },
        onSuccess: (key) => successKey = key,
      );

      await tester.tap(find.byType(OpenRouterOAuthButton));
      await tester.pumpAndSettle();

      // The authorization page opened, then the manual code sheet appeared.
      expect(launchedUrls, hasLength(1));
      expect(
        launchedUrls.single.toString(),
        contains('https://openrouter.ai/'),
      );
      await tester.enterText(find.byType(TextField), 'pasted-code');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(exchangedCode, 'pasted-code');
      expect(successKey, 'pasted-key');
    });

    testWidgets('an empty capture falls back to the browser flow', (
      tester,
    ) async {
      final launchedUrls = <Uri>[];
      stubLaunch(tester, true, launchedUrls);
      String? exchangedCode;

      await pumpButton(
        tester,
        onCapture: (authUrl) async => '',
        exchange: (code, {required codeVerifier}) async {
          exchangedCode = code;
          return const OpenRouterOAuthKey(key: 'k');
        },
      );

      await tester.tap(find.byType(OpenRouterOAuthButton));
      await tester.pumpAndSettle();
      expect(launchedUrls, hasLength(1));

      await tester.enterText(find.byType(TextField), 'late-code');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(exchangedCode, 'late-code');
    });

    testWidgets('a refused browser launch cancels the flow silently', (
      tester,
    ) async {
      final launchedUrls = <Uri>[];
      stubLaunch(tester, false, launchedUrls);
      var exchanged = false;
      String? successKey;

      await pumpButton(
        tester,
        exchange: (code, {required codeVerifier}) async {
          exchanged = true;
          return const OpenRouterOAuthKey(key: 'k');
        },
        onSuccess: (key) => successKey = key,
      );

      await tester.tap(find.byType(OpenRouterOAuthButton));
      await tester.pumpAndSettle();

      expect(launchedUrls, hasLength(1));
      expect(find.text('OpenRouter authorization'), findsNothing);
      expect(exchanged, isFalse);
      expect(successKey, isNull);
    });

    testWidgets('dismissing the code sheet cancels the flow', (tester) async {
      final launchedUrls = <Uri>[];
      stubLaunch(tester, true, launchedUrls);
      var exchanged = false;

      await pumpButton(
        tester,
        exchange: (code, {required codeVerifier}) async {
          exchanged = true;
          return const OpenRouterOAuthKey(key: 'k');
        },
      );

      await tester.tap(find.byType(OpenRouterOAuthButton));
      await tester.pumpAndSettle();
      expect(find.text('OpenRouter authorization'), findsOneWidget);

      // Tap the modal barrier to dismiss; no code, no exchange.
      await tester.tap(find.byType(ModalBarrier).last);
      await tester.pumpAndSettle();
      expect(find.text('OpenRouter authorization'), findsNothing);
      expect(exchanged, isFalse);
    });

    testWidgets('a config exchange failure surfaces the provider message', (
      tester,
    ) async {
      String? successKey;

      await pumpButton(
        tester,
        onCapture: (authUrl) async => 'bad-code',
        exchange: (code, {required codeVerifier}) async =>
            throw const ConfigException('invalid_code: expired'),
        onSuccess: (key) => successKey = key,
      );

      await tester.tap(find.byType(OpenRouterOAuthButton));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'OpenRouter authorization failed: invalid_code: expired',
        ),
        findsOneWidget,
      );
      expect(successKey, isNull);
    });

    testWidgets('an unexpected exchange failure surfaces the error text', (
      tester,
    ) async {
      String? successKey;

      await pumpButton(
        tester,
        onCapture: (authUrl) async => 'odd-code',
        exchange: (code, {required codeVerifier}) async =>
            throw StateError('boom'),
        onSuccess: (key) => successKey = key,
      );

      await tester.tap(find.byType(OpenRouterOAuthButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('Bad state: boom'), findsOneWidget);
      expect(successKey, isNull);
    });
  });
}
