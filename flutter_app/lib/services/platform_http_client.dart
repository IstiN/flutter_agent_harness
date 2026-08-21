// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:http/http.dart' as http;

import 'platform_http_client_stub.dart'
    if (dart.library.io) 'platform_http_client_io.dart';

/// Creates the best HTTP client for the current platform.
///
/// On iOS/macOS this returns a [CupertinoClient] (NSURLSession-backed);
/// elsewhere it returns the standard [http.Client]. The conditional import
/// keeps the web build free of `dart:io` and `cupertino_http` dependencies.
http.Client createPlatformHttpClient() => createPlatformHttpClientImpl();
