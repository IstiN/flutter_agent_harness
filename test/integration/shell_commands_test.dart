// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration test for the local shell: exercises the standard POSIX/bash
/// commands an agent relies on when running against [LocalExecutionEnv].
///
/// This test spawns real processes via `sh -c`, so it is tagged `integration`
/// and excluded from the pre-commit gate.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

extension _ResultGetOrThrow<T, E> on (T, E)? {
  // ignore: unused_element
  T get valueOrNull => this!.$1;
}

void main() {
  late Directory tempDir;
  late LocalExecutionEnv env;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('harness-shell-test-');
    tempDir = Directory(await tempDir.resolveSymbolicLinks());
    env = LocalExecutionEnv(cwd: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Helper: runs [command] and returns the [ShellExecResult] or fails.
  Future<ShellExecResult> run(String command) async {
    final result = await env.exec(
      command,
      options: ShellExecOptions(cwd: tempDir.path),
    );
    if (result.isErr) {
      final error = result.errorOrNull!;
      fail('"$command" failed: $error');
    }
    return result.valueOrNull!;
  }

  /// Helper: runs [command] and expects a non-zero exit or spawn error.
  Future<void> runFails(String command) async {
    final result = await env.exec(
      command,
      options: ShellExecOptions(cwd: tempDir.path),
    );
    if (result.isErr) return;
    expect(result.valueOrNull!.exitCode, isNot(0));
  }

  group('basic shell builtins', () {
    test('echo and printf', () async {
      final echo = await run('echo hello world');
      expect(echo.stdout.trim(), 'hello world');

      final printf = await run(r"printf 'x%sy' z");
      expect(printf.stdout, 'xzy');
    });

    test('true and false exit codes', () async {
      expect((await run('true')).exitCode, 0);
      expect((await run('false')).exitCode, 1);
    });

    test('test / [ builtin', () async {
      expect((await run('test -d /tmp && echo yes')).stdout.trim(), 'yes');
      expect((await run('[ -f /bin/sh ] && echo yes')).stdout.trim(), 'yes');
      expect((await run('[ -d /bin/sh ] || echo no')).stdout.trim(), 'no');
    });
  });

  group('navigation and inspection', () {
    test('pwd and ls', () async {
      final pwd = await run('pwd');
      expect(pwd.stdout.trim(), tempDir.path);

      await run('touch a.txt b.txt');
      final ls = await run('ls');
      expect(ls.stdout, contains('a.txt'));
      expect(ls.stdout, contains('b.txt'));

      final lsL = await run('ls -1');
      final lines = lsL.stdout.trim().split('\n');
      expect(lines, containsAll(['a.txt', 'b.txt']));
    });

    test('cat reads file contents', () async {
      await run('printf "line one\nline two\n" > notes.txt');
      final cat = await run('cat notes.txt');
      expect(cat.stdout, 'line one\nline two\n');
    });
  });

  group('file manipulation', () {
    test('mkdir, rm, cp, mv, touch', () async {
      await run('mkdir -p d/sub');
      expect(Directory('${tempDir.path}/d/sub').existsSync(), isTrue);

      await run('touch d/sub/f.txt');
      expect(File('${tempDir.path}/d/sub/f.txt').existsSync(), isTrue);

      await run('cp d/sub/f.txt d/sub/g.txt');
      expect(File('${tempDir.path}/d/sub/g.txt').existsSync(), isTrue);

      await run('mv d/sub/g.txt d/sub/h.txt');
      expect(File('${tempDir.path}/d/sub/g.txt').existsSync(), isFalse);
      expect(File('${tempDir.path}/d/sub/h.txt').existsSync(), isTrue);

      await run('rm d/sub/h.txt');
      expect(File('${tempDir.path}/d/sub/h.txt').existsSync(), isFalse);

      await run('rm -r d');
      expect(Directory('${tempDir.path}/d').existsSync(), isFalse);
    });
  });

  group('text processing', () {
    setUp(() async {
      await run('printf "cherry\napple\nbanana\napple\n" > fruits.txt');
      await run('printf "one:1\ntwo:2\nthree:3\n" > nums.txt');
    });

    test('head and tail', () async {
      expect((await run('head -n1 fruits.txt')).stdout.trim(), 'cherry');
      expect((await run('tail -n1 fruits.txt')).stdout.trim(), 'apple');
    });

    test('sort and uniq', () async {
      final sorted = await run('sort fruits.txt');
      expect(sorted.stdout.trim().split('\n'), [
        'apple',
        'apple',
        'banana',
        'cherry',
      ]);

      final unique = await run('sort fruits.txt | uniq');
      expect(unique.stdout.trim().split('\n'), ['apple', 'banana', 'cherry']);
    });

    test('wc counts lines/words/bytes', () async {
      final wc = await run('wc -l fruits.txt');
      expect(wc.stdout.trim(), contains('4'));
    });

    test('cut extracts fields', () async {
      final cut = await run("cut -d':' -f2 nums.txt");
      expect(cut.stdout.trim().split('\n'), ['1', '2', '3']);
    });

    test('tr translates characters', () async {
      final tr = await run("echo hello | tr 'a-z' 'A-Z'");
      expect(tr.stdout.trim(), 'HELLO');
    });

    test('paste merges lines', () async {
      final paste = await run('paste -d"," nums.txt fruits.txt');
      final lines = paste.stdout.trim().split('\n');
      expect(lines.first, startsWith('one:1'));
    });
  });

  group('search', () {
    setUp(() async {
      await run('printf "alpha\nbeta\ngamma\n" > words.txt');
    });

    test('grep filters lines', () async {
      final grep = await run('grep et words.txt');
      expect(grep.stdout.trim(), 'beta');
    });

    test('find locates files', () async {
      await run('mkdir -p nested');
      await run('touch nested/target.txt other.txt');
      final find = await run('find . -name target.txt');
      expect(find.stdout.trim(), contains('target.txt'));
    });
  });

  group('path utilities', () {
    test('basename, dirname, realpath, readlink', () async {
      await run('mkdir -p a/b && touch a/b/c.txt');
      expect((await run('basename a/b/c.txt')).stdout.trim(), 'c.txt');
      expect((await run('dirname a/b/c.txt')).stdout.trim(), 'a/b');
      expect(
        (await run('realpath a/b/c.txt')).stdout.trim(),
        '${tempDir.path}/a/b/c.txt',
      );

      await run('ln -s a/b/c.txt link.txt');
      expect((await run('readlink link.txt')).stdout.trim(), 'a/b/c.txt');
    });
  });

  group('arithmetic and sequence', () {
    test('seq generates ranges', () async {
      final seq = await run('seq 1 3');
      expect(seq.stdout.trim().split('\n'), ['1', '2', '3']);
    });
  });

  group('time and platform', () {
    test('date and uname', () async {
      final date = await run('date +%Y');
      expect(date.stdout.trim(), matches(r'^\d{4}$'));

      final uname = await run('uname');
      expect(uname.stdout.trim(), isNotEmpty);
    });

    test('whoami returns a user', () async {
      final whoami = await run('whoami');
      expect(whoami.stdout.trim(), isNotEmpty);
    });
  });

  group('hashing', () {
    test('md5sum and sha256sum', () async {
      await run('printf "hash me" > h.txt');
      final md5 = await run('md5sum h.txt');
      expect(md5.stdout.trim(), matches(r'^[a-f0-9]{32}\s+h\.txt$'));

      final sha = await run('sha256sum h.txt');
      expect(sha.stdout.trim(), matches(r'^[a-f0-9]{64}\s+h\.txt$'));
    });
  });

  group('environment', () {
    test('env and printenv pass variables through', () async {
      final envResult = await env.exec(
        'env',
        options: const ShellExecOptions(env: {'FAH_TEST_VAR': 'hello-env'}),
      );
      expect(envResult.valueOrNull!.stdout, contains('FAH_TEST_VAR=hello-env'));

      final printenv = await env.exec(
        'printenv FAH_TEST_VAR',
        options: const ShellExecOptions(
          env: {'FAH_TEST_VAR': 'hello-printenv'},
        ),
      );
      expect(printenv.valueOrNull!.stdout.trim(), 'hello-printenv');
    });
  });

  group('pipelines and redirections', () {
    test('pipeline chains commands', () async {
      final result = await run('printf "b\na\nc\n" | sort | uniq | head -n2');
      expect(result.stdout.trim().split('\n'), ['a', 'b']);
    });

    test('output redirect creates and overwrites files', () async {
      await run('echo first > out.txt');
      expect(File('${tempDir.path}/out.txt').readAsStringSync(), 'first\n');
      await run('echo second > out.txt');
      expect(File('${tempDir.path}/out.txt').readAsStringSync(), 'second\n');
    });

    test('append redirect appends to files', () async {
      await run('echo one >> out.txt');
      await run('echo two >> out.txt');
      expect(File('${tempDir.path}/out.txt').readAsStringSync(), 'one\ntwo\n');
    });

    test('logical operators short-circuit', () async {
      final and = await run('true && echo ok');
      expect(and.stdout.trim(), 'ok');

      final or = await run('false || echo fallback');
      expect(or.stdout.trim(), 'fallback');

      final semi = await run('echo one; echo two');
      expect(semi.stdout.trim().split('\n'), ['one', 'two']);
    });
  });

  group('commonly used advanced commands', () {
    test('sed edits text', () async {
      final sed = await run("echo 'hello world' | sed 's/world/fah/'");
      expect(sed.stdout.trim(), 'hello fah');
    });

    test('awk extracts columns', () async {
      final awk = await run("printf 'a 1\\nb 2\\n' | awk '{print \$2}'");
      expect(awk.stdout.trim().split('\n'), ['1', '2']);
    });

    test('xargs passes arguments', () async {
      final xargs = await run("printf 'a\nb\n' | xargs -I{} echo item:{}");
      expect(xargs.stdout.trim().split('\n'), ['item:a', 'item:b']);
    });

    test('which locates executables', () async {
      final which = await run('which sh');
      expect(which.stdout.trim(), isNotEmpty);
    });

    test('curl is available on the host', () async {
      final result = await env.exec('curl --version');
      // curl may not be installed in all CI images; skip rather than fail.
      if (result.isErr) {
        markTestSkipped('curl not installed: ${result.errorOrNull}');
        return;
      }
      expect(result.valueOrNull!.exitCode, 0);
      expect(result.valueOrNull!.stdout, contains('curl'));
    });
  });

  group('commands expected to fail gracefully', () {
    test('missing command returns non-zero', () async {
      await runFails('this_command_does_not_exist_12345');
    });

    test('missing file returns non-zero', () async {
      await runFails('cat this_file_does_not_exist_12345.txt');
    });
  });
}
