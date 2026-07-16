import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'wasm_shell.dart';

/// Creates the execution environment for the current platform.
///
/// Desktop keeps the existing [LocalExecutionEnv] with the host shell. Mobile
/// uses a sandboxed host directory and a WasiSandboxShell backed by
/// MIT-licensed uutils/ripgrep WASM binaries so the agent has a working shell
/// on iOS and Android.
Future<ExecutionEnv> createPlatformEnv({http.Client? httpClient}) async {
  if (kIsWeb) {
    // Fallback for the unlikely case this file is compiled for web; the stub
    // implementation is preferred via conditional import.
    return MemoryExecutionEnv(cwd: '/');
  }

  final appDir = await getApplicationDocumentsDirectory();
  if (Platform.isAndroid || Platform.isIOS) {
    final sandbox = Directory('${appDir.path}/fah_sandbox');
    await sandbox.create(recursive: true);
    final shell = await WasiSandboxShell.load(
      workingDirectory: '/',
      sandboxHostPath: sandbox.path,
      httpClient: httpClient,
    );
    return LocalExecutionEnv(cwd: sandbox.path, shell: shell);
  }

  return LocalExecutionEnv(cwd: appDir.path);
}

/// `true` when running on a mobile OS that needs the WASM shell sandbox.
bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// `true` when running on the web.
bool get isWebPlatform => false;
