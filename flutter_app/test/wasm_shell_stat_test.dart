// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// E2E tests for the `stat` builtin of WasiSandboxShell (issue #701 CRAP
// descent #12). `stat` runs entirely in Dart over the sandbox host dir,
// so the branch matrix — flag parsing (`-c`, `--format=`, bare flags),
// missing operand, missing file, per-format-directive rendering and the
// default multi-line block — is asserted through `exec` like the
// descent-#11 suites (see test/wasm_shell_pipeline_test.dart). No WASM
// cores are loaded.

import 'dart:io' as io;

import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

/// The scripted-module scaffolding from the pipeline suite: slots must be
/// distinct instances, and with no instance queued any spawn fails — no
/// test here spawns one, so a spawn attempt is a test failure by itself.
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
    sandbox = io.Directory.systemTemp.createTempSync('fah_701_stat');
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

  Future<ShellExecResult> run(String script) async {
    final r = await shell().exec(script);
    expect(r.isOk, isTrue, reason: script);
    return r.valueOrNull!;
  }

  io.File hostFile(String rel, String content) {
    final f = io.File('${sandbox.path}/$rel');
    f.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  group('stat builtin (issue #701)', () {
    test('default block for a regular file', () async {
      hostFile('f.txt', 'abc');
      final r = await run('stat f.txt');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('File: /f.txt'));
      expect(r.stdout, contains('Size: 3'));
      expect(r.stdout, contains('Type: regular file'));
      expect(r.stdout, contains('Modify:'));
      expect(r.stdout, contains('Change:'));
      expect(r.stderr, isEmpty);
    });

    test('default block for a directory', () async {
      io.Directory('${sandbox.path}/sub').createSync();
      final r = await run('stat sub');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Type: directory'));
    });

    test('missing operand exits 1 with GNU message', () async {
      final r = await run('stat');
      expect(r.exitCode, 1);
      expect(r.stderr, 'stat: missing operand\n');
      expect(r.stdout, isEmpty);
    });

    test('-c without a value exits 1', () async {
      hostFile('f.txt', 'abc');
      final r = await run('stat -c');
      expect(r.exitCode, 1);
      expect(r.stderr, 'stat: option requires an argument -- c\n');
    });

    test('--format consumes the next token, leaving no operand', () async {
      final r = await run('stat --format f.txt');
      expect(r.exitCode, 1);
      expect(r.stderr, 'stat: missing operand\n');
    });

    test('missing file exits 1 naming the operand', () async {
      final r = await run('stat nope.txt');
      expect(r.exitCode, 1);
      expect(
        r.stderr,
        "stat: cannot stat 'nope.txt': No such file or directory\n",
      );
      expect(r.stdout, isEmpty);
    });

    test('-c renders %s %n %F in one line per file', () async {
      hostFile('f.txt', 'abcd');
      final r = await run('stat -c %s:%n:%F f.txt');
      expect(r.exitCode, 0);
      expect(r.stdout, '4:/f.txt:regular file\n');
    });

    test('--format= form renders timestamps too', () async {
      final f = hostFile('f.txt', 'x');
      final mtime = f.lastModifiedSync();
      final r = await run('stat --format=%Y/%y f.txt');
      expect(r.exitCode, 0);
      expect(
        r.stdout,
        '${mtime.millisecondsSinceEpoch ~/ 1000}/'
        '${mtime.toIso8601String()}\n',
      );
    });

    test('unknown % specifiers pass through verbatim', () async {
      hostFile('f.txt', 'zz');
      final r = await run('stat -c [%q-%s] f.txt');
      expect(r.stdout, '[%q-2]\n');
    });

    test('several files each get their own default block', () async {
      hostFile('a.txt', 'aaa');
      io.Directory('${sandbox.path}/d').createSync();
      final r = await run('stat a.txt d');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('File: /a.txt'));
      expect(r.stdout, contains('Type: regular file'));
      expect(r.stdout, contains('File: /d'));
      expect(r.stdout, contains('Type: directory'));
    });

    test('several files with a format: one line each, in order', () async {
      hostFile('a.txt', 'aaa');
      hostFile('b.txt', 'bb');
      final r = await run('stat -c %s:%n a.txt b.txt');
      expect(r.stdout, '3:/a.txt\n2:/b.txt\n');
    });

    test('stat stops at the first missing file', () async {
      hostFile('a.txt', 'aaa');
      final r = await run('stat a.txt nope.txt b.txt');
      expect(r.exitCode, 1);
      expect(
        r.stderr,
        "stat: cannot stat 'nope.txt': No such file or directory\n",
      );
      expect(r.stdout, isEmpty);
    });

    test('other flags are skipped, not treated as files', () async {
      hostFile('f.txt', 'abc');
      final r = await run('stat -L -f f.txt');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Type: regular file'));
    });

    test('relative to the cwd set by cd (options.cwd)', () async {
      hostFile('sub/inner.txt', 'inside');
      final r = await run('cd sub && stat inner.txt');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('File: /sub/inner.txt'));
      expect(r.stdout, contains('Size: 6'));
    });

    test('cwd-relative format line under cd', () async {
      hostFile('sub/inner.txt', 'inside');
      final r = await run('cd sub && stat -c %n inner.txt');
      expect(r.stdout, '/sub/inner.txt\n');
    });
  });
}
