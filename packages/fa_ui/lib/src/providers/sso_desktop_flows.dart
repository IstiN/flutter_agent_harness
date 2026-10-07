// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Platform selection for the default [FaUiSso] sign-in hops
/// (issue #1321): the real desktop flows bind loopback callback servers
/// through `dart:io`; the web build gets stubs that throw
/// [UnsupportedError] (the connect methods surface a clean
/// "not available on this platform" snack instead).
library;

export 'sso_desktop_flows_stub.dart'
    if (dart.library.io) 'sso_desktop_flows_io.dart';
