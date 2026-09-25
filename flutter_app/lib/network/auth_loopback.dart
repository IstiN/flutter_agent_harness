// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'auth_loopback_stub.dart' if (dart.library.io) 'auth_loopback_io.dart';

/// Waits for the OAuth browser callback on the desktop loopback listener
/// (issue #955 iteration 3): binds an ephemeral `127.0.0.1` port, opens
/// [authUrl] in the system browser, and resolves with the
/// `/callback?code&state` URI (or throws on timeout).
///
/// The conditional import keeps `lib/network` web-safe: on web the stub
/// throws [UnsupportedError] (the loopback listener needs `dart:io`).
Future<Uri> waitForOAuthCallback(Uri authUrl) =>
    waitForOAuthCallbackImpl(authUrl);
