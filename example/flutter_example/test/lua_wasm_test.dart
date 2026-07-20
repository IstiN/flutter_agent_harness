import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_example/wasm_shell.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io' as io;

void main() {
  testWidgets('lua wasm runs a one-liner', (tester) async {
    final dir = await getTemporaryDirectory();
    final sandbox =
        '${dir.path}/lua_test_${DateTime.now().millisecondsSinceEpoch}';
    await io.Directory(sandbox).create(recursive: true);
    final shell = await WasiSandboxShell.load(sandboxHostPath: sandbox);
    final result = await shell.exec('lua -e "print(\\"hello\\")"');
    expect(result.isOk, isTrue, reason: result.errorOrNull?.toString());
    expect(result.valueOrNull?.stdout.trim(), 'hello');
  });
}
