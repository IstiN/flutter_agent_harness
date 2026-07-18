import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/memory_shell.dart';
import 'package:flutter_agent_example/sandbox_builtins.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    final shell = MemoryShell();
    env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);
  });

  Future<ShellExecResult> run(String command) async {
    final result = await env.exec(command);
    expect(result.isOk, isTrue, reason: result.errorOrNull.toString());
    return result.valueOrNull!;
  }

  /// Builds an env whose shell talks HTTP through [client] (a MockClient).
  Future<
    ({MemoryExecutionEnv env, Future<ShellExecResult> Function(String) run})
  >
  mockEnv(http.Client client) async {
    final shell = MemoryShell(httpClient: client);
    final mockEnv = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(mockEnv);
    Future<ShellExecResult> run(String command) async {
      final result = await mockEnv.exec(command);
      expect(result.isOk, isTrue, reason: result.errorOrNull.toString());
      return result.valueOrNull!;
    }

    return (env: mockEnv, run: run);
  }

  test('echo/cat with redirect round-trips through the in-memory FS', () async {
    var r = await run('echo hello web > /a.txt && cat /a.txt');
    expect(r.exitCode, 0);
    expect(r.stdout, 'hello web\n');
  });

  test('file operations: mkdir/touch/cp/mv/ls/rm/rmdir', () async {
    expect((await run('mkdir -p /d/sub')).exitCode, 0);
    expect((await run('touch /d/sub/f.txt')).exitCode, 0);
    expect((await run('cp /d/sub/f.txt /d/g.txt')).exitCode, 0);
    expect((await run('mv /d/g.txt /d/h.txt')).exitCode, 0);
    var r = await run('ls /d');
    expect(r.stdout, contains('h.txt'));
    expect(r.stdout, contains('sub'));
    expect((await run('rm /d/h.txt')).exitCode, 0);
    expect((await run('rm -r /d/sub')).exitCode, 0);
    r = await run('ls /d');
    expect(r.stdout.trim(), isEmpty);
    expect((await run('mkdir /x && rmdir /x')).exitCode, 0);
  });

  test('cd/pwd persist working directory and resolve relative paths', () async {
    expect((await run('mkdir -p /work/app')).exitCode, 0);
    var r = await run('cd /work/app && pwd');
    expect(r.stdout.trim(), '/work/app');
    // Persists across exec calls.
    r = await run('pwd');
    expect(r.stdout.trim(), '/work/app');
    r = await run('echo data > rel.txt && cat rel.txt');
    expect(r.stdout.trim(), 'data');
    r = await run('cat /work/app/rel.txt');
    expect(r.stdout.trim(), 'data');
    r = await run('cd .. && pwd');
    expect(r.stdout.trim(), '/work');
    r = await run('cd /nope || pwd');
    expect(r.stdout.trim(), '/work');
  });

  test('export/unset and \$VAR expansion work like bash', () async {
    var r = await run('export GREETING=hi && echo \$GREETING');
    expect(r.stdout.trim(), 'hi');
    r = await run('echo "\${GREETING} there"');
    expect(r.stdout.trim(), 'hi there');
    r = await run("echo '\$GREETING'");
    expect(r.stdout.trim(), '\$GREETING');
    r = await run('export');
    expect(r.stdout, contains('declare -x GREETING="hi"'));
    r = await run('unset GREETING && echo "[\$GREETING]"');
    expect(r.stdout.trim(), '[]');
  });

  test('grep supports -i/-v/-n/-c/-l/-q, pipes, and exit codes', () async {
    await run('echo -e "alpha\nBeta\ngamma" > /g.txt');

    var r = await run('grep Beta /g.txt');
    expect(r.exitCode, 0);
    expect(r.stdout.trim(), 'Beta');

    r = await run('grep -i beta /g.txt');
    expect(r.stdout.trim(), 'Beta');

    r = await run('grep missing /g.txt');
    expect(r.exitCode, 1);

    r = await run('grep -c a /g.txt');
    expect(r.stdout.trim(), '3');

    r = await run('grep -v alpha /g.txt');
    expect(r.stdout, 'Beta\ngamma\n');

    r = await run('grep -n gamma /g.txt');
    expect(r.stdout.trim(), '3:gamma');

    r = await run('echo -e "x\ny\nz" | grep y');
    expect(r.stdout.trim(), 'y');

    r = await run('grep -q alpha /g.txt');
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
  });

  test('head/tail/wc/sort/tr/basename/dirname utilities', () async {
    await run('echo -e "b\na\nc\nd" > /u.txt');
    var r = await run('head -n 2 /u.txt');
    expect(r.stdout, 'b\na\n');
    r = await run('tail -n 2 /u.txt');
    expect(r.stdout, 'c\nd\n');
    r = await run('wc -l /u.txt');
    expect(r.stdout.trim(), startsWith('4'));
    r = await run('sort /u.txt');
    expect(r.stdout, 'a\nb\nc\nd\n');
    r = await run('echo "a-b-c" | tr "-" ","');
    expect(r.stdout.trim(), 'a,b,c');
    r = await run('basename /x/y/file.txt');
    expect(r.stdout.trim(), 'file.txt');
    r = await run('dirname /x/y/file.txt');
    expect(r.stdout.trim(), '/x/y');
  });

  test('which/command -v/test/whoami/env', () async {
    var r = await run('which grep');
    expect(r.exitCode, 0);
    r = await run('which nosuchtool');
    expect(r.exitCode, 1);
    r = await run('command -v ls');
    expect(r.exitCode, 0);
    r = await run('whoami');
    expect(r.stdout.trim(), 'fah');
    r = await run('env');
    expect(r.stdout, contains('PATH=/bin'));
    r = await run('echo x > /f.txt && test -f /f.txt');
    expect(r.exitCode, 0);
    r = await run('[ -d / ]');
    expect(r.exitCode, 0);
    r = await run('[ 1 -eq 2 ]');
    expect(r.exitCode, 1);
  });

  test('logical operators and pipelines chain correctly', () async {
    var r = await run('false && echo no || echo yes');
    expect(r.stdout.trim(), 'yes');
    r = await run('true && echo ok');
    expect(r.stdout.trim(), 'ok');
    r = await run('echo -e "z\ny\nx" | sort | head -n 1');
    expect(r.stdout.trim(), 'x');
    r = await run('echo "one" > /p.txt; cat /p.txt | wc -l');
    expect(r.stdout.trim(), startsWith('1'));
  });

  test('unavailable commands report 127 command not found', () async {
    var r = await run('node --version');
    expect(r.exitCode, 127);
    expect(r.stderr, contains('command not found'));

    r = await run('make --version');
    expect(r.exitCode, 127);
    expect(r.stderr, contains('command not found'));

    // git IS available in the web sandbox (local porcelain only).
    r = await run('git --version');
    expect(r.exitCode, 0);
    expect(r.stdout, contains('git version'));
  });

  group('ssh/scp/sftp (registered on web, exit 127)', () {
    test('which resolves the ssh commands', () async {
      for (final name in ['ssh', 'scp', 'sftp']) {
        final r = await run('which $name');
        expect(r.exitCode, 0, reason: '$name not registered');
        expect(r.stdout, contains('/bin/$name'));
      }
    });

    test('ssh/scp/sftp exit 127: raw TCP is impossible on web', () async {
      for (final command in [
        'ssh user@example.com echo hi',
        'scp file.txt user@example.com:/tmp/',
        'sftp user@example.com',
      ]) {
        final r = await run(command);
        expect(r.exitCode, 127, reason: command);
        expect(r.stderr, contains('not available in the web sandbox'));
        expect(r.stderr, contains('raw TCP'));
      }
    });
  });

  group('lua (registered on web, exit 127)', () {
    test('which resolves lua', () async {
      final r = await run('which lua');
      expect(r.exitCode, 0, reason: 'lua not registered');
      expect(r.stdout, contains('/bin/lua'));
    });

    test('lua exits 127: no browser-hosted build', () async {
      for (final command in [
        'lua -v',
        "lua -e 'print(1)'",
        'lua /script.lua',
      ]) {
        final r = await run(command);
        expect(r.exitCode, 127, reason: command);
        expect(r.stderr, contains('command not found'));
      }
    });
  });

  test('printf formats directives and repeats for extra args', () async {
    var r = await run(r"printf 'hello %s\n' world");
    expect(r.exitCode, 0);
    expect(r.stdout, 'hello world\n');

    r = await run(r'printf "%s %d\n" answer 42');
    expect(r.stdout, 'answer 42\n');

    r = await run(r'printf "%s\n" a b c');
    expect(r.stdout, 'a\nb\nc\n');

    r = await run(r'printf "x\ty\n"');
    expect(r.stdout, 'x\ty\n');

    // No trailing newline unless the format asks for one.
    r = await run(r"printf 'bare'");
    expect(r.stdout, 'bare');
  });

  test('sed substitutes, prints addressed lines, and edits in place', () async {
    var r = await run("echo 'hello world' | sed 's/world/earth/'");
    expect(r.stdout.trim(), 'hello earth');

    r = await run("echo 'a a a' | sed 's/a/b/g'");
    expect(r.stdout.trim(), 'b b b');

    r = await run("echo 'foo bar' | sed -e 's/foo/baz/' -e 's/bar/qux/'");
    expect(r.stdout.trim(), 'baz qux');

    await run("printf 'one\ntwo\nthree\n' > /s.txt");
    r = await run("sed -n '2p' /s.txt");
    expect(r.stdout.trim(), 'two');

    r = await run("sed -n '1,2p' /s.txt");
    expect(r.stdout, 'one\ntwo\n');

    r = await run("sed -n '\$p' /s.txt");
    expect(r.stdout.trim(), 'three');

    r = await run("sed '2s/two/TWO/' /s.txt");
    expect(r.stdout, 'one\nTWO\nthree\n');

    r = await run("sed -i 's/two/2/' /s.txt && cat /s.txt");
    expect(r.stdout, 'one\n2\nthree\n');

    r = await run("echo 'a-b' | sed 's/-/+/'");
    expect(r.stdout.trim(), 'a+b');
  });

  test('awk prints fields, NR/NF, arithmetic, and pattern matches', () async {
    var r = await run("echo '1 2 3' | awk '{print \$1 + \$2 + \$3}'");
    expect(r.exitCode, 0, reason: r.stderr);
    expect(r.stdout.trim(), '6');

    r = await run("echo 'a b c' | awk '{print \$2}'");
    expect(r.stdout.trim(), 'b');

    r = await run("echo 'a b c' | awk '{print}'");
    expect(r.stdout.trim(), 'a b c');

    r = await run("printf 'x 1\\ny 2\\n' | awk '{print \$2}'");
    expect(r.stdout, '1\n2\n');

    r = await run("printf 'x 1\\ny 2\\n' | awk '{print NR, \$0}'");
    expect(r.stdout, '1 x 1\n2 y 2\n');

    r = await run("echo 'a b c' | awk '{print NF}'");
    expect(r.stdout.trim(), '3');

    r = await run("printf 'a:b:c\\n' | awk -F: '{print \$2}'");
    expect(r.stdout.trim(), 'b');

    r = await run("printf 'foo 1\\nbar 2\\n' | awk '/bar/ {print \$1}'");
    expect(r.stdout.trim(), 'bar');

    await run("printf 'm 10\\nn 20\\n' > /awk.txt");
    r = await run("awk '{print \$1}' /awk.txt");
    expect(r.stdout, 'm\nn\n');
  });

  test('find walks the sandbox recursively with -name/-type filters', () async {
    await run(
      'mkdir -p /proj/src /proj/docs && '
      'touch /proj/src/a.dart /proj/src/b.txt /proj/docs/readme.md',
    );

    var r = await run('find /proj');
    expect(r.exitCode, 0, reason: r.stderr);
    expect(
      r.stdout,
      '/proj\n'
      '/proj/docs\n'
      '/proj/docs/readme.md\n'
      '/proj/src\n'
      '/proj/src/a.dart\n'
      '/proj/src/b.txt\n',
    );

    r = await run('cd /proj && find .');
    expect(
      r.stdout,
      '.\n./docs\n./docs/readme.md\n./src\n./src/a.dart\n./src/b.txt\n',
    );

    r = await run("find /proj -name '*.dart'");
    expect(r.stdout.trim(), '/proj/src/a.dart');

    r = await run('find /proj -type d');
    expect(r.stdout, '/proj\n/proj/docs\n/proj/src\n');

    r = await run('find /proj -type f -name "*.txt"');
    expect(r.stdout.trim(), '/proj/src/b.txt');

    r = await run('find /nope');
    expect(r.exitCode, 1);
  });

  test('xargs appends stdin tokens to a command with -n batching', () async {
    var r = await run("echo 'a b c' | xargs echo");
    expect(r.exitCode, 0, reason: r.stderr);
    expect(r.stdout.trim(), 'a b c');

    // Default utility is echo.
    r = await run("printf 'x\\n' | xargs");
    expect(r.stdout.trim(), 'x');

    r = await run("printf 'a\\nb\\nc\\n' | xargs -n 1 echo");
    expect(r.stdout, 'a\nb\nc\n');

    r = await run("printf 'a b c d\\n' | xargs -n 2 echo");
    expect(r.stdout, 'a b\nc d\n');

    // Commands that need the filesystem dispatch through the shell itself.
    r = await run("echo /xd1 /xd2 | xargs mkdir && ls / | grep xd");
    expect(r.stdout, contains('xd1'));
    expect(r.stdout, contains('xd2'));
  });

  test('realpath normalizes paths and fails on missing files', () async {
    await run('mkdir -p /builtins && touch /builtins/t.txt');

    var r = await run('realpath /builtins/../builtins/t.txt');
    expect(r.exitCode, 0, reason: r.stderr);
    expect(r.stdout.trim(), '/builtins/t.txt');

    r = await run('cd /builtins && realpath ./t.txt');
    expect(r.stdout.trim(), '/builtins/t.txt');

    r = await run('realpath /nope.txt');
    expect(r.exitCode, 1);
    expect(r.stderr, contains('No such file'));
  });

  test('rg is an alias of the grep implementation', () async {
    await run("printf 'alpha\\nBeta\\ngamma\\n' > /rg.txt");

    var r = await run('rg Beta /rg.txt');
    expect(r.exitCode, 0);
    expect(r.stdout.trim(), 'Beta');

    r = await run('rg -i beta /rg.txt');
    expect(r.stdout.trim(), 'Beta');

    r = await run('rg missing /rg.txt');
    expect(r.exitCode, 1);

    r = await run("printf 'x\\ny\\nz\\n' | rg y");
    expect(r.stdout.trim(), 'y');
  });

  test('curl --version/--help and usage errors', () async {
    final m = await mockEnv(
      MockClient((request) async => http.Response('', 200)),
    );

    var r = await m.run('curl --version');
    expect(r.exitCode, 0);
    expect(r.stdout, contains('curl'));
    expect(r.stdout, contains('fah'));

    r = await m.run('curl --help');
    expect(r.exitCode, 0);
    expect(r.stdout, contains('Usage: curl'));

    r = await m.run('wget --version');
    expect(r.exitCode, 0);
    expect(r.stdout, contains('Wget'));

    r = await m.run('curl');
    expect(r.exitCode, 2);
    expect(r.stderr, contains('no URL specified'));
  });

  test('curl GET/POST and -o against a MockClient', () async {
    final m = await mockEnv(
      MockClient((request) async {
        if (request.method == 'POST') {
          expect(request.headers['authorization'], 'Bearer token');
          expect(request.body, '{"name":"fah"}');
          return http.Response('{"id":42}', 201);
        }
        return http.Response('{"items":[1,2,3]}', 200);
      }),
    );

    var r = await m.run('curl -s https://api.example.com/items');
    expect(r.exitCode, 0);
    expect(r.stdout, contains('"items":[1,2,3]'));
    expect(r.stderr, isEmpty);

    r = await m.run('curl https://api.example.com/items');
    expect(r.stderr, contains('HTTP 200'));

    r = await m.run(
      r'''curl -X POST -H 'Authorization: Bearer token' -d '{"name":"fah"}' https://api.example.com/items''',
    );
    expect(r.exitCode, 0);
    expect(r.stdout, contains('"id":42'));

    r = await m.run('curl -s -o /server.txt https://api.example.com/hello');
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
    final cat = await m.run('cat /server.txt');
    expect(cat.stdout.trim(), '{"items":[1,2,3]}');

    // wget is a thin alias over curl.
    r = await m.run('wget -q -O /w.txt https://api.example.com/hello');
    expect(r.exitCode, 0);
    expect((await m.run('cat /w.txt')).stdout.trim(), '{"items":[1,2,3]}');
  });

  test('jq extracts fields and arrays from files and stdin', () async {
    await env.writeFile(
      '/data.json',
      '{\n'
          '  "name": "fah",\n'
          '  "tags": ["dart", "agent"],\n'
          '  "nested": {"value": 42}\n'
          '}\n',
    );

    expect((await run('jq . /data.json')).stdout, contains('"name": "fah"'));
    expect((await run('jq .name /data.json')).stdout.trim(), '"fah"');
    expect((await run('jq .nested.value /data.json')).stdout.trim(), '42');
    expect((await run('jq .tags.[] /data.json')).stdout.trim().split('\n'), [
      '"dart"',
      '"agent"',
    ]);
    expect((await run('jq .tags.length /data.json')).stdout.trim(), '2');

    // jq reads JSON from a pipe.
    final r = await run("echo '{\"result\":true}' | jq .result");
    expect(r.exitCode, 0, reason: r.stderr);
    expect(r.stdout.trim(), 'true');

    final missing = await run('jq . /nope.json');
    expect(missing.exitCode, isNot(0));
  });

  test('yq converts YAML to JSON and filters', () async {
    await env.writeFile(
      '/data.yaml',
      'name: fah\n'
          'tags:\n'
          '  - dart\n'
          '  - agent\n'
          'nested:\n'
          '  value: 42\n',
    );

    expect((await run('yq . /data.yaml')).stdout, contains('"name": "fah"'));
    expect((await run('yq .name /data.yaml')).stdout.trim(), '"fah"');
    expect((await run('yq .nested.value /data.yaml')).stdout.trim(), '42');

    final r = await run("printf 'a: 1\\n' | yq .a");
    expect(r.stdout.trim(), '1');
  });

  test('curl pipes into jq', () async {
    final m = await mockEnv(
      MockClient((request) async => http.Response('{"result":true}', 200)),
    );
    final r = await m.run('curl -s https://api.example.com/flag | jq .result');
    expect(r.exitCode, 0);
    expect(r.stdout.trim(), 'true');
  });

  test('tar/gzip/zip/unzip round-trip through package:archive', () async {
    await env.writeFile('/fruits.txt', 'cherry\napple\nbanana\napple\n');
    await env.writeFile('/words.txt', 'alpha\nbeta\ngamma\n');

    // tar
    var r = await run('tar -cf /archive.tar /fruits.txt /words.txt');
    expect(r.exitCode, 0, reason: r.stderr);
    await run('mkdir /tar_out');
    r = await run('tar -xf /archive.tar -C /tar_out');
    expect(r.exitCode, 0, reason: r.stderr);
    expect(
      (await run('cat /tar_out/fruits.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await run('rm -r /tar_out /archive.tar');

    // tar with a directory member
    await run('mkdir -p /tardir/sub && echo nested > /tardir/sub/n.txt');
    r = await run('tar -cf /d.tar /tardir');
    expect(r.exitCode, 0, reason: r.stderr);
    r = await run('mkdir /d_out && tar -xf /d.tar -C /d_out');
    expect(r.exitCode, 0, reason: r.stderr);
    expect((await run('cat /d_out/tardir/sub/n.txt')).stdout.trim(), 'nested');
    await run('rm -r /d_out /d.tar /tardir');

    // gzip compresses in place and removes the original.
    await run('cp /fruits.txt /fruits_copy.txt');
    r = await run('gzip /fruits_copy.txt');
    expect(r.exitCode, 0, reason: r.stderr);
    expect((await run('ls /')).stdout, contains('fruits_copy.txt.gz'));
    expect((await run('ls /')).stdout, isNot(contains('fruits_copy.txt\n')));
    r = await run('gzip -d /fruits_copy.txt.gz');
    expect(r.exitCode, 0, reason: r.stderr);
    expect(
      (await run('cat /fruits_copy.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );

    // gunzip alias.
    r = await run('gzip /words.txt && gunzip /words.txt.gz');
    expect(r.exitCode, 0, reason: r.stderr);
    expect((await run('cat /words.txt')).stdout, 'alpha\nbeta\ngamma\n');

    // zip/unzip
    r = await run('zip /archive.zip /fruits.txt /words.txt');
    expect(r.exitCode, 0, reason: r.stderr);
    await run('mkdir /zip_out');
    r = await run('unzip /archive.zip -d /zip_out');
    expect(r.exitCode, 0, reason: r.stderr);
    expect(
      (await run('cat /zip_out/fruits.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await run('rm -r /zip_out /archive.zip');

    // zip -r with a directory
    await run('mkdir -p /zdir && echo deep > /zdir/deep.txt');
    r = await run('zip -r /z.zip /zdir');
    expect(r.exitCode, 0, reason: r.stderr);
    r = await run('mkdir /z_out && unzip /z.zip -d /z_out');
    expect(r.exitCode, 0, reason: r.stderr);
    expect((await run('cat /z_out/zdir/deep.txt')).stdout.trim(), 'deep');
  });

  test(
    'sqlite3 --version follows platform availability',
    () async {
      final r = await run('sqlite3 --version');
      if (kIsWeb) {
        // sql.js loads from the CDN in the browser.
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout, contains('3.'));
      } else {
        expect(r.exitCode, 127);
        expect(r.stderr, contains('command not found'));
      }
    },
    timeout: kIsWeb ? const Timeout(Duration(seconds: 180)) : null,
  );

  group('diff/patch', () {
    test('diff exits 0 with empty output for identical files', () async {
      await run("printf 'one\ntwo\nthree\n' > /a.txt");
      await run('cp /a.txt /b.txt');
      final r = await run('diff /a.txt /b.txt');
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(r.stderr, isEmpty);
    });

    test(
      'diff prints unified output and exits 1 for different files',
      () async {
        await run("printf 'one\ntwo\nthree\n' > /a.txt");
        await run("printf 'one\nTWO\nthree\nfour\n' > /b.txt");
        final r = await run('diff /a.txt /b.txt');
        expect(r.exitCode, 1);
        expect(r.stdout, contains('--- /a.txt\n'));
        expect(r.stdout, contains('+++ /b.txt\n'));
        expect(r.stdout, contains('@@ -1,3 +1,4 @@\n'));
        expect(r.stdout, contains('-two\n'));
        expect(r.stdout, contains('+TWO\n'));
        expect(r.stdout, contains('+four\n'));
        // -u is the default already; being explicit changes nothing.
        final explicit = await run('diff -u /a.txt /b.txt');
        expect(explicit.stdout, r.stdout);
      },
    );

    test(
      'diff -q reports briefly; missing files exit 2, -N treats as empty',
      () async {
        await run("printf 'x\n' > /a.txt");
        await run("printf 'y\n' > /b.txt");
        var r = await run('diff -q /a.txt /b.txt');
        expect(r.exitCode, 1);
        expect(r.stdout, 'Files /a.txt and /b.txt differ\n');
        r = await run('diff -q /a.txt /a.txt');
        expect(r.exitCode, 0);
        expect(r.stdout, isEmpty);
        r = await run('diff /missing.txt /a.txt');
        expect(r.exitCode, 2);
        expect(r.stderr, contains('No such file or directory'));
        r = await run('diff -N /missing.txt /a.txt');
        expect(r.exitCode, 1);
        expect(r.stdout, contains('+x\n'));
      },
    );

    test('diff reads an operand from stdin via -', () async {
      await run("printf 'one\ntwo\nthree\n' > /a.txt");
      final r = await run("printf 'one\nTWO\nthree\n' | diff /a.txt -");
      expect(r.exitCode, 1);
      expect(r.stdout, contains('--- /a.txt\n'));
      expect(r.stdout, contains('+++ -\n'));
      expect(r.stdout, contains('-two\n'));
      expect(r.stdout, contains('+TWO\n'));
    });

    test('diff marks a missing trailing newline', () async {
      await run("printf 'one\ntwo' > /a.txt");
      await run("printf 'one\ntwo\n' > /b.txt");
      final r = await run('diff /a.txt /b.txt');
      expect(r.exitCode, 1);
      expect(r.stdout, contains('\\ No newline at end of file'));
    });

    test('patch applies a diff produced by diff (round-trip)', () async {
      await run("printf 'one\ntwo\nthree\n' > /orig.txt");
      await run("printf 'one\nTWO\nthree\nfour\n' > /mod.txt");
      await run('cp /orig.txt /copy.txt');
      final p = await run('diff /orig.txt /mod.txt | patch /copy.txt');
      expect(p.exitCode, 0, reason: p.stderr);
      expect(p.stdout, 'patching file /copy.txt\n');
      final cmp = await run('diff /copy.txt /mod.txt');
      expect(cmp.exitCode, 0, reason: cmp.stdout);
    });

    test(
      'patch reads the patch from a redirect, a file operand, or -i',
      () async {
        await run("printf 'a\nb\nc\n' > /orig.txt");
        await run("printf 'a\nB\nc\n' > /mod.txt");
        await run('diff /orig.txt /mod.txt > /fix.diff');

        await run('cp /orig.txt /t1.txt');
        var r = await run('patch /t1.txt < /fix.diff');
        expect(r.exitCode, 0, reason: r.stderr);
        expect((await run('diff /t1.txt /mod.txt')).exitCode, 0);

        await run('cp /orig.txt /t2.txt');
        r = await run('patch /t2.txt /fix.diff');
        expect(r.exitCode, 0, reason: r.stderr);
        expect((await run('diff /t2.txt /mod.txt')).exitCode, 0);

        await run('cp /orig.txt /t3.txt');
        r = await run('patch -i /fix.diff /t3.txt');
        expect(r.exitCode, 0, reason: r.stderr);
        expect((await run('diff /t3.txt /mod.txt')).exitCode, 0);
      },
    );

    test('patch -p1 strips git-style a/ b/ prefixes', () async {
      await run("printf 'hello\n' > /file.txt");
      await run(
        "printf '%s\n' '--- a/file.txt' '+++ b/file.txt' '@@ -1 +1 @@' "
        "'-hello' '+goodbye' > /g.diff",
      );
      final r = await run('patch -p1 < /g.diff');
      expect(r.exitCode, 0, reason: r.stderr);
      expect((await run('cat /file.txt')).stdout, 'goodbye\n');
    });

    test('patch round-trip preserves a missing trailing newline', () async {
      await run("printf 'one\ntwo' > /orig.txt");
      await run("printf 'one\nTWO' > /mod.txt");
      await run('cp /orig.txt /copy.txt');
      final p = await run('diff /orig.txt /mod.txt | patch /copy.txt');
      expect(p.exitCode, 0, reason: p.stderr);
      expect((await run('cat /copy.txt')).stdout, 'one\nTWO');
    });

    test(
      'patch exits 1 on failed hunks and leaves the file untouched',
      () async {
        await run("printf 'one\ntwo\nthree\n' > /orig.txt");
        await run("printf 'one\nTWO\nthree\n' > /mod.txt");
        await run('diff /orig.txt /mod.txt > /fix.diff');
        await run("printf 'completely\ndifferent\n' > /other.txt");
        final r = await run('patch /other.txt < /fix.diff');
        expect(r.exitCode, 1);
        expect(r.stderr, contains('FAILED'));
        expect((await run('cat /other.txt')).stdout, 'completely\ndifferent\n');
      },
    );

    test('patch exits 2 on missing target and on garbage input', () async {
      await run("printf 'one\ntwo\nthree\n' > /orig.txt");
      await run("printf 'one\nTWO\nthree\n' > /mod.txt");
      await run('diff /orig.txt /mod.txt > /fix.diff');
      var r = await run('patch /missing.txt < /fix.diff');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('No such file or directory'));
      r = await run('echo garbage | patch /orig.txt');
      expect(r.exitCode, 2);
      r = await run('patch /orig.txt /missing.diff');
      expect(r.exitCode, 2);
    });
  });

  group('netdiag (nslookup/dig/whois)', () {
    /// Builds a canned DNS-over-HTTPS JSON body (cloudflare-dns.com shape).
    String dohJson(int status, List<Map<String, Object>> answers) {
      return jsonEncode({
        'Status': status,
        if (answers.isNotEmpty) 'Answer': answers,
      });
    }

    Map<String, Object> dohRecord(String name, int type, String data) {
      return {'name': name, 'type': type, 'TTL': 300, 'data': data};
    }

    test('which resolves the netdiag commands', () async {
      for (final name in ['nslookup', 'dig', 'whois']) {
        final r = await run('which $name');
        expect(r.exitCode, 0, reason: '$name not registered');
      }
    });

    test('nslookup resolves A and AAAA via DoH', () async {
      final m = await mockEnv(
        MockClient((request) async {
          expect(request.url.host, 'cloudflare-dns.com');
          expect(request.headers['Accept'], 'application/dns-json');
          expect(request.url.queryParameters['name'], 'example.com');
          final type = request.url.queryParameters['type'];
          return http.Response(
            dohJson(0, [
              if (type == 'A')
                dohRecord('example.com.', 1, '93.184.216.34')
              else
                dohRecord(
                  'example.com.',
                  28,
                  '2606:2800:220:1:248:1893:25c8:1946',
                ),
            ]),
            200,
          );
        }),
      );

      final r = await m.run('nslookup example.com');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('Server:  cloudflare-dns.com'));
      expect(r.stdout, contains('Name:    example.com.'));
      expect(r.stdout, contains('Address: 93.184.216.34'));
      expect(r.stdout, contains('Address: 2606:2800:220:1:248:1893:25c8:1946'));
    });

    test('nslookup of an IPv4 literal does a PTR query', () async {
      final m = await mockEnv(
        MockClient((request) async {
          expect(request.url.queryParameters['name'], '1.1.1.1.in-addr.arpa');
          expect(request.url.queryParameters['type'], 'PTR');
          return http.Response(
            dohJson(0, [
              dohRecord('1.1.1.1.in-addr.arpa.', 12, 'one.one.one.one.'),
            ]),
            200,
          );
        }),
      );

      final r = await m.run('nslookup 1.1.1.1');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('name = one.one.one.one.'));
    });

    test(
      'nslookup reports NXDOMAIN and transport failure with exit 1',
      () async {
        var m = await mockEnv(
          MockClient((request) async => http.Response(dohJson(3, []), 200)),
        );
        var r = await m.run('nslookup nope.invalid');
        expect(r.exitCode, 1);
        expect(r.stderr, contains("server can't find nope.invalid: NXDOMAIN"));

        m = await mockEnv(
          MockClient((request) async => http.Response('oops', 502)),
        );
        r = await m.run('nslookup example.com');
        expect(r.exitCode, 1);
        expect(r.stderr, contains('HTTP 502'));

        r = await run('nslookup');
        expect(r.exitCode, 2);
        expect(r.stderr, contains('usage: nslookup'));
      },
    );

    test('dig prints the status line and answer section', () async {
      final m = await mockEnv(
        MockClient((request) async {
          expect(request.url.queryParameters['type'], 'A');
          return http.Response(
            dohJson(0, [dohRecord('example.com.', 1, '93.184.216.34')]),
            200,
          );
        }),
      );

      final r = await m.run('dig example.com');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains(';; status: NOERROR'));
      expect(r.stdout, contains(';; SERVER: cloudflare-dns.com'));
      expect(r.stdout, contains(';; ANSWER SECTION:'));
      expect(r.stdout, contains('example.com.\t300\tIN\tA\t93.184.216.34'));
    });

    test('dig supports an explicit query type and -x reverse', () async {
      final m = await mockEnv(
        MockClient((request) async {
          final name = request.url.queryParameters['name'];
          final type = request.url.queryParameters['type'];
          if (type == 'MX') {
            return http.Response(
              dohJson(0, [
                dohRecord('example.com.', 15, '10 mail.example.com.'),
              ]),
              200,
            );
          }
          expect(name, '1.1.1.1.in-addr.arpa');
          expect(type, 'PTR');
          return http.Response(
            dohJson(0, [
              dohRecord('1.1.1.1.in-addr.arpa.', 12, 'one.one.one.one.'),
            ]),
            200,
          );
        }),
      );

      var r = await m.run('dig example.com MX');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('IN\tMX\t10 mail.example.com.'));

      r = await m.run('dig -x 1.1.1.1');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('IN\tPTR\tone.one.one.one.'));
    });

    test('dig keeps exit 0 on NXDOMAIN and rejects bad usage', () async {
      final m = await mockEnv(
        MockClient((request) async => http.Response(dohJson(3, []), 200)),
      );

      var r = await m.run('dig nope.invalid');
      expect(r.exitCode, 0);
      expect(r.stdout, contains(';; status: NXDOMAIN'));
      expect(r.stdout, isNot(contains('ANSWER SECTION')));

      r = await m.run('dig');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('usage: dig'));
      r = await m.run('dig example.com BOGUS');
      expect(r.exitCode, 2);
      expect(r.stderr, contains("unknown query type 'BOGUS'"));
      r = await m.run('dig -x example.com');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('-x expects an IPv4 address'));
    });

    test('whois summarizes RDAP JSON on the web path', () async {
      final m = await mockEnv(
        MockClient((request) async {
          expect(request.url.host, 'rdap.org');
          if (request.url.path == '/domain/example.com') {
            return http.Response(
              jsonEncode({
                'objectClassName': 'domain',
                'ldhName': 'EXAMPLE.COM',
                'handle': '2336799_DOMAIN_COM-VRSN',
                'status': ['client delete prohibited'],
                'entities': [
                  {
                    'objectClassName': 'entity',
                    'handle': '376',
                    'roles': ['registrar'],
                    'publicIds': [
                      {'type': 'IANA Registrar ID', 'identifier': '376'},
                    ],
                    'vcardArray': [
                      'vcard',
                      [
                        ['version', {}, 'text', '4.0'],
                        [
                          'fn',
                          {},
                          'text',
                          'RESERVED-Internet Assigned Numbers Authority',
                        ],
                      ],
                    ],
                  },
                ],
                'events': [
                  {
                    'eventAction': 'registration',
                    'eventDate': '1995-08-14T04:00:00Z',
                  },
                  {
                    'eventAction': 'expiration',
                    'eventDate': '2026-08-13T04:00:00Z',
                  },
                ],
                'nameservers': [
                  {
                    'objectClassName': 'nameserver',
                    'ldhName': 'A.IANA-SERVERS.NET',
                  },
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/ip/1.1.1.1');
          return http.Response(
            jsonEncode({
              'objectClassName': 'ip network',
              'handle': 'NET-1-1-1-0-1',
              'name': 'APNIC-LABS',
              'startAddress': '1.1.1.0',
              'endAddress': '1.1.1.255',
              'country': 'AU',
            }),
            200,
          );
        }),
      );

      var r = await m.run('whois example.com');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('Domain Name: EXAMPLE.COM'));
      expect(r.stdout, contains('Registry Domain ID: 2336799_DOMAIN_COM-VRSN'));
      expect(r.stdout, contains('Domain Status: client delete prohibited'));
      expect(
        r.stdout,
        contains(
          'Registrar: RESERVED-Internet Assigned Numbers Authority '
          '(IANA ID: 376)',
        ),
      );
      expect(r.stdout, contains('Creation Date: 1995-08-14T04:00:00Z'));
      expect(r.stdout, contains('Registry Expiry Date: 2026-08-13T04:00:00Z'));
      expect(r.stdout, contains('Name Server: A.IANA-SERVERS.NET'));

      r = await m.run('whois 1.1.1.1');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('NetRange: 1.1.1.0 - 1.1.1.255'));
      expect(r.stdout, contains('NetName: APNIC-LABS'));
      expect(r.stdout, contains('Country: AU'));
    });

    test('whois exits 1 on RDAP errors and 2 on usage', () async {
      final m = await mockEnv(
        MockClient((request) async => http.Response('', 404)),
      );
      var r = await m.run('whois nope.invalid');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('whois: nope.invalid: not found'));

      r = await m.run('whois');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('usage: whois'));
    });

    test('whois over TCP follows one referral (canned text)', () async {
      SandboxBuiltins tcpBuiltins(
        Future<String> Function(String query, String server) connector,
      ) {
        return SandboxBuiltins(
          readTextFile: (path) async => null,
          writeBinaryFile: (path, bytes) async {},
          whoisConnector: connector,
        );
      }

      // Domain: IANA is asked for the TLD (whois: key, as in real IANA
      // responses); the registry gets the full domain.
      final exchanges = <String>[];
      final following = tcpBuiltins((query, server) async {
        exchanges.add('$server?$query');
        if (server == 'whois.iana.org') {
          return 'domain:       COM\nwhois:        whois.verisign-grs.com\n';
        }
        return 'Domain Name: EXAMPLE.COM\nRegistrar: IANA\n';
      });
      var r = await following.whois(['example.com']);
      expect(r.exitCode, 0);
      expect(exchanges, [
        'whois.iana.org?com',
        'whois.verisign-grs.com?example.com',
      ]);
      expect(utf8.decode(r.stdout), contains('Domain Name: EXAMPLE.COM'));

      // IP: the literal goes to IANA verbatim and the refer: key is used.
      exchanges.clear();
      final ipReferral = tcpBuiltins((query, server) async {
        exchanges.add('$server?$query');
        if (server == 'whois.iana.org') {
          return 'refer:        whois.apnic.net\n';
        }
        return 'inetnum:        1.1.1.0 - 1.1.1.255\n';
      });
      r = await ipReferral.whois(['1.1.1.1']);
      expect(r.exitCode, 0);
      expect(exchanges, ['whois.iana.org?1.1.1.1', 'whois.apnic.net?1.1.1.1']);
      expect(utf8.decode(r.stdout), contains('inetnum:'));

      // Without a referral the IANA response is printed as-is.
      final noReferral = tcpBuiltins(
        (query, server) async => 'TLD information only\n',
      );
      r = await noReferral.whois(['example.void']);
      expect(r.exitCode, 0);
      expect(utf8.decode(r.stdout), 'TLD information only\n');

      // A dead referral target still yields the IANA response.
      final deadReferral = tcpBuiltins((query, server) async {
        if (server == 'whois.iana.org') {
          return 'refer: whois.dead.example\n';
        }
        throw StateError('connection refused');
      });
      r = await deadReferral.whois(['example.com']);
      expect(r.exitCode, 0);
      expect(utf8.decode(r.stdout), 'refer: whois.dead.example\n');

      // A dead whois.iana.org is a hard failure.
      final deadIana = tcpBuiltins(
        (query, server) async => throw StateError('connection refused'),
      );
      r = await deadIana.whois(['example.com']);
      expect(r.exitCode, 1);
      expect(utf8.decode(r.stderr), contains('whois.iana.org'));
    });
  });
}
