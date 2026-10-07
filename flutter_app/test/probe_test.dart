import 'dart:io' as io;
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

class _NoWasmModule extends Fake implements WasmModule {
  @override
  WasmInstanceBuilder builder({WasiConfig? wasiConfig, WorkersConfig? workersConfig}) =>
      throw StateError('wasm');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('probe runner-style', () async {
    final dir = await io.Directory.systemTemp.createTemp('fah_1393_conf_wasi');
    for (final entry in {
      'in.txt': 'alpha\nbeta\n',
      'work/notes.txt': 'note one\nnote two\n',
      'apps/2048/app.json': '{"tap":true}\n',
      'apps/notes/app.json': '{"other":1}\n',
    }.entries) {
      final file = io.File('${dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final shell = WasiSandboxShell(
      coreutils: _NoWasmModule(), rg: _NoWasmModule(), find: _NoWasmModule(),
      sed: _NoWasmModule(), awk: _NoWasmModule(), tar: _NoWasmModule(),
      gzip: _NoWasmModule(), zip: _NoWasmModule(), python: _NoWasmModule(),
      qjs: _NoWasmModule(), sqlite3: _NoWasmModule(), lua: _NoWasmModule(),
      sandboxHostPath: dir.path,
    );
    final r = await shell.exec('test -f in.txt');
    print('exit=${r.valueOrNull!.exitCode}');
    print('dir exists still: ${io.File('${dir.path}/in.txt').existsSync()}');
    await dir.delete(recursive: true);
  });
}
