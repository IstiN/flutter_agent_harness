// Copyright 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Stub for the published `flutter_inappwebview_linux` federated platform
/// implementation (gh-1265).
///
/// The app never builds a webView host on Linux — `createFaWebViewHost()`
/// in `flutter_app/lib/apps/fa_webview_host.dart` returns null there and the
/// renderer falls back to a placeholder. This package exists purely so the
/// `dependency_overrides` entry in flutter_app/pubspec.yaml can swap the
/// real implementation (whose native CMake hard-requires the WPE WebKit
/// system library, unavailable on Ubuntu 24.04) for nothing: no
/// `flutter: plugin:` section means the Flutter tooling registers no
/// Linux plugin and `flutter build linux` compiles no inappwebview C++.
library;
