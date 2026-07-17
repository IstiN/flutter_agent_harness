// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:wasm_run_flutter/wasm_run_flutter.dart';

/// Native platforms: load the wasmtime runtime shipped by wasm_run_flutter.
Future<void> setUpWasmRuntime() => WasmRunLibrary.setUp(override: false);
