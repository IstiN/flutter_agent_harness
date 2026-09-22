// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show CodeMieSsoCredentials;

import 'package:fa/ui/screens/codemie_sso_webview.dart';

import '../../fake_webview_platform.dart';

const _orgUrl = 'https://codemie.example.com';

/// The exact SSO URL `_createController` must load (api base + login route
/// with the baked-in dummy callback port).
const _expectedSsoUrl = '$_orgUrl/code-assistant-api/v1/auth/login/48127';

String _token(Map<String, Object?> cookies) =>
    base64.encode(utf8.encode(jsonEncode({'cookies': cookies})));

void main() {
  late FakeWebViewPlatform platform;

  setUp(() {
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  Future<PopRecorder> pumpPage(
    WidgetTester tester, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final recorder = PopRecorder();
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          observers: [recorder],
          onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings,
            builder: (_) =>
                CodeMieSsoWebViewPage(orgUrl: _orgUrl, timeout: timeout),
          ),
        ),
      ),
    );
    await tester.pump();
    return recorder;
  }

  group('CodeMieSsoWebViewPage (issue #702)', () {
    testWidgets('_createController loads the SSO login URL with JS on', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(platform.controller.loadedUri.toString(), _expectedSsoUrl);
      expect(platform.controller.javaScriptMode, JavaScriptMode.unrestricted);
      expect(find.byKey(const Key('fake-webview')), findsOneWidget);
      expect(find.text('CodeMie Sign In'), findsOneWidget);
    });

    testWidgets('page start/finish drive the app-bar progress indicator', (
      tester,
    ) async {
      await pumpPage(tester);

      platform.events.onPageStarted?.call('$_orgUrl/');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      platform.events.onPageFinished?.call('$_orgUrl/');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('main-frame errors surface, sub-frame errors stay silent', (
      tester,
    ) async {
      await pumpPage(tester);

      void fire(bool mainFrame) => platform.events.onWebResourceError?.call(
        WebResourceError(
          errorCode: -1,
          description: 'net::ERR_TUNNEL',
          isForMainFrame: mainFrame,
        ),
      );

      fire(false); // favicon / ad frame noise
      await tester.pump();
      expect(find.textContaining('ERR_TUNNEL'), findsNothing);

      fire(true);
      await tester.pump();
      expect(find.textContaining('net::ERR_TUNNEL'), findsOneWidget);
    });

    testWidgets('the localhost token redirect pops decoded credentials', (
      tester,
    ) async {
      final recorder = await pumpPage(tester);

      final decision = await platform.events.onNavigationRequest!(
        NavigationRequest(
          url:
              'http://localhost:48127/?token='
              '${Uri.encodeQueryComponent(_token({'codemie_access_token': 'jwt-9'}))}',
          isMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(decision, NavigationDecision.prevent);
      final credentials = await recorder.route!.popped;
      expect(credentials, isA<CodeMieSsoCredentials>());
      final typed = credentials as CodeMieSsoCredentials;
      expect(typed.cookies, {'codemie_access_token': 'jwt-9'});
      expect(typed.apiUrl, contains('code-assistant-api'));
    });

    testWidgets('a non-localhost navigation proceeds in the WebView', (
      tester,
    ) async {
      await pumpPage(tester);

      final decision = await platform.events.onNavigationRequest!(
        const NavigationRequest(url: '$_orgUrl/some/path', isMainFrame: true),
      );

      expect(decision, NavigationDecision.navigate);
    });

    testWidgets('an undecodable token shows the failure banner and re-arms', (
      tester,
    ) async {
      final recorder = await pumpPage(tester);
      final popped = Completer<Object?>();
      recorder.route!.popped.then(popped.complete);

      await platform.events.onNavigationRequest!(
        const NavigationRequest(
          url: 'http://localhost:48127/?token=%3Cnot-base64%3E',
          isMainFrame: true,
        ),
      );
      await tester.pump();

      expect(find.textContaining('Failed to decode SSO token'), findsOneWidget);
      expect(popped.isCompleted, isFalse);

      // The flow re-arms: a good token on a later redirect still pops.
      await platform.events.onNavigationRequest!(
        NavigationRequest(
          url:
              'http://localhost:48127/?token='
              '${Uri.encodeQueryComponent(_token({'codemie_access_token': 'jwt-10'}))}',
          isMainFrame: true,
        ),
      );
      final credentials = await popped.future;
      expect(credentials, isA<CodeMieSsoCredentials>());
      expect((credentials as CodeMieSsoCredentials).cookies, {
        'codemie_access_token': 'jwt-10',
      });
    });

    testWidgets('a fresh page navigation clears the stale banner (shared '
        'scaffold re-arm)', (tester) async {
      await pumpPage(tester);

      platform.events.onWebResourceError?.call(
        const WebResourceError(
          errorCode: -1,
          description: 'net::ERR_SSO_DEAD',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(find.textContaining('ERR_SSO_DEAD'), findsOneWidget);

      platform.events.onPageStarted?.call('$_orgUrl/some/retry');
      await tester.pump();
      expect(find.textContaining('ERR_SSO_DEAD'), findsNothing);
    });

    testWidgets('the timeout pops the page with null', (tester) async {
      final recorder = await pumpPage(
        tester,
        timeout: const Duration(milliseconds: 50),
      );

      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      expect(await recorder.route!.popped, isNull);
    });

    testWidgets('delegate events after dispose are ignored, not crashes', (
      tester,
    ) async {
      await pumpPage(tester, timeout: const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      // Replace the page: the old state unmounts, but the platform
      // delegate's captured closures outlive it — their `mounted` guards
      // must turn the events into no-ops instead of setState-after-dispose.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      platform.events.onPageStarted?.call('$_orgUrl/');
      platform.events.onPageFinished?.call('$_orgUrl/');
      platform.events.onWebResourceError?.call(
        const WebResourceError(
          errorCode: -1,
          description: 'late',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
    });
  });
}
