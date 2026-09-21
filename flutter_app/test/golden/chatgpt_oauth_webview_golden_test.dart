/// Goldens for the ChatGPT OAuth WebView page (issue #773): the honest
/// failure surface (Contract 4) is real UI — app bar with the loading
/// indicator and the named-error banner. The webview area itself needs the
/// device plugin, so the registered fake platform renders a placeholder,
/// exactly like the CodeMie page tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:fa/ui/screens/chatgpt_oauth_webview.dart';

import 'golden_test_helper.dart';

/// Minimal fake webview platform: a real [WebViewController] builds against
/// it and the captured delegate events let tests drive the page states.
final class _FakeWebViewPlatform extends WebViewPlatform {
  final _FakePlatformWebViewController controller =
      _FakePlatformWebViewController();
  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller;

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(this);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

final class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => '';
}

final class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(this.owner)
    : super.implementation(const PlatformNavigationDelegateCreationParams());

  final _FakeWebViewPlatform owner;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback cb) async {
    owner.onNavigationRequest = cb;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async {
    owner.onPageStarted = cb;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback cb) async {
    owner.onPageFinished = cb;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async {
    owner.onWebResourceError = cb;
  }
}

final class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: const SizedBox.expand(),
  );
}

const _authorizeUrl =
    'https://auth.openai.com/oauth/authorize'
    '?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann'
    '&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback'
    '&code_challenge=abc&state=st-1';

void main() {
  setUpAll(ensureGoldenFonts);

  late _FakeWebViewPlatform platform;

  setUp(() {
    platform = _FakeWebViewPlatform();
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
    platform.onPageFinished?.call('https://auth.openai.com/log-in');
    platform.onWebResourceError?.call(
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
    final blocking = _BlockingPlatform();
    WebViewPlatform.instance = blocking;
    await pumpGolden(
      tester,
      ChatGptOAuthWebViewPage(
        authorizeUrl: _authorizeUrl,
        expectedState: 'st-1',
      ),
      size: goldenSizePhone,
      wrap: (child) => child,
      settle: false,
    );
    blocking.onPageFinished?.call('https://accounts.google.com/o/oauth2/auth');
    await tester.pump();

    await expectGolden(tester, 'chatgpt_oauth_webview_google_block');
  });
}

/// A fake platform whose page body text matches Google's embedded-WebView
/// OAuth block, to drive the E3 banner.
final class _BlockingPlatform extends _FakeWebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _BlockingController();
}

final class _BlockingController extends PlatformWebViewController {
  _BlockingController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      "Couldn't sign you in. This browser or app may not be secure.";
}
