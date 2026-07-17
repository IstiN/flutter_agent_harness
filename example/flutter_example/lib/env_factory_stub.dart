import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'memory_shell.dart';

/// Creates the execution environment for the current platform.
///
/// On web there is no WASM runtime (the vendored `package:wasm_run` bindings
/// import `dart:ffi`, which cannot compile for the browser), so the agent
/// shell is the pure-Dart [MemoryShell] over an in-memory filesystem.
Future<ExecutionEnv> createPlatformEnv({http.Client? httpClient}) async {
  final shell = MemoryShell(httpClient: httpClient);
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  return env;
}

/// `true` when running on a mobile OS that needs the WASM shell sandbox.
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `true` when running on the web.
bool get isWebPlatform => kIsWeb;
