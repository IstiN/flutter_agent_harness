// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:wasm_run_flutter/wasm_run_flutter.dart';

/// Native platforms: load the wasmtime runtime shipped by wasm_run_flutter.
///
/// On iOS this is a no-op: the vendored wasm_run bindings assume a desktop
/// environment where they can spawn `uname` and download a dynamic library,
/// neither of which is allowed on iOS. The wasm shell is therefore unavailable
/// on iOS, but the rest of the app (chat UI, on-device LLM providers, etc.)
/// still works.
Future<void> setUpWasmRuntime() async {
  if (Platform.isIOS) {
    return;
  }
  await WasmRunLibrary.setUp(override: false);
}
