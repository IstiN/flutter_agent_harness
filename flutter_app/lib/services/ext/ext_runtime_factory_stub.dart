// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web build of the default engine factory: a [WebWorkerExtRuntime] per
/// extension. On non-web builds the conditional twin resolves to the
/// throwing stub (`web_worker_ext_runtime_stub.dart`).
library;

import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';

import 'web_worker_ext_runtime.dart';

/// Creates a web-worker engine for [ext].
JsrRuntime Function(StoredExtension ext) get defaultJsrRuntimeFactory =>
    (ext) => WebWorkerExtRuntime();
