// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO/mobile build of the default engine factory: one flutter_js runtime per
/// extension (IO-only — `package:flutter_js` needs dart:io/dart:ffi).
library;

import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';

import 'flutter_js_ext_runtime.dart';

/// Creates a [FlutterJsExtRuntime] for [ext]; throws
/// [ExtEngineUnavailableException] where the flutter_js binding cannot load.
JsrRuntime Function(StoredExtension ext) get defaultJsrRuntimeFactory =>
    (ext) => FlutterJsExtRuntime();
