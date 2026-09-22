// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Minimal fake webview platform shared by the SSO/OAuth WebView page
/// tests and goldens (CodeMie SSO fallback page, ChatGPT sign-in page -
/// issue #773): a real [WebViewController] builds against it, and the
/// delegate events the page registers are captured so tests can fire them
/// like the native WebView would.
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Every event a page's [NavigationDelegate] registers with the platform.
final class CapturedDelegateEvents {
  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;
}

/// The fake platform. [bodyText] is what the controller serves for
/// `runJavaScriptReturningResult` (the ChatGPT Google-block sniff reads
/// the DOM through it).
final class FakeWebViewPlatform extends WebViewPlatform {
  FakeWebViewPlatform({String bodyText = ''})
    : controller = FakePlatformWebViewController(bodyText: bodyText);

  final FakePlatformWebViewController controller;
  final CapturedDelegateEvents events = CapturedDelegateEvents();

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller;

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakePlatformNavigationDelegate(events);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => FakePlatformWebViewWidget(params);
}

final class FakePlatformWebViewController extends PlatformWebViewController {
  FakePlatformWebViewController({this.bodyText = ''})
    : super.implementation(const PlatformWebViewControllerCreationParams());

  JavaScriptMode? javaScriptMode;
  Uri? loadedUri;

  /// Body text served by `runJavaScriptReturningResult`.
  String bodyText;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    javaScriptMode = mode;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUri = params.uri;
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      bodyText;
}

final class FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  FakePlatformNavigationDelegate(this.events)
    : super.implementation(const PlatformNavigationDelegateCreationParams());

  final CapturedDelegateEvents events;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {
    events.onNavigationRequest = callback;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {
    events.onPageStarted = callback;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    events.onPageFinished = callback;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {
    events.onWebResourceError = callback;
  }
}

final class FakePlatformWebViewWidget extends PlatformWebViewWidget {
  FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: const SizedBox.expand(key: Key('fake-webview')),
  );
}

/// Records the page's route at push time so tests can await its
/// [Route.popped] future — the value the page pops with (the flow payload
/// on success, null on cancel/timeout). NavigatorObserver.didPop reports
/// the result unreliably across Flutter versions, but the route's own
/// popped future always carries it.
final class PopRecorder extends NavigatorObserver {
  Route<dynamic>? route;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    this.route = route;
  }
}
