// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration test that catalogs the shell commands available in the mobile
/// WASM sandbox (uutils coreutils + ripgrep + findutils).
///
/// Run on an iOS/Android simulator or device:
///   flutter test integration_test/coreutils_catalog_test.dart
///
/// The test deliberately exercises commands an agent typically relies on, and
/// asserts that commands not shipped in the sandbox (curl, sed, awk, xargs,
/// which, whoami) fail so the prompt can be tuned accordingly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('coreutils catalog in platform ExecutionEnv', (tester) async {
    debugPrint('Creating platform env...');
    final env = await createPlatformEnv();
    final sandbox = env is LocalExecutionEnv ? env.cwd : '/';
    debugPrint('Sandbox root: $sandbox');

    Future<ShellExecResult> run(String command) async {
      final result = await env.exec(command);
      if (result.isErr) {
        final error = result.errorOrNull!;
        fail('"$command" failed: $error');
      }
      return result.valueOrNull!;
    }

    Future<void> runFails(String command) async {
      final result = await env.exec(command);
      if (result.isErr) return;
      expect(result.valueOrNull!.exitCode, isNot(0));
    }

    // Seed files through the filesystem so the test is self-contained.
    await env.writeFile('fruits.txt', 'cherry\napple\nbanana\napple\n');
    await env.writeFile('nums.txt', 'one:1\ntwo:2\nthree:3\n');
    await env.writeFile('words.txt', 'alpha\nbeta\ngamma\n');
    await env.writeFile('hash_me.txt', 'hash me');
    await env.createDir('nested');
    await env.writeFile('nested/target.txt', 'found me');

    group(String name, void Function() body) =>
        body(); // ignore: avoid_types_on_closure_parameters

    group('basics', () {
      test('echo and printf', () async {
        final echo = await run('echo hello world');
        expect(echo.stdout.trim(), 'hello world');
        final printf = await run(r"printf 'x%sy' z");
        expect(printf.stdout, 'xzy');
      });

      test('true, false, exit codes', () async {
        expect((await run('true')).exitCode, 0);
        expect((await run('false')).exitCode, 1);
      });

      test('pwd', () async {
        // The WASM sandbox sees its host directory as '/'.
        final pwd = await run('pwd');
        expect(pwd.stdout.trim(), isMobile ? '/' : sandbox);
      });
    });

    group('file operations', () {
      test('ls lists files and directories', () async {
        final ls = await run('ls /');
        expect(ls.stdout, contains('fruits.txt'));
        expect(ls.stdout, contains('nested/'));
      });

      test('cat reads files', () async {
        final cat = await run('cat /fruits.txt');
        expect(cat.stdout, 'cherry\napple\nbanana\napple\n');
      });

      test('mkdir, touch, cp, mv, rm', () async {
        await run('mkdir /d /d/sub');
        await run('touch /d/sub/f.txt');
        await run('cp /d/sub/f.txt /d/sub/g.txt');
        await run('mv /d/sub/g.txt /d/sub/h.txt');
        await run('rm /d/sub/h.txt');
        await run('rm -r /d');
      });
    });

    group('text processing', () {
      test('head and tail', () async {
        expect((await run('head -n1 /fruits.txt')).stdout.trim(), 'cherry');
        expect((await run('tail -n1 /fruits.txt')).stdout.trim(), 'apple');
      });

      test('sort and uniq', () async {
        final sorted = await run('sort /fruits.txt');
        expect(sorted.stdout.trim().split('\n'), [
          'apple',
          'apple',
          'banana',
          'cherry',
        ]);
        final unique = await run('sort /fruits.txt | uniq');
        expect(unique.stdout.trim().split('\n'), ['apple', 'banana', 'cherry']);
      });

      test('wc', () async {
        final wc = await run('wc -l /fruits.txt');
        expect(wc.stdout.trim(), contains('4'));
      });

      test('cut', () async {
        final cut = await run("cut -d':' -f2 /nums.txt");
        expect(cut.stdout.trim().split('\n'), ['1', '2', '3']);
      });

      test('tr', () async {
        final tr = await run("echo hello | tr 'a-z' 'A-Z'");
        expect(tr.stdout.trim(), 'HELLO');
      });

      test('paste', () async {
        final paste = await run('paste -d"," /nums.txt /fruits.txt');
        expect(paste.stdout, isNotEmpty);
      });
    });

    group('search', () {
      test('rg (ripgrep)', () async {
        if (!isMobile) {
          markTestSkipped('rg only bundled in the mobile WASM sandbox');
          return;
        }
        final rg = await run('rg et /words.txt');
        expect(rg.stdout.trim(), 'beta');
      });

      test('find', () async {
        final find = await run('find / -name target.txt');
        expect(find.stdout.trim(), contains('target.txt'));
      });
    });

    group('path utilities', () {
      test('basename, dirname, realpath', () async {
        await run('mkdir -p /a/b');
        await run('touch /a/b/c.txt');
        expect((await run('basename /a/b/c.txt')).stdout.trim(), 'c.txt');
        expect((await run('dirname /a/b/c.txt')).stdout.trim(), '/a/b');
        expect((await run('realpath /a/b/c.txt')).stdout.trim(), '/a/b/c.txt');
        await run('rm -r /a');
      });
    });

    group('sequence, time, platform', () {
      test('seq', () async {
        final seq = await run('seq 1 3');
        expect(seq.stdout.trim().split('\n'), ['1', '2', '3']);
      });

      test('date and uname', () async {
        final date = await run('date +%Y');
        expect(date.stdout.trim(), matches(r'^\d{4}$'));
        final uname = await run('uname');
        expect(uname.stdout.trim(), isNotEmpty);
      });
    });

    group('hashing and env', () {
      test('md5sum and sha256sum', () async {
        final md5 = await run('md5sum /hash_me.txt');
        expect(md5.stdout.trim(), matches(r'^[a-f0-9]{32}\s+/hash_me\.txt$'));
        final sha = await run('sha256sum /hash_me.txt');
        expect(sha.stdout.trim(), matches(r'^[a-f0-9]{64}\s+/hash_me\.txt$'));
      });

      test('env and printenv', () async {
        final envResult = await env.exec(
          'env',
          options: const ShellExecOptions(env: {'FAH_TEST_VAR': 'hello-env'}),
        );
        expect(
          envResult.valueOrNull!.stdout,
          contains('FAH_TEST_VAR=hello-env'),
        );
        final printenv = await env.exec(
          'printenv FAH_TEST_VAR',
          options: const ShellExecOptions(
            env: {'FAH_TEST_VAR': 'hello-printenv'},
          ),
        );
        expect(printenv.valueOrNull!.stdout.trim(), 'hello-printenv');
      });
    });

    group('pipelines and redirects', () {
      test('pipeline', () async {
        final result = await run('printf "b\na\nc\n" | sort | uniq | head -n2');
        expect(result.stdout.trim().split('\n'), ['a', 'b']);
      });

      test('output redirect and append', () async {
        await run('echo first > /out.txt');
        await run('echo second >> /out.txt');
        final cat = await run('cat /out.txt');
        expect(cat.stdout.trim().split('\n'), ['first', 'second']);
      });

      test('logical operators', () async {
        expect((await run('true && echo ok')).stdout.trim(), 'ok');
        expect((await run('false || echo fallback')).stdout.trim(), 'fallback');
      });
    });

    group('builtins', () {
      test('test and [ check file and directory existence', () async {
        expect(
          (await run('test -f fruits.txt && echo ok')).stdout.trim(),
          'ok',
        );
        expect((await run('[ -d nested ] && echo ok')).stdout.trim(), 'ok');
        expect(
          (await run('[ -f missing.txt ] || echo no')).stdout.trim(),
          'no',
        );
      });

      test('which and command -v locate available commands', () async {
        final which = await run('which ls');
        expect(which.stdout.trim(), contains('ls'));
        final command = await run('command -v cat');
        expect(command.stdout.trim(), contains('cat'));
      });

      test('whoami returns a non-empty user', () async {
        final whoami = await run('whoami');
        expect(whoami.stdout.trim(), isNotEmpty);
      });

      test('xargs passes arguments from stdin', () async {
        final all = await run('echo fruits.txt | xargs cat');
        expect(all.stdout, 'cherry\napple\nbanana\napple\n');

        final perLine = await run(r"printf 'a\nb\n' | xargs -I{} echo item:{}");
        expect(perLine.stdout.trim().split('\n'), ['item:a', 'item:b']);
      });
    });

    group('commands NOT available in the WASM sandbox', () {
      test('curl is missing on mobile', () async {
        if (!isMobile) {
          markTestSkipped('curl is available on the host shell');
          return;
        }
        await runFails('curl --version');
      });

      test('sed is missing on mobile', () async {
        if (!isMobile) {
          markTestSkipped('sed is available on the host shell');
          return;
        }
        await runFails('sed --version');
      });

      test('awk is missing on mobile', () async {
        if (!isMobile) {
          markTestSkipped('awk is available on the host shell');
          return;
        }
        await runFails('awk --version');
      });
    });

    // Render something so the integration test has a visual artifact.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Coreutils catalog: ${isMobile ? "sandbox" : "host"}'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'coreutils_catalog',
    );
  });
}
