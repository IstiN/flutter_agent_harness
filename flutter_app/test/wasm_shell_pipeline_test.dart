// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the WasiSandboxShell pipeline/stage engine (issue #558
// CRAP descent). Dart builtins (`expr`, `tr`, `tac`, `cd`) drive the
// pipeline, redirect and accumulator machinery end to end, and a scripted
// WasmModule stub records WASI argv so the path-rewrite engine is asserted
// without loading any WASM cores.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

/// Shared per-test state: every WASI config handed to a builder plus the
/// next scripted instance to serve. With no instance queued the build
/// fails (spawn error), which is how argv-asserting tests terminate.
class _Recorder {
  final configs = <WasiConfig>[];
  WasmInstance? next;
}

/// One WASM module slot. Slots must be DISTINCT INSTANCES so the shell's
/// `module == python` identity checks behave like the real registry.
class _SlotModule extends Fake implements WasmModule {
  _SlotModule(this._rec);
  final _Recorder _rec;

  @override
  WasmInstanceBuilder builder({
    WasiConfig? wasiConfig,
    WorkersConfig? workersConfig,
  }) {
    _rec.configs.add(wasiConfig!);
    final instance = _rec.next;
    _rec.next = null;
    return _ScriptedBuilder(instance);
  }
}

class _ScriptedBuilder extends Fake implements WasmInstanceBuilder {
  _ScriptedBuilder(this._instance);
  final WasmInstance? _instance;

  @override
  Future<WasmInstance> build() async {
    final instance = _instance;
    if (instance == null) throw StateError('no scripted instance');
    return instance;
  }
}

/// Instance whose WASI start can be gated (to hold the timeout race), can
/// fail with a scripted trap, and whose stdio streams are scriptable
/// controllers.
class _ScriptedInstance extends Fake implements WasmInstance {
  final StreamController<Uint8List> out = StreamController<Uint8List>();
  final StreamController<Uint8List> err = StreamController<Uint8List>();

  Completer<void>? gate;
  Object? startError;

  @override
  Stream<Uint8List> get stdout => out.stream;

  @override
  Stream<Uint8List> get stderr => err.stream;
  @override
  Future<void> runWasiStartAsync() async {
    final gate = this.gate;
    if (gate != null) await gate.future;
    final error = startError;
    if (error != null) throw error;
  }

  @override
  void dispose() {
    out.close();
    err.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory sandbox;
  late _Recorder rec;

  setUp(() {
    sandbox = io.Directory.systemTemp.createTempSync('fah_558');
    rec = _Recorder();
    addTearDown(() => sandbox.deleteSync(recursive: true));
  });

  WasiSandboxShell shell() => WasiSandboxShell(
    coreutils: _SlotModule(rec),
    rg: _SlotModule(rec),
    find: _SlotModule(rec),
    sed: _SlotModule(rec),
    awk: _SlotModule(rec),
    tar: _SlotModule(rec),
    gzip: _SlotModule(rec),
    zip: _SlotModule(rec),
    python: _SlotModule(rec),
    qjs: _SlotModule(rec),
    sqlite3: _SlotModule(rec),
    lua: _SlotModule(rec),
    sandboxHostPath: sandbox.path,
  );

  group('expr evaluator (Dart builtin path)', () {
    Future<ShellExecResult> run(String script) async {
      final r = await shell().exec(script);
      expect(r.isOk, isTrue, reason: script);
      return r.valueOrNull!;
    }

    test('multiplication binds tighter than addition', () async {
      final r = await run('expr 2 + 3 * 4');
      expect(r.stdout, '14\n');
      expect(r.exitCode, 0);
    });

    test('integer division truncates and modulo wraps', () async {
      expect((await run('expr 7 / 2')).stdout, '3\n');
      expect((await run('expr 10 % 3')).stdout, '1\n');
    });

    test('sums chain left to right', () async {
      expect((await run('expr 1 + 2 + 3')).stdout, '6\n');
    });

    test('comparisons yield 1 or 0', () async {
      expect((await run("expr 3 '<' 9")).stdout, '1\n');
      expect((await run("expr 3 '=' 4")).stdout, '0\n');
      expect((await run('expr 1 + 2 = 3')).stdout, '1\n');
    });

    test('length and substr string functions', () async {
      expect((await run('expr length hello')).stdout, '5\n');
      expect((await run('expr substr hello 2 3')).stdout, 'ell\n');
      // Length past the end clamps to the string.
      expect((await run('expr substr hello 4 99')).stdout, 'lo\n');
    });

    test('missing operand exits 2 with a GNU-shaped message', () async {
      final r = await run('expr');
      expect(r.exitCode, 2);
      expect(r.stderr, 'expr: missing operand\n');
    });

    test('division by zero exits 2', () async {
      final r = await run('expr 1 / 0');
      expect(r.exitCode, 2);
      expect(r.stderr, 'expr: division by zero\n');
    });

    test('non-integer operand names the offender', () async {
      final r = await run('expr 1 + x');
      expect(r.exitCode, 2);
      expect(r.stderr, 'expr: non-integer argument: x\n');
    });

    test('trailing garbage after a comparison is a syntax error', () async {
      final r = await run('expr 1 = 2 = 3');
      expect(r.exitCode, 2);
      expect(r.stderr, 'expr: syntax error\n');
    });
  });

  group('pipeline plumbing (Dart builtin stages)', () {
    test('builtin stdout crosses the pipe into the next stage', () async {
      final r = await shell().exec('expr 1 + 2 | tr 3 4');
      expect(r.valueOrNull!.stdout, '4\n');
      expect(r.valueOrNull!.exitCode, 0);
    });

    test('intermediate stdout never leaks into the accumulator', () async {
      final r = await shell().exec('expr 1 + 2 | tac');
      expect(r.valueOrNull!.stdout, '3\n');
    });

    test('stdin redirect feeds the stage from the sandbox root', () async {
      io.File('${sandbox.path}/in.txt').writeAsStringSync('a\nb\n');
      final r = await shell().exec('tac < in.txt');
      expect(r.valueOrNull!.stdout, 'b\na\n');
    });

    test('cd moves the resolution root for later stages', () async {
      io.Directory('${sandbox.path}/work').createSync();
      io.File('${sandbox.path}/work/in.txt').writeAsStringSync('x\n');
      final r = await shell().exec('cd /work && tac < in.txt');
      expect(r.valueOrNull!.stdout, 'x\n');
    });

    test('stdout redirect truncates, append accumulates', () async {
      final s = shell();
      await s.exec('expr 6 * 7 > out.txt');
      await s.exec('expr 1 + 1 >> out.txt');
      expect(io.File('${sandbox.path}/out.txt').readAsStringSync(), '42\n2\n');
    });

    test('stderr redirect captures builtin errors', () async {
      final r = await shell().exec('expr 1 / 0 2> err.txt');
      expect(r.valueOrNull!.exitCode, 2);
      expect(
        io.File('${sandbox.path}/err.txt').readAsStringSync(),
        'expr: division by zero\n',
      );
    });
  });

  group('stage engine over scripted modules', () {
    test('build failure surfaces a spawn error', () async {
      final r = await shell().exec('cat notes.txt');
      expect(r.isErr, isTrue);
      expect(r.errorOrNull?.code, ExecutionErrorCode.spawnError);
    });

    test('cat operand is rewritten against the current directory', () async {
      io.Directory('${sandbox.path}/work').createSync();
      rec.next = _ScriptedInstance();
      final r = await shell().exec('cd /work && cat notes.txt');
      expect(r.isOk, isTrue); // the stub's start returns, exit 0
      expect(rec.configs, hasLength(1));
      expect(rec.configs.single.args, ['cat', '/work/notes.txt']);
    });

    test('dd if=/of= operands are rewritten', () async {
      rec.next = _ScriptedInstance();
      await shell().exec('dd if=in.bin of=out.bin');
      expect(rec.configs.single.args, ['dd', 'if=/in.bin', 'of=/out.bin']);
    });

    test('sed keeps its script argument verbatim', () async {
      io.Directory('${sandbox.path}/work').createSync();
      io.File('${sandbox.path}/work/doc.txt').writeAsStringSync('a');
      rec.next = _ScriptedInstance();
      await shell().exec("cd /work && sed 's/a/b/' doc.txt");
      expect(rec.configs.single.args, ['sed', 's/a/b/', '/work/doc.txt']);
    });

    test('flag values are never rewritten even when the file exists', () async {
      io.Directory('${sandbox.path}/work').createSync();
      io.File('${sandbox.path}/work/2').writeAsStringSync('');
      io.File('${sandbox.path}/work/f.log').writeAsStringSync('');
      rec.next = _ScriptedInstance();
      await shell().exec('cd /work && head -n 2 f.log');
      expect(rec.configs.single.args, ['head', '-n', '2', '/work/f.log']);
    });

    test('mixed-kind commands rewrite only existing files', () async {
      io.Directory('${sandbox.path}/work').createSync();
      io.File('${sandbox.path}/work/script.py').writeAsStringSync('');
      rec.next = _ScriptedInstance();
      await shell().exec(
        "cd /work && python3 -c 'print(1)' script.py nope.txt",
      );
      expect(rec.configs.single.args, [
        'python',
        '-c',
        'print(1)',
        '/work/script.py',
        'nope.txt',
      ]);
    });

    test('python stages get PYTHONPATH with pip site-packages', () async {
      rec.next = _ScriptedInstance();
      await shell().exec("python3 -c 'print(1)'");
      final env = rec.configs.single.env;
      expect(env.map((e) => e.name), contains('PYTHONPATH'));
    });

    test('non-python stages get no PYTHONPATH', () async {
      rec.next = _ScriptedInstance();
      await shell().exec('cat notes.txt');
      expect(
        rec.configs.single.env.map((e) => e.name),
        isNot(contains('PYTHONPATH')),
      );
    });

    test('stdout/stderr chunks reach callbacks and the accumulator', () async {
      final seen = <String>[];
      final instance = _ScriptedInstance();
      rec.next = instance;
      final future = shell().exec(
        'cat x',
        options: ShellExecOptions(onStdout: seen.add),
      );
      instance.out.add(utf8.encode('hello'));
      instance.err.add(utf8.encode('boo'));
      final r = await future;
      expect(seen, ['hello']);
      expect(r.valueOrNull!.stdout, 'hello');
      expect(r.valueOrNull!.stderr, 'boo');
      expect(r.valueOrNull!.exitCode, 0);
    });

    test('I32Exit traps map to the stage exit code', () async {
      final instance = _ScriptedInstance()
        ..startError = Exception('Exited with i32 exit status 7');
      rec.next = instance;
      final r = await shell().exec('cat x');
      expect(r.valueOrNull!.exitCode, 7);
    });

    test('unparsable traps with output degrade to exit 1', () async {
      final instance = _ScriptedInstance()..startError = StateError('trap');
      rec.next = instance;
      final future = shell().exec('cat x');
      instance.out.add(utf8.encode('partial'));
      final r = await future;
      expect(r.valueOrNull!.exitCode, 1);
    });

    test('a hung start times out with a timeout error', () async {
      final instance = _ScriptedInstance()..gate = Completer<void>();
      rec.next = instance;
      final r = await shell().exec(
        'cat x',
        options: ShellExecOptions(timeout: const Duration(milliseconds: 30)),
      );
      expect(r.isErr, isTrue);
      expect(r.errorOrNull?.code, ExecutionErrorCode.timeout);
      instance.gate!.complete(); // drain the dangling start
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('caller callback failure wins the outcome', () async {
      final instance = _ScriptedInstance()..gate = Completer<void>();
      rec.next = instance;
      final delivered = Completer<void>();
      final future = shell().exec(
        'cat x',
        options: ShellExecOptions(
          onStdout: (s) {
            if (!delivered.isCompleted) delivered.complete();
            throw StateError('cb boom');
          },
        ),
      );
      instance.out.add(utf8.encode('boom'));
      await delivered.future;
      instance.gate!.complete();
      final r = await future;
      expect(r.isErr, isTrue);
      expect(r.errorOrNull?.code, ExecutionErrorCode.callbackError);
      expect(r.errorOrNull?.message, contains('cb boom'));
    });
  });
}
