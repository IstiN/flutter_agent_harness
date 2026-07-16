import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wasm_run/wasm_run.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('minimal wasm add runs on iOS simulator', (tester) async {
    debugPrint('Loading add.wasm...');
    final byteData = await rootBundle.load('assets/wasm/add.wasm');
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    debugPrint('Compiling module...');
    final module = await compileWasmModule(bytes);
    debugPrint('Building instance...');
    final instance = await module.builder().build();
    debugPrint('Calling add(2, 3)...');
    final add = instance.getFunction('add')!;
    final result = add.call([2, 3]);
    debugPrint('add result: $result');

    expect(result, [5]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('add(2,3) = $result'))),
      ),
    );
    await tester.pumpAndSettle();
  });
}
