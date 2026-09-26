// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'auth_flow.dart';

/// Web stub for `startOAuthCallbackReceiver` (auth_loopback.dart): the
/// browser sandbox cannot bind a loopback HTTP server, so OAuth sign-in on
/// web surfaces this error until a redirect-based flow lands.
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverImpl() async =>
    throw UnsupportedError(
      'OAuth loopback sign-in requires dart:io (unavailable on web)',
    );

/// Web stub for `openAuthUrl` (auth_loopback.dart).
Future<void> openAuthUrlImpl(Uri authUrl) async => throw UnsupportedError(
  'OAuth loopback sign-in requires dart:io (unavailable on web)',
);
