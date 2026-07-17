// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web: no WASM runtime is available (the vendored wasm_run bindings import
/// dart:ffi, which cannot compile for the browser), so setup is a no-op.
Future<void> setUpWasmRuntime() async {}
