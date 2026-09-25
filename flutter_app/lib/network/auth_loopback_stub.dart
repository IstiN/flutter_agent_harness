// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub for `waitForOAuthCallback` (auth_loopback.dart): the browser
/// sandbox cannot bind a loopback HTTP server, so OAuth sign-in on web
/// surfaces this error until a redirect-based flow lands.
Future<Uri> waitForOAuthCallbackImpl(Uri authUrl) async =>
    throw UnsupportedError(
      'OAuth loopback sign-in requires dart:io (unavailable on web)',
    );
