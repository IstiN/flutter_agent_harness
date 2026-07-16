// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wasm_run/wasm_run.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('web WASM runtime probe', (tester) async {
    debugPrint('[probe] setUp start');
    await WasmRunLibrary.setUp(
      override: false,
      isFlutter: true,
      loadAsset: rootBundle.load,
    ).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        debugPrint('[probe] setUp TIMED OUT (script never fired onLoad)');
      },
    );
    debugPrint('[probe] setUp done');

    final features = await wasmRuntimeFeatures();
    debugPrint('[probe] features: ${features.supportedFeatures}');

    final byteData = await rootBundle.load('assets/wasm/wasi_hello.wasm');
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    final module = await compileWasmModule(bytes);
    debugPrint('[probe] module compiled');
    final instance = await module
        .builder(
          wasiConfig: const WasiConfig(
            preopenedDirs: [],
            webBrowserFileSystem: {},
            captureStdout: true,
            captureStderr: true,
          ),
        )
        .build();
    debugPrint('[probe] instance built');
    final stdoutFuture = instance.stdout.first;
    await instance.runWasiStartAsync();
    final text = String.fromCharCodes(await stdoutFuture);
    debugPrint('[probe] stdout: $text');
    expect(text, contains('hello from rust wasi'));
  });
}
