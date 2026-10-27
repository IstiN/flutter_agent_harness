// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Direct unit tests for `WasmSshCommands.builtinsFor` (issue #1713 CRAP
// descent: the 0%-cov entry). The five local-filesystem closures are pure
// `dart:io` over the sandbox host dir (`sandboxHostPath`), so the whole
// surface — read/write/kind/list/mkdir — is exercised against a throwaway
// temp tree. No SSH connection is involved: the connector and identity
// seams are never called here (they are covered by the scp/sftp suites
// against the in-memory fake remote in sandbox_ssh_test.dart).

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/sandbox/sandbox_ssh.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:fa/sandbox/wasm_shell_ssh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

/// The scripted-module scaffolding from the pipeline suite: distinct
/// instances per slot, and any spawn attempt is a test failure by itself —
/// no test here runs a WASM stage.
class _Recorder {
  final configs = <WasiConfig>[];
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
    return _ScriptedBuilder(null);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory sandbox;
  late _Recorder rec;

  setUp(() {
    sandbox = io.Directory.systemTemp.createTempSync('fah_1713_ssh');
    rec = _Recorder();
    addTearDown(() => sandbox.deleteSync(recursive: true));
  });

  WasmSshCommands commands() => WasmSshCommands(
    WasiSandboxShell(
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
    ),
  );

  group('builtinsFor local closures (issue #1713)', () {
    test('readBinaryFile returns bytes, or null when missing', () async {
      io.File('${sandbox.path}/a.bin').writeAsBytesSync([1, 2, 3]);
      final builtins = commands().builtinsFor('/');
      expect(await builtins.readBinaryFile('/a.bin'), [1, 2, 3]);
      expect(await builtins.readBinaryFile('/nope.bin'), isNull);
    });

    test('writeBinaryFile creates parents and writes bytes', () async {
      final builtins = commands().builtinsFor('/');
      await builtins.writeBinaryFile('/sub/dir/b.bin', Uint8List.fromList([9]));
      expect(io.File('${sandbox.path}/sub/dir/b.bin').readAsBytesSync(), [9]);
    });

    test('localKind maps file, directory and missing', () async {
      io.File('${sandbox.path}/f.txt').writeAsStringSync('x');
      io.Directory('${sandbox.path}/d').createSync();
      final builtins = commands().builtinsFor('/');
      expect(await builtins.localKind('/f.txt'), SandboxSshEntryKind.file);
      expect(await builtins.localKind('/d'), SandboxSshEntryKind.directory);
      expect(await builtins.localKind('/missing'), isNull);
    });

    test('listLocalDir returns sorted entry basenames', () async {
      io.Directory('${sandbox.path}/d').createSync();
      io.File('${sandbox.path}/d/z.txt').writeAsStringSync('');
      io.File('${sandbox.path}/d/a.txt').writeAsStringSync('');
      io.Directory('${sandbox.path}/d/m').createSync();
      final builtins = commands().builtinsFor('/');
      expect(await builtins.listLocalDir('/d'), ['a.txt', 'm', 'z.txt']);
    });

    test('makeLocalDir creates recursively', () async {
      final builtins = commands().builtinsFor('/');
      await builtins.makeLocalDir('/x/y/z');
      expect(io.Directory('${sandbox.path}/x/y/z').existsSync(), isTrue);
    });
  });
}
