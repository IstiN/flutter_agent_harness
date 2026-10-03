// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The iOS/WASI sandbox golden probe suite, simulator/device entry
/// (issue #1156 AC1/AC7).
///
/// Run on an iOS simulator or device:
/// ```
/// flutter test integration_test/sandbox_probe_suite_test.dart
/// ```
///
/// Each probe row runs against the REAL `WasiSandboxShell` produced by
/// `createMobileSandboxEnv`'s loader — the exact shell the app ships.
library;

import 'dart:io';

import 'package:fa/sandbox/wasm_setup_io.dart';
import 'e2e_support/sandbox_probe_suite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  // BEFORE the binding init (see the host entry note in the shared suite).
  final httpClient = http.Client();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  await setUpWasmRuntime();

  final docs = await getApplicationDocumentsDirectory();
  final root = '${docs.path}/fah_probe_sandbox';
  await Directory(root).create(recursive: true);
  final probes = await makeProbeSuite(root, httpClient: httpClient);

  for (final (name, body) in probes) {
    testWidgets(name, (tester) async {
      await tester.runAsync(body);
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
