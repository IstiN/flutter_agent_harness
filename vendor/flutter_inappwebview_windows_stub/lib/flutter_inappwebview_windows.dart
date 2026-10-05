// Copyright 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Stub for the published `flutter_inappwebview_windows` federated platform
/// implementation (gh-1265).
///
/// The app never builds a webView host on Windows — `createFaWebViewHost()`
/// in `flutter_app/lib/apps/fa_webview_host.dart` returns null there and the
/// renderer falls back to a placeholder. This package exists purely so the
/// `dependency_overrides` entry in flutter_app/pubspec.yaml can swap the
/// real implementation (whose C++17 sources, compiled without /await, pull
/// in <experimental/coroutine> and fail on MSVC 14.51 with C2338 STL1011)
/// for nothing: no `flutter: plugin:` section means the Flutter tooling
/// registers no Windows plugin and `flutter build windows` compiles no
/// inappwebview C++.
library;
