import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:path_provider/path_provider.dart';

import 'wasm_shell.dart';

/// Creates the execution environment for the current platform.
///
/// Desktop keeps the existing [LocalExecutionEnv] with the host shell. Mobile
/// uses a sandboxed host directory and a BusyBox WASM shell so the agent has a
/// working `bash`/`sh` on iOS and Android.
Future<ExecutionEnv> createPlatformEnv() async {
  if (kIsWeb) {
    // Fallback for the unlikely case this file is compiled for web; the stub
    // implementation is preferred via conditional import.
    return MemoryExecutionEnv(cwd: '/');
  }

  final appDir = await getApplicationDocumentsDirectory();
  if (Platform.isAndroid || Platform.isIOS) {
    final sandbox = Directory('${appDir.path}/fah_sandbox');
    await sandbox.create(recursive: true);
    final module = await WasmShell.loadModule();
    final shell = WasmShell(
      module: module,
      workingDirectory: '/',
      sandboxHostPath: sandbox.path,
    );
    return LocalExecutionEnv(cwd: sandbox.path, shell: shell);
  }

  return LocalExecutionEnv(cwd: appDir.path);
}

/// `true` when running on a mobile OS that needs the WASM shell sandbox.
bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// `true` when running on the web.
bool get isWebPlatform => false;
