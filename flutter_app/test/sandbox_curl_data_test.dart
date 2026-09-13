// curl `-d`/`--data` argument handling (issue #337 AC3/E1): `@file` reads
// the body from the shell filesystem, `-` reads piped stdin, multiple flags
// join with `&`, bodies stay byte-exact, and oversized bodies fail cleanly.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/sandbox_builtins.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('curl -d @file posts the file bytes verbatim', () async {
    final bodies = <List<int>>[];
    final methods = <String>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        methods.add(request.method);
        bodies.add(request.bodyBytes);
        return http.Response('{"ok":true}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);
    await env.writeFile(
      '/tmp/issue.json',
      '{"title":"t","body":"# Heading\\n\\n- a\\n- b\\n"}',
    );

    final result = await env.exec(
      'curl -s -X POST -H "Content-Type: application/json" '
      '-d @/tmp/issue.json https://api.example.com/issues',
    );
    final r = result.valueOrNull!;
    expect(r.exitCode, 0, reason: r.stderr);
    expect(methods, ['POST']);
    expect(
      utf8.decode(bodies.single),
      '{"title":"t","body":"# Heading\\n\\n- a\\n- b\\n"}',
    );
    expect(r.stdout, contains('"ok":true'));
  });

  test('curl --data with multiline JSON keeps newlines and quotes', () async {
    final bodies = <String>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        bodies.add(request.body);
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final result = await env.exec(
      'curl -s -X POST --data \'{"body":"line1\nline2","q":"x"}\' '
      'https://api.example.com',
    );
    expect(result.valueOrNull!.exitCode, 0);
    // The shell must hand the body over as ONE argument, byte-exact
    // (real newline inside the single-quoted word included).
    expect(bodies.single, '{"body":"line1\nline2","q":"x"}');
  });

  test('multiple -d flags join with & and imply POST', () async {
    final requests = <RequestRecord>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        requests.add(
          RequestRecord(request.method, request.body, request.url.toString()),
        );
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final result = await env.exec(
      "curl -s -d 'name=fah' -d 'role=agent' https://api.example.com",
    );
    expect(result.valueOrNull!.exitCode, 0);
    expect(requests.single.method, 'POST');
    expect(requests.single.body, 'name=fah&role=agent');
  });

  test('curl -d @- reads the request body from piped stdin', () async {
    final bodies = <String>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        bodies.add(request.body);
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final result = await env.exec(
      'echo \'{"piped":true}\' | curl -s -X POST -d @- https://api.example.com',
    );
    expect(result.valueOrNull!.exitCode, 0);
    expect(bodies.single, '{"piped":true}\n');
  });

  test('curl -d @missing-file fails with exit 26 and names the file', () async {
    final shell = MemoryShell(
      httpClient: MockClient(
        (request) async => http.Response('{}', 200),
      ),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final result = await env.exec(
      'curl -s -X POST -d @/tmp/nope.json https://api.example.com',
    );
    final r = result.valueOrNull!;
    expect(r.exitCode, 26);
    expect(r.stderr, contains('/tmp/nope.json'));
    expect(r.stderr, contains('No such file'));
  });

  test('curl rejects bodies over the 1 MiB sandbox cap (E1)', () async {
    var requested = false;
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        requested = true;
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);
    await env.writeFile('/tmp/big.bin', 'x' * (1024 * 1024 + 1));

    final result = await env.exec(
      'curl -s -X POST -d @/tmp/big.bin https://api.example.com',
    );
    final r = result.valueOrNull!;
    expect(r.exitCode, 26);
    expect(r.stderr, contains('1 MiB'));
    expect(requested, isFalse, reason: 'the request must not be sent');
  });

  test('binary bodies survive byte-for-byte (no UTF-8 re-encoding)', () async {
    final bytes = <int>[0x00, 0x01, 0xff, 0xfe, 0x80, 0x7f, 0x0d, 0x0a];
    final bodies = <List<int>>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        bodies.add(request.bodyBytes);
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);
    await env.writeBinaryFile('/tmp/blob.bin', Uint8List.fromList(bytes));

    final result = await env.exec(
      'curl -s -X POST -d @/tmp/blob.bin https://api.example.com',
    );
    expect(result.valueOrNull!.exitCode, 0);
    expect(bodies.single, bytes);
  });
  test('curl --data-raw @file sends the value literally (no file read)', () async {
    final bodies = <String>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        bodies.add(request.body);
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final result = await env.exec(
      "curl -s --data-raw @/tmp/nope.json https://api.example.com",
    );
    final r = result.valueOrNull!;
    expect(r.exitCode, 0, reason: r.stderr);
    expect(bodies.single, '@/tmp/nope.json');
  });

  test('explicit -X GET with -d sends GET with a body (curl semantics)', () async {
    final methods = <String>[];
    final bodies = <String>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        methods.add(request.method);
        bodies.add(request.body);
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final result = await env.exec(
      "curl -s -X GET -d 'payload' https://api.example.com",
    );
    final r = result.valueOrNull!;
    expect(r.exitCode, 0, reason: r.stderr);
    expect(methods, ['GET']);
    expect(bodies.single, 'payload');
  });

  test('binary stdin bytes ride -d @- byte-for-byte', () async {
    final bodies = <List<int>>[];
    final shell = MemoryShell(
      httpClient: MockClient((request) async {
        bodies.add(request.bodyBytes);
        return http.Response('{}', 200);
      }),
    );
    final env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);

    final bytes = Uint8List.fromList(
      [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff],
    );
    final builtins = SandboxBuiltins(
      httpClient: MockClient((request) async {
        bodies.add(request.bodyBytes);
        return http.Response('{}', 200);
      }),
      readTextFile: (path) async => null,
      writeBinaryFile: (path, content) async {},
      readBinaryFile: (path) async => null,
    );
    final result = await builtins.curl(
      ['-s', '-d', '@-', 'https://api.example.com'],
      stdinBytes: bytes,
    );
    expect(result.exitCode, 0, reason: utf8.decode(result.stderr));
    expect(bodies.single, bytes);
  });
}

class RequestRecord {
  RequestRecord(this.method, this.body, this.url);
  final String method;
  final String body;
  final String url;
}
