// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export: the real `flutter_gemma`-backed engine on IO
/// platforms (iOS/Android via FFI) and on web (`@litert-lm/core` — the
/// plugin API is platform-uniform and wasm-clean, so one implementation
/// covers both); the unavailable stub remains for desktop builds (same
/// pattern as `secrets_store.dart` in this app).
library;

export 'gemma_service_stub.dart'
    if (dart.library.io) 'gemma_service_plugin.dart'
    if (dart.library.js_interop) 'gemma_service_plugin.dart';
