// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'auth_loopback_stub.dart'
    if (dart.library.io) 'auth_loopback_io.dart'
    if (dart.library.html) 'auth_loopback_web.dart';

import 'auth_flow.dart';

/// Binds the platform callback receiver for OAuth sign-in: an RFC 8252
/// loopback on desktop, a deep link on mobile, or a popup plus origin
/// callback on web. The conditional import keeps `lib/network` web-safe.
Future<OAuthCallbackReceiver> startOAuthCallbackReceiver() =>
    startOAuthCallbackReceiverImpl();

/// Opens the provider authorization URL in the system browser.
Future<void> openAuthUrl(Uri authUrl) => openAuthUrlImpl(authUrl);
