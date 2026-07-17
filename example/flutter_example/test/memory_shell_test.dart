import 'package:flutter_agent_example/memory_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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
    var r = await run('python3 --version');
    expect(r.exitCode, 127);
    expect(r.stderr, contains('command not found'));

    r = await run('node --version');
    expect(r.exitCode, 127);
    expect(r.stderr, contains('command not found'));

    // git IS available in the web sandbox (local porcelain only).
    r = await run('git --version');
    expect(r.exitCode, 0);
    expect(r.stdout, contains('git version'));
  });
}
