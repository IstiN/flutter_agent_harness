// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:ffi';
import 'dart:io';

import 'package:wasm_run_flutter/wasm_run_flutter.dart';

/// Native platforms: load the wasmtime runtime shipped by wasm_run_flutter.
///
/// On iOS the vendored wasm_run bindings cannot download a dynamic library
/// (they would spawn `uname` and fetch a dylib, neither of which is allowed
/// on iOS). Instead we register the statically linked library directly via
/// [DynamicLibrary.process]. On other platforms we use the standard
/// [WasmRunLibrary.setUp] path.
Future<void> setUpWasmRuntime() async {
  if (Platform.isIOS) {
    // iOS statically links wasm_run into the app binary; DynamicLibrary.process()
    // exposes its symbols to the FFI lookup.
    try {
      WasmRunLibrary.set(DynamicLibrary.process());
    } catch (_) {
      // The static library is not linked; WASM features will be unavailable.
    }
    return;
  }
  await WasmRunLibrary.setUp(override: false);
}
