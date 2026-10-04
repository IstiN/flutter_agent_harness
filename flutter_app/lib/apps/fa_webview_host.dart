// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// The host's web-view factory for JS-app `webView` nodes (gh-1235), or
/// null where the platform cannot embed web content — Linux/Windows (the
/// plugin has no support there) and web (the core iframe host /
/// placeholder path). The renderer falls back to a placeholder icon when
/// this returns null.
///
/// Deliberately NOT a singleton: every call builds a fresh
/// [FaWebViewHost], and every `webView` node gets its own `InAppWebView`
/// with the DEFAULT data store — cookies, localStorage and the HTTP cache
/// persist and are shared across all openings. No incognito mode.
JsWebViewHost? createFaWebViewHost() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.android ||
    TargetPlatform.macOS => const FaWebViewHost(),
    _ => null,
  };
}

/// VM implementation of [JsWebViewHost] backed by `flutter_inappwebview`
/// (iOS / Android / macOS; every other platform falls back to the
/// renderer's placeholder — see [createFaWebViewHost]).
///
/// JS bridge: the embedded page calls
/// `window.flutter_inappwebview.callHandler('jsr', 'message')`; the string
/// is forwarded to the widget's `onMessage` event as `{value: message}`.
class FaWebViewHost extends JsWebViewHost {
  const FaWebViewHost();

  @override
  Widget buildWebView({
    required String src,
    void Function(String message)? onMessage,
    double? width,
    double? height,
  }) {
    return SizedBox(
      width: width,
      height: height,
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(src)),
        // System default data store (no incognito): cookies, localStorage
        // and the HTTP cache persist and are shared across openings.
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: onMessage != null,
          isInspectable: false,
        ),
        onWebViewCreated: (controller) {
          if (onMessage == null) return;
          controller.addJavaScriptHandler(
            handlerName: 'jsr',
            callback: (args) {
              if (args.isNotEmpty && args.first != null) {
                onMessage(args.first.toString());
              }
            },
          );
        },
      ),
    );
  }
}
