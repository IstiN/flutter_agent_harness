// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'auth_loopback_stub.dart' if (dart.library.io) 'auth_loopback_io.dart';

import 'auth_flow.dart';

/// Binds the desktop loopback callback receiver for the OAuth sign-in
/// (issue #955 iteration 3). The conditional import keeps `lib/network`
/// web-safe: on web the stub throws [UnsupportedError] (the loopback
/// listener needs `dart:io`).
Future<OAuthCallbackReceiver> startOAuthCallbackReceiver() =>
    startOAuthCallbackReceiverImpl();

/// Opens the provider authorization URL in the system browser.
Future<void> openAuthUrl(Uri authUrl) => openAuthUrlImpl(authUrl);
