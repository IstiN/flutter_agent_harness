// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'auth_flow.dart';

/// Fallback for platforms with neither `dart:io` nor browser callbacks.
/// Web selects `auth_loopback_web.dart`; native selects
/// `auth_loopback_io.dart`.
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverImpl() async =>
    throw UnsupportedError('OAuth sign-in is unavailable on this platform');

/// Fallback opener for the same unsupported platforms.
Future<void> openAuthUrlImpl(Uri authUrl) async =>
    throw UnsupportedError('OAuth sign-in is unavailable on this platform');
