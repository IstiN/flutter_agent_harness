// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The iOS/WASI sandbox golden probe suite, HOST entry (issue #1156).
///
/// Runs the SAME probes as `integration_test/sandbox_probe_suite_test.dart`
/// against the same real `WasiSandboxShell` on a macOS/Linux desktop host —
/// the local proof layer for the fidelity fixes. The authoritative gate for
/// the iOS device/simulator specifics remains the AC7 simulator lane; this
/// host copy exercises the shell code itself.
///
/// Requires the wasm_run native library (see WASM_RUN_DART_DYNAMIC_LIBRARY
/// or `.dart_tool/wasm_run/`); without it the suite SKIPs with a loud
/// reason — the simulator lane is the gate there.
@Tags(['integration'])
library;

import 'dart:io';

import '../integration_test/e2e_support/sandbox_probe_suite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wasm_run_flutter/wasm_run_flutter.dart';

Future<void> main() async {
  // BEFORE the binding init: flutter_test swaps HttpOverrides.global for a
  // 400 stub, so the curl builtin's client must exist before that happens.
  final httpClient = http.Client();
  TestWidgetsFlutterBinding.ensureInitialized();

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

  final root = await Directory.systemTemp.createTemp('fah_probe_sandbox_');
  final probes = await makeProbeSuite(root.path, httpClient: httpClient);

  for (final (name, body) in probes) {
    test(
      name,
      body,
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
