import 'dart:io' as io;
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' show LocalShell;
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

class _NoWasmModule extends Fake implements WasmModule {
  @override
  WasmInstanceBuilder builder({WasiConfig? wasiConfig, WorkersConfig? workersConfig}) =>
      throw StateError('wasm');
}

Future<Result<ShellExecResult, ExecutionError>> runWasi(String command) async {
  final dir = await io.Directory.systemTemp.createTemp('fah_1393_conf_wasi');
  try {
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
    final probe = await shell.exec('test -f in.txt');
    // ignore: avoid_print
    print('[probe] exit=${probe.valueOrNull!.exitCode}');
    for (var i = 2; i <= 8; i++) {
      final r = await shell.exec(command);
      final exists = io.File('$dir/in.txt').existsSync();
      // ignore: avoid_print
      print('[exec-$i] exit=${r.valueOrNull!.exitCode} fileExists=$exists');
    }
    return shell.exec(command);
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('probe exact runner', () async {
    final r = await runWasi('test -f in.txt');
    // ignore: avoid_print
    print('[row] exit=${r.valueOrNull?.exitCode} ok=${r.isOk}');
  });
}
