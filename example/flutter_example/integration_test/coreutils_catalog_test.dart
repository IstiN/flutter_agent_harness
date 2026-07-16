// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration test that catalogs the shell commands available in the mobile
/// WASM sandbox (uutils coreutils + ripgrep + findutils + sed + awk + tar +
/// gzip + zip/unzip) and the host shell on desktop.
///
/// Run on an iOS/Android simulator or device:
///   flutter test integration_test/coreutils_catalog_test.dart
///
/// The test deliberately exercises commands an agent typically relies on, and
/// asserts that commands not shipped in the sandbox (curl) fail so the prompt
/// can be tuned accordingly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ExecutionEnv> makeEnv() async => createPlatformEnv();

  Future<ShellExecResult> runCmd(ExecutionEnv env, String command) async {
    final result = await env.exec(command);
    if (result.isErr) {
      fail('"$command" failed: ${result.errorOrNull!}');
    }
    return result.valueOrNull!;
  }

  Future<void> runFails(ExecutionEnv env, String command) async {
    final result = await env.exec(command);
    if (result.isErr) return;
    expect(result.valueOrNull!.exitCode, isNot(0));
  }

  testWidgets('basics and file operations', (tester) async {
    final env = await makeEnv();
    final sandbox = env is LocalExecutionEnv ? env.cwd : '/';

    await env.writeFile('fruits.txt', 'cherry\napple\nbanana\napple\n');
    await env.createDir('nested');
    await env.writeFile('nested/target.txt', 'found me');

    final echo = await runCmd(env, 'echo hello world');
    expect(echo.stdout.trim(), 'hello world');
    final printf = await runCmd(env, r"printf 'x%sy' z");
    expect(printf.stdout, 'xzy');

    expect((await runCmd(env, 'true')).exitCode, 0);
    expect((await runCmd(env, 'false')).exitCode, 1);

    final pwd = await runCmd(env, 'pwd');
    expect(pwd.stdout.trim(), isMobile ? '/' : sandbox);

    final ls = await runCmd(env, 'ls /');
    expect(ls.stdout, contains('fruits.txt'));
    expect(ls.stdout, contains('nested'));

    final cat = await runCmd(env, 'cat /fruits.txt');
    expect(cat.stdout, 'cherry\napple\nbanana\napple\n');

    await runCmd(env, 'mkdir /d /d/sub');
    await runCmd(env, 'touch /d/sub/f.txt');
    await runCmd(env, 'cp /d/sub/f.txt /d/sub/g.txt');
    await runCmd(env, 'mv /d/sub/g.txt /d/sub/h.txt');
    await runCmd(env, 'rm /d/sub/h.txt');
    await runCmd(env, 'rm -r /d');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('basics/file ops'))),
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('text processing', (tester) async {
    final env = await makeEnv();
    await env.writeFile('fruits.txt', 'cherry\napple\nbanana\napple\n');
    await env.writeFile('nums.txt', 'one:1\ntwo:2\nthree:3\n');
    await env.writeFile('words.txt', 'alpha\nbeta\ngamma\n');

    expect((await runCmd(env, 'head -n1 /fruits.txt')).stdout.trim(), 'cherry');
    expect((await runCmd(env, 'tail -n1 /fruits.txt')).stdout.trim(), 'apple');

    final sorted = await runCmd(env, 'sort /fruits.txt');
    expect(sorted.stdout.trim().split('\n'), [
      'apple',
      'apple',
      'banana',
      'cherry',
    ]);
    final unique = await runCmd(env, 'sort /fruits.txt | uniq');
    expect(unique.stdout.trim().split('\n'), ['apple', 'banana', 'cherry']);

    final wc = await runCmd(env, 'wc -l /fruits.txt');
    expect(wc.stdout.trim(), contains('4'));

    final cut = await runCmd(env, "cut -d':' -f2 /nums.txt");
    expect(cut.stdout.trim().split('\n'), ['1', '2', '3']);

    final tr = await runCmd(env, "echo hello | tr '[:lower:]' '[:upper:]'");
    expect(tr.stdout.trim(), 'HELLO');

    final sed = await runCmd(env, "echo 'hello world' | sed 's/world/earth/'");
    expect(sed.stdout.trim(), 'hello earth');

    final awk = await runCmd(
      env,
      "echo '1 2 3' | awk '{print \$1 + \$2 + \$3}'",
    );
    expect(awk.stdout.trim(), '6');

    final paste = await runCmd(env, 'paste -d"," /nums.txt /fruits.txt');
    expect(paste.stdout, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('text processing'))),
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('search, path, sequence, hashing', (tester) async {
    final env = await makeEnv();
    await env.createDir('nested');
    await env.writeFile('nested/target.txt', 'found me');
    await env.writeFile('hash_me.txt', 'hash me');

    if (isMobile) {
      final rg = await runCmd(env, 'rg et /words.txt');
      expect(rg.stdout.trim(), 'beta');
    }

    final find = await runCmd(env, 'find / -name target.txt');
    expect(find.stdout.trim(), contains('target.txt'));

    await runCmd(env, 'mkdir -p /a/b');
    await runCmd(env, 'touch /a/b/c.txt');
    expect((await runCmd(env, 'basename /a/b/c.txt')).stdout.trim(), 'c.txt');
    expect((await runCmd(env, 'dirname /a/b/c.txt')).stdout.trim(), '/a/b');
    await runCmd(env, 'rm -r /a');

    final seq = await runCmd(env, 'seq 1 3');
    expect(seq.stdout.trim().split('\n'), ['1', '2', '3']);

    final date = await runCmd(env, 'date +%Y');
    expect(date.stdout.trim(), matches(r'^\d{4}$'));
    final uname = await runCmd(env, 'uname');
    expect(uname.stdout.trim(), isNotEmpty);

    final md5 = await runCmd(env, 'md5sum /hash_me.txt');
    expect(md5.stdout.trim(), matches(r'^[a-f0-9]{32}\s+/hash_me\.txt$'));
    final sha = await runCmd(env, 'sha256sum /hash_me.txt');
    expect(sha.stdout.trim(), matches(r'^[a-f0-9]{64}\s+/hash_me\.txt$'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('search/path/hash'))),
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('env, pipelines, builtins', (tester) async {
    final env = await makeEnv();
    await env.writeFile('fruits.txt', 'cherry\napple\nbanana\napple\n');

    final envResult = await env.exec(
      'env',
      options: const ShellExecOptions(env: {'FAH_TEST_VAR': 'hello-env'}),
    );
    expect(envResult.valueOrNull!.stdout, contains('FAH_TEST_VAR=hello-env'));

    final printenv = await env.exec(
      'printenv FAH_TEST_VAR',
      options: const ShellExecOptions(env: {'FAH_TEST_VAR': 'hello-printenv'}),
    );
    expect(printenv.valueOrNull!.stdout.trim(), 'hello-printenv');

    final pipeline = await runCmd(
      env,
      'printf "b\na\nc\n" | sort | uniq | head -n2',
    );
    expect(pipeline.stdout.trim().split('\n'), ['a', 'b']);

    await runCmd(env, 'echo first > /out.txt');
    await runCmd(env, 'echo second >> /out.txt');
    final cat = await runCmd(env, 'cat /out.txt');
    expect(cat.stdout.trim().split('\n'), ['first', 'second']);

    expect((await runCmd(env, 'true && echo ok')).stdout.trim(), 'ok');
    expect(
      (await runCmd(env, 'false || echo fallback')).stdout.trim(),
      'fallback',
    );

    expect(
      (await runCmd(env, 'test -f fruits.txt && echo ok')).stdout.trim(),
      'ok',
    );
    expect((await runCmd(env, '[ -d nested ] && echo ok')).stdout.trim(), 'ok');

    final which = await runCmd(env, 'which ls');
    expect(which.stdout.trim(), contains('ls'));
    final command = await runCmd(env, 'command -v cat');
    expect(command.stdout.trim(), contains('cat'));

    final whoami = await runCmd(env, 'whoami');
    expect(whoami.stdout.trim(), isNotEmpty);

    final all = await runCmd(env, 'echo fruits.txt | xargs cat');
    expect(all.stdout, 'cherry\napple\nbanana\napple\n');
    final perLine = await runCmd(
      env,
      r"printf 'a\nb\n' | xargs -I{} echo item:{}",
    );
    expect(perLine.stdout.trim().split('\n'), ['item:a', 'item:b']);

    if (isMobile) {
      await runFails(env, 'curl --version');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('env/pipes/builtins'))),
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('archive and compression', (tester) async {
    final env = await makeEnv();
    await env.writeFile('fruits.txt', 'cherry\napple\nbanana\napple\n');
    await env.writeFile('words.txt', 'alpha\nbeta\ngamma\n');

    await runCmd(env, 'tar -cf /archive.tar /fruits.txt /words.txt');
    await runCmd(env, 'mkdir /tar_out');
    await runCmd(env, 'tar -xf /archive.tar -C /tar_out');
    expect(
      (await runCmd(env, 'cat /tar_out/fruits.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await runCmd(env, 'rm -r /tar_out /archive.tar');

    await runCmd(env, 'cp /fruits.txt /fruits_copy.txt');
    await runCmd(env, 'gzip /fruits_copy.txt');
    expect((await runCmd(env, 'ls /')).stdout, contains('fruits_copy.txt.gz'));
    await runCmd(env, 'gzip -d /fruits_copy.txt.gz');
    expect(
      (await runCmd(env, 'cat /fruits_copy.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await runCmd(env, 'rm /fruits_copy.txt');

    await runCmd(env, 'zip /archive.zip /fruits.txt /words.txt');
    await runCmd(env, 'mkdir /zip_out');
    await runCmd(env, 'unzip /archive.zip -d /zip_out');
    expect(
      (await runCmd(env, 'cat /zip_out/fruits.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await runCmd(env, 'rm -r /zip_out /archive.zip');

    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'coreutils_catalog',
    );
  });
}
