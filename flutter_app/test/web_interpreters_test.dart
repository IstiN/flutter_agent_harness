import 'package:flutter/foundation.dart';
import 'package:fa/memory_shell.dart';
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

  test(
    'qjs evaluates JavaScript via quickjs-emscripten',
    () async {
      var r = await run("qjs -e 'console.log(6 * 7)'");
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout.trim(), '42');

      r = await run("js -e 'console.log(JSON.stringify({ok:true}))'");
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('"ok":true'));

      // Script file from the in-memory FS.
      await env.writeFile(
        '/demo/a.js',
        'const xs = [1,2,3]; console.log(xs.map(x=>x*2).join(","));',
      );
      r = await run('qjs /demo/a.js');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout.trim(), '2,4,6');

      // Errors propagate with a non-zero exit code.
      r = await run("qjs -e 'throw new Error(\"boom\")'");
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('boom'));

      r = await run('qjs --version');
      expect(r.exitCode, 0);
    },
    timeout: const Timeout(Duration(seconds: 120)),
    skip: !kIsWeb,
  );

  test(
    'python3 evaluates code via pyodide',
    () async {
      var r = await run("python3 -c 'print(6 * 7)'");
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout.trim(), '42');

      // Script file with json from the stdlib.
      await env.writeFile(
        '/demo/a.py',
        'import json\nprint(json.dumps({"ok": True}))\n',
      );
      r = await run('python3 /demo/a.py');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('"ok": true'));

      // Errors propagate with a non-zero exit code.
      r = await run("python3 -c 'raise ValueError(\"boom\")'");
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('boom'));

      r = await run('python3 --version');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('3.'));
    },
    timeout: const Timeout(Duration(seconds: 180)),
    skip: !kIsWeb,
  );
}
