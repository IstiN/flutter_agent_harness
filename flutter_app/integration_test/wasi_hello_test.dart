import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wasm_run/wasm_run.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('minimal WASI hello runs on iOS simulator', (tester) async {
    debugPrint('Loading wasi_hello.wasm...');
    final byteData = await rootBundle.load('assets/wasm/wasi_hello.wasm');
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    debugPrint('Compiling module...');
    final module = await compileWasmModule(bytes);
    debugPrint('Building instance...');
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
    debugPrint('Running _start...');
    final stdoutFuture = instance.stdout.first;
    await instance.runWasiStartAsync();

    final stdout = await stdoutFuture;
    final text = String.fromCharCodes(stdout);
    debugPrint('WASI stdout: $text');

    expect(text, contains('hello from rust wasi'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('WASI: $text'))),
      ),
    );
    await tester.pumpAndSettle();
  });
}
