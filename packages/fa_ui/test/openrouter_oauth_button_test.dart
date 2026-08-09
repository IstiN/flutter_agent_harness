// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_ui/fa_ui.dart';

void main() {
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
  });
}
