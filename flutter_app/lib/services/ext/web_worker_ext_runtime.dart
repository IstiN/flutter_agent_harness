// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web-worker engine for JS extensions: the real `Worker`-based
/// [JsrRuntime] on web builds, an unavailable stub elsewhere.
///
/// Conditional import (same pattern as the app's `web_interpreters`):
/// the web twin is compiled only where `dart.library.html` holds and is
/// never exercised by VM tests — the deterministic suite covers the wiring
/// through [FakeJsrRuntime].
library;

export 'web_worker_ext_runtime_stub.dart'
    if (dart.library.html) 'web_worker_ext_runtime_web.dart';
