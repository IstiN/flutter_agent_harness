// Behavior tests for the shell scripting subset (if/for/assignments/
// command substitution) shared by WasiSandboxShell and MemoryShell via
// lib/sandbox/shell_script.dart. Runs against MemoryShell — fast, no WASM.

import 'package:fa/sandbox/memory_shell.dart';
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

  Future<ShellExecResult> runAllowFail(String command) async {
    final result = await env.exec(command);
    return result.isOk
        ? result.valueOrNull!
        : ShellExecResult(
            stdout: '',
            stderr: result.errorOrNull!.message,
            exitCode: 1,
          );
  }

  group('if / elif / else / fi', () {
    test('true branch runs, else skipped', () async {
      final r = await run('if [ -n "x" ]; then echo YES; else echo NO; fi');
      expect(r.stdout.trim(), 'YES');
      expect(r.exitCode, 0);
    });

    test('false branch falls to else', () async {
      final r = await run('if [ -z "x" ]; then echo YES; else echo NO; fi');
      expect(r.stdout.trim(), 'NO');
    });

    test('elif chain picks the first true condition', () async {
      final r = await run(
        'if [ 1 -eq 2 ]; then echo A; elif [ 2 -eq 2 ]; then echo B; '
        'else echo C; fi',
      );
      expect(r.stdout.trim(), 'B');
    });

    test('condition may be any pipeline (ls exit code)', () async {
      await run('mkdir -p /apps');
      final ok = await run('if ls /apps; then echo FOUND; fi');
      expect(ok.stdout.trim(), contains('FOUND'));
      final missing = await run('if ls /nope; then echo FOUND; fi');
      expect(missing.stdout.trim(), isNot(contains('FOUND')));
      expect(missing.exitCode, 0, reason: 'if without else yields 0');
    });

    test('multiline script', () async {
      final r = await run(
        'if [ -n "x" ]\nthen\n  echo MULTI\nelse\n  echo NO\nfi',
      );
      expect(r.stdout.trim(), 'MULTI');
    });

    test('nested if inside for/if works', () async {
      final r = await run(
        'if [ -n "x" ]; then if [ -z "" ]; then echo INNER; fi; fi',
      );
      expect(r.stdout.trim(), 'INNER');
    });
  });

  group('for / do / done', () {
    test('iterates a literal list', () async {
      final r = await run('for f in a b c; do echo \$f; done');
      expect(r.stdout.trim().split('\n'), ['a', 'b', 'c']);
    });

    test('iterates over command substitution', () async {
      final r = await run('for i in \$(echo 1 2 3); do echo "n\$i"; done');
      expect(r.stdout.trim().split('\n'), ['n1', 'n2', 'n3']);
    });

    test('empty list runs zero iterations and exits 0', () async {
      final r = await run('for i in; do echo X; done');
      expect(r.stdout.trim(), '');
      expect(r.exitCode, 0);
    });

    test('loop variable expands inside the body', () async {
      final r = await run('for f in one two; do echo "file: \$f"; done');
      expect(r.stdout.trim().split('\n'), ['file: one', 'file: two']);
    });

    test('multiline for loop', () async {
      final r = await run('for f in x y\ndo\n  echo \$f\ndone');
      expect(r.stdout.trim().split('\n'), ['x', 'y']);
    });
  });

  group('command substitution', () {
    test(r'$() substitutes stdout', () async {
      final r = await run('echo "count: \$(echo hi | wc -c)"');
      expect(r.stdout.trim(), startsWith('count: '));
      expect(r.stdout.trim(), isNot(contains(r'$(')));
    });

    test('backquotes work too', () async {
      final r = await run('echo "val: `echo deep`"');
      expect(r.stdout.trim(), 'val: deep');
    });

    test('nested substitution', () async {
      final r = await run('echo \$(echo \$(echo deep))');
      expect(r.stdout.trim(), 'deep');
    });

    test('trailing newlines are trimmed', () async {
      final r = await run('echo "[\$(echo a; echo b)]"');
      expect(r.stdout.trim(), '[a\nb]');
    });

    test('failing inner command substitutes empty and continues', () async {
      final r = await run('echo "[\$(ls /definitely-missing)]"; echo ok');
      expect(r.stdout.trim(), endsWith('ok'));
    });

    test(r'assignment from substitution: X=$(...)', () async {
      final r = await run('X=\$(echo hi | tr a-z A-Z); echo \$X');
      expect(r.stdout.trim(), 'HI');
    });

    test('unquoted substitution splits into words', () async {
      final r = await run('for w in \$(echo "a b c"); do echo \$w; done');
      expect(r.stdout.trim().split('\n'), ['a', 'b', 'c']);
    });

    test('quoted substitution does not split', () async {
      final r = await run('X="\$(echo "a b")"; echo "\$X"');
      expect(r.stdout.trim(), 'a b');
    });

    test('single quotes keep it literal', () async {
      final r = await run("echo '\$(echo no)'");
      expect(r.stdout.trim(), r'$(echo no)');
    });
  });

  group('assignments', () {
    test('plain assignment then expansion', () async {
      final r = await run('A=hello; echo \$A');
      expect(r.stdout.trim(), 'hello');
    });

    test('multiple assignments in one statement', () async {
      final r = await run('A=1 B=2; echo "\$A\$B"');
      expect(r.stdout.trim(), '12');
    });

    test('assignment honors double-quoted values', () async {
      final r = await run('A="two words"; echo "\$A"');
      expect(r.stdout.trim(), 'two words');
    });
  });

  group('script errors stay clean', () {
    test('missing fi is a parse error naming fi', () async {
      final r = await runAllowFail('if true; then echo x');
      expect(r.stderr, contains('fi'));
    });

    test('stray done is a parse error', () async {
      final r = await runAllowFail('done');
      expect(r.stderr, contains('done'));
    });

    test('stray fi is a parse error', () async {
      final r = await runAllowFail('fi');
      expect(r.stderr, contains('fi'));
    });

    test('unmatched substitution is a parse error', () async {
      final r = await runAllowFail(r'echo $(echo hi');
      expect(r.stderr, isNotEmpty);
    });

    test('substitution depth bomb fails cleanly', () async {
      var cmd = 'echo deep';
      for (var i = 0; i < 12; i++) {
        cmd = 'echo \$($cmd)';
      }
      final r = await runAllowFail(cmd);
      expect(r.stderr, contains('nested too deeply'));
    });
  });
}
