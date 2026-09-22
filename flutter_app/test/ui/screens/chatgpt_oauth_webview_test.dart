// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:fa/ui/screens/chatgpt_oauth_webview.dart';

import '../../fake_webview_platform.dart';

const _authorizeUrl =
    'https://auth.openai.com/oauth/authorize'
    '?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann'
    '&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback'
    '&code_challenge=abc&state=st-1';
const _expectedState = 'st-1';

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
            builder: (_) => ChatGptOAuthWebViewPage(
              authorizeUrl: _authorizeUrl,
              expectedState: _expectedState,
              timeout: timeout,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return recorder;
  }

  group('chatGptNavigationDecision (issue #773 AC1)', () {
    test('a localhost callback with code + matching state is intercepted', () {
      String? code;
      String? error;
      final decision = chatGptNavigationDecision(
        'http://localhost:1455/auth/callback?code=c-1&state=$_expectedState',
        expectedState: _expectedState,
        onCode: (c) => code = c,
        onError: (e) => error = e,
      );

      expect(decision, NavigationDecision.prevent);
      expect(code, 'c-1');
      expect(error, isNull);
    });

    test('the 127.0.0.1 loopback form is intercepted too', () {
      String? code;
      final decision = chatGptNavigationDecision(
        'http://127.0.0.1:1455/auth/callback?code=c-2&state=$_expectedState',
        expectedState: _expectedState,
        onCode: (c) => code = c,
      );

      expect(decision, NavigationDecision.prevent);
      expect(code, 'c-2');
    });

    test('a state mismatch names the error and never navigates', () {
      String? code;
      String? error;
      final decision = chatGptNavigationDecision(
        'http://localhost:1455/auth/callback?code=c-3&state=other-session',
        expectedState: _expectedState,
        onCode: (c) => code = c,
        onError: (e) => error = e,
      );

      expect(decision, NavigationDecision.prevent);
      expect(code, isNull);
      expect(error, contains('state mismatch'));
    });

    test('an OAuth error param names the error and its description', () {
      String? code;
      String? error;
      final decision = chatGptNavigationDecision(
        'http://localhost:1455/auth/callback'
        '?error=access_denied&error_description=User+denied',
        expectedState: _expectedState,
        onCode: (c) => code = c,
        onError: (e) => error = e,
      );

      expect(decision, NavigationDecision.prevent);
      expect(code, isNull);
      expect(error, contains('access_denied'));
      expect(error, contains('User denied'));
    });

    test('a non-loopback URL navigates normally', () {
      final decision = chatGptNavigationDecision(
        'https://auth.openai.com/log-in',
        expectedState: _expectedState,
      );

      expect(decision, NavigationDecision.navigate);
    });

    test('a loopback URL on another path navigates normally', () {
      final decision = chatGptNavigationDecision(
        'http://localhost:1455/other',
        expectedState: _expectedState,
      );

      expect(decision, NavigationDecision.navigate);
    });

    test('a partial callback (no code, no error) navigates normally', () {
      var armed = false;
      final decision = chatGptNavigationDecision(
        'http://localhost:1455/auth/callback?state=$_expectedState',
        expectedState: _expectedState,
        onCode: (_) => armed = true,
      );

      expect(decision, NavigationDecision.navigate);
      expect(armed, isFalse);
    });

    test('an unparseable URL navigates (never crashes the delegate)', () {
      final decision = chatGptNavigationDecision(
        'http://%', // percent-encoding garbage: Uri.tryParse fails
        expectedState: _expectedState,
      );

      expect(decision, NavigationDecision.navigate);
    });
  });

  group('chatGptGoogleBlockMessage (issue #773 E3)', () {
    test('Google block pages surface the named actionable message', () {
      expect(
        chatGptGoogleBlockMessage(
          'Couldn\'t sign you in — This browser or app may not be secure.',
        ),
        contains('Google blocks sign-in inside the in-app browser'),
      );
      expect(
        chatGptGoogleBlockMessage('Error 403: disallowed_useragent'),
        isNotNull,
      );
    });

    test('ordinary pages (including the OpenAI login) stay silent', () {
      expect(
        chatGptGoogleBlockMessage('Sign in to ChatGPT\nEmail address'),
        isNull,
      );
      expect(chatGptGoogleBlockMessage(''), isNull);
    });
  });

  group('ChatGptOAuthWebViewPage (issue #773)', () {
    testWidgets('loads the authorize URL with JS on and shows the title', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(platform.controller.loadedUri.toString(), _authorizeUrl);
      expect(platform.controller.javaScriptMode, JavaScriptMode.unrestricted);
      expect(find.byKey(const Key('fake-webview')), findsOneWidget);
      expect(find.text('ChatGPT Sign In'), findsOneWidget);
    });

    testWidgets('page start/finish drive the app-bar progress indicator', (
      tester,
    ) async {
      await pumpPage(tester);

      platform.events.onPageStarted?.call('https://auth.openai.com/log-in');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      platform.events.onPageFinished?.call('https://auth.openai.com/log-in');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a matching callback pops the authorization code', (
      tester,
    ) async {
      final recorder = await pumpPage(tester);

      await platform.events.onNavigationRequest!(
        NavigationRequest(
          url:
              'http://localhost:1455/auth/callback'
              '?code=c-9&state=$_expectedState',
          isMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(await recorder.route!.popped, 'c-9');
    });

    testWidgets('a state mismatch shows the banner, stays open, and a good '
        'redirect still pops (re-arm)', (tester) async {
      final recorder = await pumpPage(tester);
      final popped = Completer<Object?>();
      recorder.route!.popped.then(popped.complete);

      await platform.events.onNavigationRequest!(
        NavigationRequest(
          url: 'http://localhost:1455/auth/callback?code=c-x&state=stale',
          isMainFrame: true,
        ),
      );
      await tester.pump();

      expect(find.textContaining('state mismatch'), findsOneWidget);
      expect(popped.isCompleted, isFalse);

      await platform.events.onNavigationRequest!(
        NavigationRequest(
          url:
              'http://localhost:1455/auth/callback'
              '?code=c-good&state=$_expectedState',
          isMainFrame: true,
        ),
      );
      expect(await popped.future, 'c-good');
    });

    testWidgets('a fresh page navigation clears the stale banner (re-arm)', (
      tester,
    ) async {
      await pumpPage(tester);

      platform.events.onWebResourceError?.call(
        const WebResourceError(
          errorCode: -1,
          description: 'net::ERR_DEAD',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(find.textContaining('ERR_DEAD'), findsOneWidget);

      // A new page start (a retry navigation) re-arms the flow: the old
      // error must not sit over the next page.
      platform.events.onPageStarted?.call('https://auth.openai.com/log-in');
      await tester.pump();
      expect(find.textContaining('ERR_DEAD'), findsNothing);
    });

    testWidgets('an OAuth error redirect shows the named banner', (
      tester,
    ) async {
      final recorder = await pumpPage(tester);

      await platform.events.onNavigationRequest!(
        const NavigationRequest(
          url:
              'http://localhost:1455/auth/callback'
              '?error=access_denied&error_description=User+denied',
          isMainFrame: true,
        ),
      );
      await tester.pump();

      expect(find.textContaining('access_denied'), findsOneWidget);
      expect(find.textContaining('User denied'), findsOneWidget);
      expect(recorder.route!.isActive, isTrue);
    });

    testWidgets('the Google embedded-WebView block (E3) surfaces the named '
        'message instead of a silent wall', (tester) async {
      await pumpPage(tester);
      platform.controller.bodyText =
          'Couldn\'t sign you in. This browser or app may not be secure.';

      platform.events.onPageFinished?.call(
        'https://accounts.google.com/o/oauth2/auth',
      );
      await tester.pump();

      expect(
        find.textContaining('Google blocks sign-in inside the in-app browser'),
        findsOneWidget,
      );
    });

    testWidgets('a benign page finish raises no banner', (tester) async {
      await pumpPage(tester);
      platform.controller.bodyText = 'Sign in to ChatGPT';

      platform.events.onPageFinished?.call('https://auth.openai.com/log-in');
      await tester.pump();

      expect(find.textContaining('Google blocks'), findsNothing);
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

    testWidgets('the timeout pops the page with null (E4 honesty)', (
      tester,
    ) async {
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
      platform.events.onPageStarted?.call('https://auth.openai.com/');
      platform.events.onPageFinished?.call('https://auth.openai.com/');
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
