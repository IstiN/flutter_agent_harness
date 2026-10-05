// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

// gh-1274: the mobile harness reports the *host* sandbox directory as the
// env cwd (`/var/mobile/Containers/…/fah_sandbox` on iOS) and the bash tool
// passes it into every ShellExecOptions. The WASI guest is preopened at `/`,
// so using that host string as the guest cwd resolves every relative path
// against a nonexistent nested mirror. These tests pin the sandbox shell's
// contract: a cwd inside sandboxHostPath maps back to its sandbox-absolute
// form, so `echo hello > t.txt && cat t.txt` round-trips. The sandbox root
// deliberately lives under an iOS-container-shaped path so the path
// semantics are the ones seen on device.

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

/// Shared per-test state: every WASI config handed to a builder plus the
/// next scripted instance to serve (same pattern as
/// wasm_shell_pipeline_test.dart).
class _Recorder {
  final configs = <WasiConfig>[];
  WasmInstance? next;
}

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

class _ScriptedInstance extends Fake implements WasmInstance {
  final StreamController<Uint8List> out = StreamController<Uint8List>();
  final StreamController<Uint8List> err = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get stdout => out.stream;

  @override
  Stream<Uint8List> get stderr => err.stream;

  @override
  Future<void> runWasiStartAsync() async {}

  @override
  void dispose() {
    out.close();
    err.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tmp;
  late io.Directory sandbox;
  late _Recorder rec;

  // iOS container shape: /var/mobile/Containers/Data/Application/<uuid>/
  // Documents/fah_sandbox — long, deep, and not a path the WASI guest can
  // see (its only preopen maps `/` at the sandbox root).
  final hostCwd = <String>[];

  setUp(() {
    tmp = io.Directory.systemTemp.createTempSync('fah_1274');
    sandbox = io.Directory(
      '${tmp.path}/var/mobile/Containers/Data/Application/'
      'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/Documents/fah_sandbox',
    )..createSync(recursive: true);
    hostCwd
      ..clear()
      ..add(sandbox.path);
    rec = _Recorder();
    addTearDown(() => tmp.deleteSync(recursive: true));
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
    sandboxHostPath: sandbox.path,
  );

  group('host cwd never leaks into guest path resolution (gh-1274)', () {
    test('redirect write with host cwd lands at the sandbox root', () async {
      // `pwd` is a Dart builtin, so no scripted WASM guest is needed; on
      // device `echo hello > t.txt` exercises the identical redirect path.
      final r = await shell().exec(
        'pwd > t.txt',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      expect(r.isOk, isTrue, reason: r.errorOrNull?.message);
      final written = io.File('${sandbox.path}/t.txt');
      expect(written.existsSync(), isTrue);
      expect(written.readAsStringSync(), '/\n');
      // No nested mirror of the host path inside the sandbox.
      expect(io.Directory('${sandbox.path}/var').existsSync(), isFalse);
    });

    test('cat operand with host cwd resolves to /t.txt', () async {
      io.File('${sandbox.path}/t.txt').writeAsStringSync('hello\n');
      rec.next = _ScriptedInstance();
      final r = await shell().exec(
        'cat t.txt',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      expect(r.isOk, isTrue, reason: r.errorOrNull?.message);
      expect(rec.configs.single.args, ['cat', '/t.txt']);
    });

    test('host cwd inside a subdirectory maps to the guest subdir', () async {
      io.Directory('${sandbox.path}/work').createSync();
      rec.next = _ScriptedInstance();
      final r = await shell().exec(
        'cat notes.txt',
        options: ShellExecOptions(cwd: '${hostCwd.single}/work'),
      );
      expect(r.isOk, isTrue, reason: r.errorOrNull?.message);
      expect(rec.configs.single.args, ['cat', '/work/notes.txt']);
    });

    test('cd from a host-cwd exec lands at a guest path', () async {
      io.Directory('${sandbox.path}/work').createSync();
      rec.next = _ScriptedInstance();
      final session = shell();
      // Mobile flow: every exec carries the host cwd; `cd` in its own
      // command must still move the shell to a *guest* path.
      final cd = await session.exec(
        'cd work',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      expect(cd.isOk, isTrue, reason: cd.errorOrNull?.message);
      final cat = await session.exec('cat t.txt');
      expect(cat.isOk, isTrue, reason: cat.errorOrNull?.message);
      expect(rec.configs.single.args, ['cat', '/work/t.txt']);
    });

    test('pwd with host cwd prints the guest path', () async {
      final r = await shell().exec(
        'pwd',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      expect(r.isOk, isTrue, reason: r.errorOrNull?.message);
      expect(r.valueOrNull!.stdout, '/\n');
    });

    test('PWD env with host cwd carries the guest path', () async {
      rec.next = _ScriptedInstance();
      await shell().exec(
        'cat t.txt',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      final pwd = rec.configs.single.env.firstWhere(
        (e) => e.name == 'PWD',
      );
      expect(pwd.value, '/');
    });

    test('guest-side cwd still passes through unchanged', () async {
      io.Directory('${sandbox.path}/work').createSync();
      rec.next = _ScriptedInstance();
      final r = await shell().exec(
        'cat notes.txt',
        options: const ShellExecOptions(cwd: '/work'),
      );
      expect(r.isOk, isTrue, reason: r.errorOrNull?.message);
      expect(rec.configs.single.args, ['cat', '/work/notes.txt']);
    });

    test('git with host cwd touches the sandbox root, not a mirror', () async {
      // `git init` is a repo-free command resolved against the call's cwd;
      // with the host cwd it must land at the real sandbox root (the view
      // the file tools and guest-side commands share), not a nested mirror
      // of the host path.
      final init = await shell().exec(
        'git init',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      expect(init.isOk, isTrue, reason: init.errorOrNull?.message);
      expect(init.valueOrNull!.exitCode, 0, reason: init.valueOrNull!.stderr);
      expect(io.Directory('${sandbox.path}/.git').existsSync(), isTrue);
      expect(io.Directory('${sandbox.path}/var').existsSync(), isFalse);
    });

    test('write then read round trip lands one visible file', () async {
      // `pwd`/`tac` are Dart builtins, so the whole round trip goes through
      // the same host FS with no scripted WASM guest; on device
      // `echo hello > t.txt && cat t.txt` exercises the identical path.
      final r = await shell().exec(
        'pwd > t.txt && tac t.txt',
        options: ShellExecOptions(cwd: hostCwd.single),
      );
      expect(r.isOk, isTrue, reason: r.errorOrNull?.message);
      expect(r.valueOrNull!.stdout, '/\n');
      expect(io.File('${sandbox.path}/t.txt').existsSync(), isTrue);
    });
  });
}
