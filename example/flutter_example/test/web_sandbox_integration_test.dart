// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web sandbox integration suite for the pure-Dart [MemoryShell].
///
/// Mirrors the iOS WASM integration tests (`integration_test/` cannot run on
/// web, and `flutter test --platform chrome` can only load files from
/// `test/`): shell_builtins_test, dart_native_tools_test, wasm_archive_test,
/// sqlite_sandbox_test, plus python/qjs smokes.
///
/// Run with: `flutter test --platform chrome test/web_sandbox_integration_test.dart`
/// On the host VM `createPlatformEnv()` is the LocalExecutionEnv (real
/// processes), not the sandbox, so every test here skips unless kIsWeb.
///
/// curl/wget coverage goes through the `httpClient` injection point on
/// `createPlatformEnv` (a MockClient), because real cross-origin requests
/// from Chrome would be subject to CORS.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Future<ShellExecResult> run(ExecutionEnv env, String command) async {
    final result = await env.exec(command);
    expect(result.isOk, isTrue, reason: result.errorOrNull.toString());
    return result.valueOrNull!;
  }

  group('web sandbox (MemoryShell) command parity', skip: !kIsWeb, () {
    test('every parity command resolves via which', () async {
      final env = await createPlatformEnv();
      for (final command in [
        'awk',
        'curl',
        'find',
        'gunzip',
        'gzip',
        'jq',
        'printf',
        'realpath',
        'rg',
        'sed',
        'sqlite3',
        'tar',
        'unzip',
        'wget',
        'xargs',
        'yq',
        'zip',
      ]) {
        final r = await run(env, 'which $command');
        expect(r.exitCode, 0, reason: '$command not registered');
      }
    });

    // Mirrors integration_test/shell_builtins_test.dart.
    test(
      'cd/pwd/export/grep/realpath builtins behave like the WASM shell',
      () async {
        final env = await createPlatformEnv();

        var r = await run(
          env,
          'mkdir -p /builtins/sub && cd /builtins/sub && pwd',
        );
        expect(r.stdout.trim(), '/builtins/sub');
        r = await run(env, 'pwd');
        expect(r.stdout.trim(), '/builtins/sub');
        r = await run(env, 'cd .. && pwd');
        expect(r.stdout.trim(), '/builtins');
        r = await run(env, 'cd /nope && pwd || pwd');
        expect(r.stdout.trim(), '/builtins');

        r = await run(env, 'export FAH_GREETING=hello && echo \$FAH_GREETING');
        expect(r.stdout.trim(), 'hello');
        r = await run(env, 'echo \${FAH_GREETING} world');
        expect(r.stdout.trim(), 'hello world');
        r = await run(env, 'unset FAH_GREETING && echo "[\$FAH_GREETING]"');
        expect(r.stdout.trim(), '[]');

        await run(env, 'printf "alpha\\nBeta\\ngamma\\n" > /builtins/g.txt');
        r = await run(env, 'grep Beta /builtins/g.txt');
        expect(r.exitCode, 0);
        expect(r.stdout.trim(), 'Beta');
        r = await run(env, 'grep -i beta /builtins/g.txt');
        expect(r.stdout.trim(), 'Beta');
        r = await run(env, 'grep missing /builtins/g.txt');
        expect(r.exitCode, 1);
        r = await run(env, 'grep -c a /builtins/g.txt');
        expect(r.stdout.trim(), '3');
        r = await run(env, 'grep -q gamma /builtins/g.txt');
        expect(r.exitCode, 0);
        expect(r.stdout, isEmpty);

        await run(env, 'touch /builtins/t.txt');
        r = await run(env, 'realpath /builtins/../builtins/t.txt');
        expect(r.exitCode, 0);
        expect(r.stdout.trim(), '/builtins/t.txt');
      },
    );

    // Mirrors integration_test/dart_native_tools_test.dart (MockClient
    // instead of live HTTP; see the library doc comment).
    test('curl/wget against an injected MockClient', () async {
      final env = await createPlatformEnv(
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            expect(request.headers['authorization'], 'Bearer token');
            expect(request.body, '{"name":"fah"}');
            return http.Response('{"id":42}', 201);
          }
          return http.Response('<title>Example Domain</title>', 200);
        }),
      );

      var r = await run(env, 'curl --version');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('curl'));
      expect(r.stdout, contains('fah'));

      r = await run(env, 'curl --help');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Usage: curl'));

      r = await run(env, 'wget --version');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Wget'));

      r = await run(env, 'curl');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('no URL specified'));

      r = await run(env, 'curl -s https://api.example.com/items');
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Example Domain'));
      expect(r.stderr, isEmpty);

      r = await run(
        env,
        r'''curl -X POST -H 'Authorization: Bearer token' -d '{"name":"fah"}' https://api.example.com/items''',
      );
      expect(r.exitCode, 0);
      expect(r.stdout, contains('"id":42'));

      r = await run(env, 'curl -s -o /server.txt https://api.example.com/x');
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(
        (await run(env, 'cat /server.txt')).stdout,
        contains('Example Domain'),
      );

      // Mirrors the wget line in shell_builtins_test.dart.
      r = await run(
        env,
        'wget -q -O /builtins_example.html https://example.com',
      );
      expect(r.exitCode, 0);
      r = await run(env, 'grep -i "Example Domain" /builtins_example.html');
      expect(r.exitCode, 0);
    });

    test('jq/yq filter files and curl pipes into jq', () async {
      final env = await createPlatformEnv(
        httpClient: MockClient(
          (request) async => http.Response('{"result":true}', 200),
        ),
      );
      await env.writeFile(
        '/data.json',
        '{\n'
            '  "name": "fah",\n'
            '  "tags": ["dart", "agent"],\n'
            '  "nested": {"value": 42}\n'
            '}\n',
      );

      expect(
        (await run(env, 'jq . /data.json')).stdout,
        contains('"name": "fah"'),
      );
      expect((await run(env, 'jq .name /data.json')).stdout.trim(), '"fah"');
      expect(
        (await run(env, 'jq .nested.value /data.json')).stdout.trim(),
        '42',
      );
      expect(
        (await run(env, 'jq .tags.[] /data.json')).stdout.trim().split('\n'),
        ['"dart"', '"agent"'],
      );
      expect((await run(env, 'jq .tags.length /data.json')).stdout.trim(), '2');

      await env.writeFile(
        '/data.yaml',
        'name: fah\n'
            'tags:\n'
            '  - dart\n'
            '  - agent\n'
            'nested:\n'
            '  value: 42\n',
      );
      expect(
        (await run(env, 'yq . /data.yaml')).stdout,
        contains('"name": "fah"'),
      );
      expect((await run(env, 'yq .name /data.yaml')).stdout.trim(), '"fah"');
      expect(
        (await run(env, 'yq .nested.value /data.yaml')).stdout.trim(),
        '42',
      );

      final r = await run(
        env,
        'curl -s https://api.example.com/flag | jq .result',
      );
      expect(r.exitCode, 0);
      expect(r.stdout.trim(), 'true');
    });

    // Mirrors integration_test/wasm_archive_test.dart.
    test('sed, awk, tar, gzip, zip/unzip in the web sandbox', () async {
      final env = await createPlatformEnv();
      await env.writeFile('/fruits.txt', 'cherry\napple\nbanana\napple\n');
      await env.writeFile('/words.txt', 'alpha\nbeta\ngamma\n');

      final sed = await run(env, "echo 'hello world' | sed 's/world/earth/'");
      expect(sed.stdout.trim(), 'hello earth');

      final awk = await run(
        env,
        "echo '1 2 3' | awk '{print \$1 + \$2 + \$3}'",
      );
      expect(awk.stdout.trim(), '6');

      await run(env, 'tar -cf /archive.tar /fruits.txt /words.txt');
      await run(env, 'mkdir /tar_out');
      await run(env, 'tar -xf /archive.tar -C /tar_out');
      expect(
        (await run(env, 'cat /tar_out/fruits.txt')).stdout,
        'cherry\napple\nbanana\napple\n',
      );
      await run(env, 'rm -r /tar_out /archive.tar');

      await run(env, 'cp /fruits.txt /fruits_copy.txt');
      await run(env, 'gzip /fruits_copy.txt');
      expect((await run(env, 'ls /')).stdout, contains('fruits_copy.txt.gz'));
      await run(env, 'gzip -d /fruits_copy.txt.gz');
      expect(
        (await run(env, 'cat /fruits_copy.txt')).stdout,
        'cherry\napple\nbanana\napple\n',
      );
      await run(env, 'rm /fruits_copy.txt');

      await run(env, 'zip /archive.zip /fruits.txt /words.txt');
      await run(env, 'mkdir /zip_out');
      await run(env, 'unzip /archive.zip -d /zip_out');
      expect(
        (await run(env, 'cat /zip_out/fruits.txt')).stdout,
        'cherry\napple\nbanana\napple\n',
      );
      await run(env, 'rm -r /zip_out /archive.zip');
    });

    // Mirrors integration_test/sqlite_sandbox_test.dart (sql.js instead of
    // the WASI sqlite3 CLI binary).
    test(
      'sqlite3 works in the web sandbox via sql.js',
      () async {
        final env = await createPlatformEnv();
        await env.exec('rm -f /demo.db');

        var r = await run(env, 'sqlite3 --version');
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout, contains('3.'));

        r = await run(
          env,
          "sqlite3 /demo.db \"CREATE TABLE t(x TEXT, n INTEGER); "
          "INSERT INTO t VALUES ('hello', 42), ('world', 7);\"",
        );
        expect(r.exitCode, 0, reason: r.stderr);

        r = await run(
          env,
          'sqlite3 /demo.db "SELECT x, n*n FROM t ORDER BY n;"',
        );
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout, contains('world|49'));
        expect(r.stdout, contains('hello|1764'));

        // The database file persists across exec calls.
        r = await run(env, 'sqlite3 /demo.db "SELECT count(*) FROM t;"');
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout.trim(), '2');

        // SQL from stdin via a pipe (in-memory database).
        r = await run(env, 'echo "SELECT 40 + 2;" | sqlite3');
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout.trim(), '42');

        // A syntax error surfaces with a non-zero exit code.
        r = await run(env, 'sqlite3 /demo.db "SELEC nonsense;"');
        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains('error'));
      },
      timeout: const Timeout(Duration(seconds: 180)),
    );

    // Mirrors integration_test/qjs_sandbox_test.dart (smoke level; the full
    // coverage lives in web_interpreters_test.dart).
    test(
      'qjs smoke in the web sandbox',
      () async {
        final env = await createPlatformEnv();
        var r = await run(env, "qjs -e 'console.log(6 * 7)'");
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout.trim(), '42');

        r = await run(env, "js -e 'console.log(JSON.stringify({ok:true}))'");
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout, contains('"ok":true'));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    // Mirrors integration_test/python_sandbox_test.dart (smoke level).
    test(
      'python3 smoke in the web sandbox',
      () async {
        final env = await createPlatformEnv();
        var r = await run(env, 'python3 --version');
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout, contains('3.'));

        r = await run(env, "python3 -c 'print(6 * 7)'");
        expect(r.exitCode, 0, reason: r.stderr);
        expect(r.stdout.trim(), '42');
      },
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });
}
