import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/memory_shell.dart';
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
}
