// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.
//
/// Host entry for the AC7 chat mini-test (issue #1156): the SAME probe body
/// the simulator lane runs (`integration_test/sandbox_agent_chat_test.dart`)
/// against the real `WasiSandboxShell` (wasm_run dylib) inside the app's
/// mobile-sandbox env factory. Proves the agent loop, MockLlmServer wiring,
/// and the tool-result round-trip without a simulator; the simulator lane
/// additionally proves the statically linked wasm_run runtime.
///
/// Requires the wasm_run native library (see WASM_RUN_DART_DYNAMIC_LIBRARY
/// or `.dart_tool/wasm_run/`); without it the test SKIPs with a loud
/// reason — the simulator lane is the gate there.
library;

import 'dart:io';

import 'package:fa/sandbox/env_factory_io.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wasm_run_flutter/wasm_run_flutter.dart';

import '../integration_test/e2e_support/sandbox_agent_chat_probe.dart';

void main() {
  String? skipReason;
  try {
    WasmRunFlutterNative.registerWith();
  } on Object catch (error) {
    skipReason = 'wasm_run runtime unavailable: $error';
  }
  if (skipReason == null && !WasmRunLibrary.isReachable()) {
    skipReason =
        'wasm_run native library not reachable; set '
        'WASM_RUN_DART_DYNAMIC_LIBRARY or run `dart run wasm_run:setup`';
  }

  testWidgets('chat loop drives the sandbox shell via the bash tool', (
    tester,
  ) async {
    // The app's env factory asks path_provider for the documents directory;
    // flutter_tester has no plugin host, so answer with a temp dir.
    final docsDir = await Directory.systemTemp.createTemp('fah_chat_sandbox_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getApplicationDocumentsPath' => docsDir.path,
        'getApplicationSupportPath' => docsDir.path,
        _ => null,
      },
    );

    // The curl builtin's client must exist before the binding's
    // HttpOverrides.global swap (same ordering as the probe suite host test).
    final httpClient = http.Client();
    final env = await createMobileSandboxEnv(
      httpClient: httpClient,
      loadShell: () => WasiSandboxShell.load(
        workingDirectory: '/',
        sandboxHostPath: '${docsDir.path}/fah_sandbox',
        httpClient: httpClient,
      ),
    );

    await sandboxAgentChatProbe(tester, env: env);
  }, skip: skipReason != null);
  if (skipReason != null) {
    // ignore: avoid_print
    print('SKIP REASON: $skipReason');
  }
}
