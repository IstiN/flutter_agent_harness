import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'fs_persistence_stub.dart'
    if (dart.library.html) 'fs_persistence_web.dart';
import 'memory_shell.dart';
import 'persistent_web_env.dart';

/// Creates the execution environment for the current platform.
///
/// On web there is no WASM runtime (the vendored `package:wasm_run` bindings
/// import `dart:ffi`, which cannot compile for the browser), so the agent
/// shell is the pure-Dart [MemoryShell] over an in-memory filesystem. The
/// filesystem is wrapped in a [PersistentWebExecutionEnv] that mirrors every
/// mutation into IndexedDB and restores the last snapshot here — before the
/// `AgentService` is built — so uploaded files (and the agent's own work,
/// including sessions under `/sessions`) survive a page reload.
Future<ExecutionEnv> createPlatformEnv({http.Client? httpClient}) async {
  final shell = MemoryShell(httpClient: httpClient);
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  return PersistentWebExecutionEnv.restore(env, createFsSnapshotStore());
}

/// `true` when running on a mobile OS that needs the WASM shell sandbox.
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `true` when running on Android (the WASM shell sandbox works there).
bool get isAndroidPlatform => defaultTargetPlatform == TargetPlatform.android;

/// `true` when running on iOS (no WASM shell sandbox; shell commands are
/// unavailable).
bool get isIosPlatform => defaultTargetPlatform == TargetPlatform.iOS;

/// `true` when running on the web.
bool get isWebPlatform => kIsWeb;
