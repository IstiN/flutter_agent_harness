/// Goldens for the ChatGPT OAuth WebView page (issue #773): the honest
/// failure surface (Contract 4) is real UI — app bar with the loading
/// indicator and the named-error banner. The page renders the shared
/// OAuth/SSO WebView chrome (oauth_webview_scaffold.dart); the webview
/// area itself needs the device plugin, so the registered fake platform
/// renders a placeholder, exactly like the CodeMie page tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:fa/ui/screens/chatgpt_oauth_webview.dart';

import '../fake_webview_platform.dart';
import 'golden_test_helper.dart';

const _authorizeUrl =
    'https://auth.openai.com/oauth/authorize'
    '?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann'
    '&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback'
    '&code_challenge=abc&state=st-1';

void main() {
  setUpAll(ensureGoldenFonts);

  late FakeWebViewPlatform platform;

  setUp(() {
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  /// The page is an iPhone-only surface — phone frame, full screen.
  Future<void> pumpPage(WidgetTester tester) => pumpGolden(
    tester,
    ChatGptOAuthWebViewPage(authorizeUrl: _authorizeUrl, expectedState: 'st-1'),
    size: goldenSizePhone,
    wrap: (child) => child,
    settle: false, // the app-bar loading indicator animates forever
  );

  testWidgets('loading state — app bar with the progress indicator', (
    tester,
  ) async {
    await pumpPage(tester);

    await expectGolden(tester, 'chatgpt_oauth_webview_loading');
  });

  testWidgets('failure state — the named-error banner over the page', (
    tester,
  ) async {
    await pumpPage(tester);
    platform.events.onPageFinished?.call('https://auth.openai.com/log-in');
    platform.events.onWebResourceError?.call(
      const WebResourceError(
        errorCode: -1,
        description: 'net::ERR_CONNECTION_REFUSED',
        isForMainFrame: true,
      ),
    );
    await tester.pump();

    await expectGolden(tester, 'chatgpt_oauth_webview_error');
  });

  testWidgets('Google sign-in block state — the E3 named message', (
    tester,
  ) async {
    platform.controller.bodyText =
        "Couldn't sign you in. This browser or app may not be secure.";
    await pumpPage(tester);
    platform.events.onPageFinished?.call(
      'https://accounts.google.com/o/oauth2/auth',
    );
    await tester.pump();

    await expectGolden(tester, 'chatgpt_oauth_webview_google_block');
  });
}
