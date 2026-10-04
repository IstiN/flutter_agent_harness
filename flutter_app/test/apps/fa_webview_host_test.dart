// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'package:fa/apps/fa_webview_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// Test platform for `flutter_inappwebview` (the plugin ships no Linux
/// implementation and its factory asserts an [InAppWebViewPlatform] —
/// this fake exists exactly for that, per the plugin's own error message).
/// Only the web-view-widget factory is backed; everything else throws
/// UnimplementedError from the base class.
final class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);
}

final class _FakePlatformWebViewWidget extends PlatformInAppWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => Container();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

/// Recording [JsWebViewHost] — renders a marker text and captures the
/// arguments the renderer passed, so the widget tests stay off the native
/// webview plugin.
final class _FakeWebViewHost extends JsWebViewHost {
  String? lastSrc;
  double? lastWidth;
  double? lastHeight;
  void Function(String message)? lastOnMessage;

  @override
  Widget buildWebView({
    required String src,
    void Function(String message)? onMessage,
    double? width,
    double? height,
  }) {
    lastSrc = src;
    lastWidth = width;
    lastHeight = height;
    lastOnMessage = onMessage;
    return Text('webview:$src');
  }
}

void main() {
  group('FaWebViewHost', () {
    setUpAll(() {
      // No real plugin registers on a Linux test host — the fake is the
      // only platform implementation this isolate ever sees (test files
      // run in their own isolate, so the registration leaks nowhere).
      InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
    });

    test('builds an InAppWebView with the system default data store', () {
      const host = FaWebViewHost();
      final widget = host.buildWebView(
        src: 'https://example.com',
        onMessage: (_) {},
        width: 200,
        height: 100,
      ) as SizedBox;

      expect(widget.width, 200);
      expect(widget.height, 100);
      final webView = widget.child! as InAppWebView;
      final params = webView.platform.params;
      expect(params.initialUrlRequest?.url, WebUri('https://example.com'));
      // JS bridge needs JavaScript; the system default data store keeps
      // cookies/localStorage/cache across openings (never incognito).
      expect(params.initialSettings?.javaScriptEnabled, isTrue);
      expect(params.initialSettings?.incognito, isFalse);
    });

    test('leaves JavaScript off without an onMessage handler', () {
      const host = FaWebViewHost();
      final widget = host.buildWebView(src: 'https://example.com') as SizedBox;
      final webView = widget.child! as InAppWebView;
      expect(webView.platform.params.initialSettings?.javaScriptEnabled, isFalse);
    });

    test('createFaWebViewHost is null on platforms the plugin does not serve', () {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        expect(createFaWebViewHost(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = previous;
      }
    });
  });

  group('webView node rendering (JsonWidgetRenderer)', () {
    Future<void> pumpNode(
      WidgetTester tester,
      Map<String, dynamic> node,
      _FakeWebViewHost host,
    ) async {
      final renderer = JsonWidgetRenderer(
        webViewHost: host,
        onEvent: (actionId, payload) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => renderer.build(node, context),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders the node through the webView host', (tester) async {
      final host = _FakeWebViewHost();
      await pumpNode(tester, const {
        'type': 'webView',
        'src': 'https://example.com',
        'width': 320.0,
        'height': 240.0,
      }, host);

      expect(find.text('webview:https://example.com'), findsOneWidget);
      expect(host.lastSrc, 'https://example.com');
      expect(host.lastWidth, 320);
      expect(host.lastHeight, 240);
      expect(host.lastOnMessage, isNull);
    });

    testWidgets('routes page messages to onEvent as {value: msg}', (
      tester,
    ) async {
      final host = _FakeWebViewHost();
      String? actionId;
      Map<String, dynamic>? payload;
      final renderer = JsonWidgetRenderer(
        webViewHost: host,
        onEvent: (id, p) {
          actionId = id;
          payload = p;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => renderer.build(const {
                'type': 'webView',
                'src': 'https://example.com',
                'onMessage': 'page.message',
              }, context),
            ),
          ),
        ),
      );
      await tester.pump();

      // The page bridge: window.flutter_inappwebview.callHandler('jsr', msg)
      // fires the node's onMessage — the renderer forwards it as an event.
      expect(host.lastOnMessage, isNotNull);
      host.lastOnMessage!('hello from page');
      expect(actionId, 'page.message');
      expect(payload, {'value': 'hello from page'});
    });

    testWidgets('renders the placeholder when no host is wired', (tester) async {
      final renderer = JsonWidgetRenderer(
        onEvent: (actionId, payload) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => renderer.build(const {
                'type': 'webView',
                'src': 'https://example.com',
                'label': 'Web page',
              }, context),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Web page'), findsOneWidget);
      expect(find.byIcon(Icons.language), findsOneWidget);
    });
  });
}
