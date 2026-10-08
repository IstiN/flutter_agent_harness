// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1393 WS-1 behavioral suite: the field-evidence defects, pinned on BOTH
// sandbox shells. WASI rows use scripted WASM slots (argv-level assertions
// for the rg-forwarding layer, real behavior for the Dart builtins); the
// web MemoryShell runs its real Dart builtins. The cross-shell conformance
// oracle lives in sandbox_conformance_test.dart.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

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

  group('WasiSandboxShell (gh-1393 field defects)', () {
    late io.Directory sandbox;
    late _Recorder rec;

    setUp(() {
      sandbox = io.Directory.systemTemp.createTempSync('fah_1393_wasi');
      rec = _Recorder();
      addTearDown(() => sandbox.deleteSync(recursive: true));
      io.Directory('${sandbox.path}/apps/2048').createSync(recursive: true);
      io.Directory('${sandbox.path}/apps/notes').createSync(recursive: true);
      io.File(
        '${sandbox.path}/apps/2048/app.json',
      ).writeAsStringSync('{"tap":true}\n');
      io.File(
        '${sandbox.path}/apps/notes/app.json',
      ).writeAsStringSync('{"other":1}\n');
      io.File('${sandbox.path}/in.txt').writeAsStringSync('abc\n');
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

    Future<ShellExecResult> run(
      String command, {
      List<int> stdoutBytes = const [],
      List<int> stderrBytes = const [],
      int exitCode = 0,
      ShellExecOptions? options,
    }) async {
      rec.next = _ScriptedInstance()
        ..out.add(Uint8List.fromList(stdoutBytes))
        ..err.add(Uint8List.fromList(stderrBytes));
      final r = await shell().exec(command, options: options);
      expect(r.isOk, isTrue, reason: r.errorOrNull.toString());
      final result = r.valueOrNull!;
      // Drain the scripted streams like the real pipeline does.
      return result;
    }

    test('AC1: glob args expand (was: ShellParseException)', () async {
      // `grep -rl 'TAP' apps/*/app.json` — the evidence command. The rg
      // layer receives BOTH matched files (order sorted), the -l from the
      // cluster, the pattern via -e, and grep-traversal parity flags.
      rec.next = _ScriptedInstance();
      final shell_ = shell();
      final r = await shell_.exec("grep -rl 'TAP' apps/*/app.json");
      expect(r.isOk, isTrue);
      expect(rec.configs.single.args, [
        'rg',
        '-l',
        '--no-ignore',
        '--hidden',
        '-e',
        'TAP',
        '/apps/2048/app.json',
        '/apps/notes/app.json',
      ]);
    });

    test('E1: glob matching nothing passes the literal through', () async {
      rec.next = _ScriptedInstance();
      await shell().exec('grep x *.nomatch');
      expect(rec.configs.single.args, [
        'rg',
        '--no-ignore',
        '--hidden',
        '-e',
        'x',
        '*.nomatch',
      ]);
    });

    test('AC1: bracket classes expand in argv (rework round 3)', () async {
      // gh-1393 rework: `[0-9]*` matches only the 2048 app dir — the
      // MemoryShell twin is pinned behaviorally (glob_expand_test) and
      // against the sh -c oracle (conformance row).
      rec.next = _ScriptedInstance();
      await shell().exec('grep tap apps/[0-9]*/app.json');
      expect(rec.configs.single.args, [
        'rg',
        '--no-ignore',
        '--hidden',
        '-e',
        'tap',
        '/apps/2048/app.json',
      ]);
    });

    test('quoted glob words stay literal', () async {
      rec.next = _ScriptedInstance();
      await shell().exec("grep x '*.nomatch'");
      expect(rec.configs.single.args.last, '*.nomatch');
    });

    test(
      'AC1: `grep -rl счёт apps` reaches rg with pattern-first position',
      () async {
        rec.next = _ScriptedInstance();
        await shell().exec('grep -rl счёт apps');
        expect(rec.configs.single.args, [
          'rg',
          '-l',
          '--no-ignore',
          '--hidden',
          '-e',
          'счёт',
          '/apps',
        ]);
      },
    );

    test('--include=GLOB forwards as an rg -g filter', () async {
      rec.next = _ScriptedInstance();
      await shell().exec('grep -r --include=*.json TAP apps');
      expect(rec.configs.single.args, [
        'rg',
        '-g',
        '*.json',
        '--no-ignore',
        '--hidden',
        '-e',
        'TAP',
        '/apps',
      ]);
    });

    test('-m1 reaches rg attached and detached (rework round 3 pin)',
        () async {
      // gh-1393 rework: the max-count flag is pinned on BOTH shells —
      // the WASI twin forwards it to rg (attached as `-m1`, detached as
      // the `-m N` pair, `--max-count=N` as the pair), the MemoryShell
      // engine honors it (memory_shell_test + the conformance oracle row).
      rec.next = _ScriptedInstance();
      await shell().exec('grep -m1 tap /in.txt');
      expect(rec.configs.last.args, contains('-m1'));

      rec.next = _ScriptedInstance();
      await shell().exec('grep -m 1 tap /in.txt');
      var args = rec.configs.last.args;
      expect(args[args.indexOf('-m') + 1], '1');

      rec.next = _ScriptedInstance();
      await shell().exec('grep --max-count=2 tap /in.txt');
      args = rec.configs.last.args;
      expect(args[args.indexOf('-m') + 1], '2');
    });

    test('BRE alternation reaches rg as ERE', () async {
      // Two stages: `echo` rides coreutils.wasm (scripted), `grep` forwards
      // to rg (scripted) — the rg stage's argv is the assertion target.
      rec.next = _ScriptedInstance();
      rec.next = _ScriptedInstance();
      await shell().exec("echo 'foo' | grep 'foo\\|bar'");
      final args = rec.configs.last.args;
      expect(args[args.indexOf('-e') + 1], 'foo|bar');
    });

    test('AC2: cd persists for subsequent execs of the shell', () async {
      io.Directory('${sandbox.path}/sub').createSync();
      final s = shell();
      var r = await s.exec('cd /sub');
      expect(r.valueOrNull!.exitCode, 0);
      r = await s.exec('pwd');
      expect(r.valueOrNull!.stdout, '/sub\n');
    });

    test('AC2: `cd /sub && tac < in.txt` resolves from the new cwd', () async {
      io.Directory('${sandbox.path}/sub').createSync();
      io.File(
        '${sandbox.path}/sub/in.txt',
      ).writeAsStringSync('first\nsecond\n');
      final r = await shell().exec('cd /sub && tac < in.txt');
      expect(r.valueOrNull!.stdout, 'second\nfirst\n');
    });

    test('an explicit non-root cwd still wins (per-exec request)', () async {
      io.Directory('${sandbox.path}/elsewhere').createSync();
      final r = await shell().exec(
        'pwd',
        options: ShellExecOptions(cwd: '${sandbox.path}/elsewhere'),
      );
      expect(r.valueOrNull!.stdout, '/elsewhere\n');
    });

    test(
      'AC3: redirect writes to /dev/null discard, nothing materializes',
      () async {
        final r = await shell().exec('tac < in.txt > /dev/null');
        expect(r.valueOrNull!.exitCode, 0);
        expect(io.File('${sandbox.path}/dev/null').existsSync(), isFalse);
        expect(io.Directory('${sandbox.path}/dev').existsSync(), isFalse);
      },
    );

    test('AC3: `expr 1 / 0 2> /dev/null` — no file, clean stderr', () async {
      final r = await shell().exec('expr 1 / 0 2> /dev/null');
      expect(r.valueOrNull!.exitCode, 2);
      expect(r.valueOrNull!.stderr, isEmpty);
      expect(io.File('${sandbox.path}/dev/null').existsSync(), isFalse);
    });

    test('AC3: `< /dev/null` reads an empty stream, never ENOENT', () async {
      final r = await shell().exec('tac < /dev/null');
      expect(r.valueOrNull!.exitCode, 0);
      expect(r.valueOrNull!.stdout, isEmpty);
      expect(io.File('${sandbox.path}/dev/null').existsSync(), isFalse);
    });

    test('AC3: `expr 1 / 0 2>&1` folds stderr into stdout', () async {
      final r = await shell().exec('expr 1 / 0 2>&1');
      expect(r.valueOrNull!.stdout, contains('division by zero'));
      expect(r.valueOrNull!.stderr, isEmpty);
    });
  });

  group('MemoryShell (gh-1393 field defects)', () {
    late MemoryShell shell;
    late MemoryExecutionEnv env;

    setUp(() {
      shell = MemoryShell();
      env = MemoryExecutionEnv(cwd: '/', shell: shell);
      shell.attach(env);
    });

    Future<ShellExecResult> run(
      String command, {
      ShellExecOptions? options,
    }) async {
      final r = await env.exec(command, options: options);
      expect(r.isOk, isTrue, reason: r.errorOrNull.toString());
      return r.valueOrNull!;
    }

    test('AC3: `echo hi 2>&1` works (was: parse-time rejection)', () async {
      final r = await run('echo hi 2>&1');
      expect(r.exitCode, 0);
      expect(r.stdout, 'hi\n');
      expect(r.stderr, isEmpty);
    });

    test('AC3: `> f 2>&1` folds both streams into the file in order', () async {
      final r = await run('echo out > /f.txt 2>&1; echo err2 1>&2');
      final content = await run('cat /f.txt');
      expect(content.stdout, 'out\n');
      expect(r.exitCode, 0);
    });

    test(
      'AC3: redirect writes to /dev/null discard, nothing materializes',
      () async {
        final r = await run('echo x > /dev/null 2> /dev/null');
        expect(r.exitCode, 0);
        final listing = await env.listDir('/');
        final names = listing.valueOrNull!.map((e) => e.name).toSet();
        expect(names.contains('dev'), isFalse);
      },
    );

    test('AC3: failing command with 2>/dev/null has clean stderr', () async {
      final r = await run('cat /missing 2> /dev/null');
      expect(r.exitCode, isNot(0));
      expect(r.stderr, isEmpty);
      final listing = await env.listDir('/');
      final names = listing.valueOrNull!.map((e) => e.name).toSet();
      expect(names.contains('dev'), isFalse);
    });

    test('AC3: `< /dev/null` reads an empty stream', () async {
      final r = await run('grep x < /dev/null');
      expect(r.exitCode, 1); // no matches, not an error
      expect(r.stdout, isEmpty);
    });

    test(
      'AC2: cd persists for subsequent execs (harness anchors at /)',
      () async {
        await run('mkdir -p /w/sub');
        await run('cd /w/sub');
        final r = await run('pwd');
        expect(r.stdout, '/w/sub\n');
        // The harness anchor (env cwd `/`) does NOT reset the tracked cwd…
        final anchored = await run(
          'pwd',
          options: const ShellExecOptions(cwd: '/'),
        );
        expect(anchored.stdout, '/w/sub\n');
        // …but an explicit different directory wins.
        final explicit = await run(
          'pwd',
          options: const ShellExecOptions(cwd: '/w'),
        );
        expect(explicit.stdout, '/w\n');
      },
    );

    test('AC2: `cd /w && cat rel.txt` resolves from the new cwd', () async {
      await run('mkdir -p /w');
      await run('echo data > /w/rel.txt');
      final r = await run('cd /w && cat rel.txt');
      expect(r.stdout, 'data\n');
    });

    test('E3: job-local clones keep independent cwds', () async {
      await run('mkdir -p /a /b');
      await run('cd /a');
      // A background job runs on a job-local clone: its `cd` must not leak
      // into the foreground shell (and vice versa).
      final started = await env.startShellJob(
        'cd /b && pwd > /fromjob.txt',
        id: 'job-1',
        logPath: '/job-1.log',
      );
      expect(started.isOk, isTrue, reason: '${started.errorOrNull}');
      final job = started.valueOrNull!;
      await job.settled;
      final mainPwd = await run('pwd');
      expect(mainPwd.stdout, '/a\n');
      final proof = await run('cat /fromjob.txt');
      expect(proof.stdout, '/b\n');
    });

    test('AC1: `grep -rl счёт apps` walks the directory with labels', () async {
      await run('mkdir -p /apps/one /apps/two');
      await run('echo "счёт один" > /apps/one/a.txt');
      await run('echo "nothing" > /apps/two/b.txt');
      await run('echo "счёт два" > /apps/two/c.json');
      final r = await run("grep -rl 'счёт' apps");
      expect(r.exitCode, 0);
      expect(r.stdout, 'apps/one/a.txt\napps/two/c.json\n');
    });

    test('AC1: --include filters recursive grep by basename', () async {
      await run('mkdir -p /proj');
      await run('echo TAP > /proj/a.json');
      await run('echo TAP > /proj/b.txt');
      final r = await run('grep -rl --include=*.json TAP proj');
      expect(r.stdout, 'proj/a.json\n');
    });

    test('E1: glob expands in argv; no match keeps the literal', () async {
      await run('mkdir -p /g/1 /g/2');
      await run('echo TAP > /g/1/f.txt');
      await run('echo TAP > /g/2/f.txt');
      final r = await run('grep -l TAP /g/*/f.txt');
      expect(r.stdout, '/g/1/f.txt\n/g/2/f.txt\n');
      final noMatch = await run('grep -l TAP /g/*/missing.txt');
      expect(noMatch.exitCode, isNot(0));
      expect(noMatch.stderr, contains('missing.txt'));
    });

    test(
      'E2: unknown flags error POSIX-style, never silently diverge',
      () async {
        final r = await run('grep -Z x /etc');
        expect(r.exitCode, 2);
        expect(r.stderr, contains("invalid option -- 'Z'"));
      },
    );

    test('\\| alternation matches either side', () async {
      await run('echo foo > /alt.txt');
      final r = await run("grep 'foo\\|bar' /alt.txt");
      expect(r.exitCode, 0);
      expect(r.stdout, 'foo\n');
    });
  });
}
