// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export: the real engine on the web, the unavailable stub
/// everywhere else (same pattern as `webllm_service.dart` in this app).
library;

export 'transformers_js_service_stub.dart'
    if (dart.library.html) 'transformers_js_service_web.dart';
