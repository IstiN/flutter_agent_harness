// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host-run integration suite for the mobile WASM sandbox toolchain
/// (issue #337): python HTTP bridge, curl data bodies, the write<->bash
/// filesystem seam, SIGPIPE noise and the end-to-end issue-creation flow.
///
/// Needs the wasmtime dynamic library and the flutter_app asset bundle:
/// `WASM_RUN_DART_DYNAMIC_LIBRARY=<libwasm_run_dart.so> flutter test test/wasm_sandbox_toolchain_test.dart`
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:fa/sandbox/env_factory_io.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Keeps real sockets but maps every https URL to the local plain-HTTP
/// server: proves the https scheme flows through the python bridge and that
/// TLS termination happens on the host side (the WASI build has no TLS).
/// The wrapped client is created before the test binding installs its socket
/// mocks, so the requests actually leave the process.
class HttpsToLoopbackClient extends http.BaseClient {
  HttpsToLoopbackClient(this._inner, this.port);
  final http.Client _inner;
  final int port;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url.replace(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
    );
    final req = http.Request(request.method, uri)
      ..headers.addAll(request.headers)
      ..followRedirects = false;
    if (request is http.Request && request.bodyBytes.isNotEmpty) {
      req.bodyBytes = request.bodyBytes;
    }
    final resp = await _inner.send(req);
    return http.StreamedResponse(
      resp.stream,
      resp.statusCode,
      headers: resp.headers,
      reasonPhrase: resp.reasonPhrase,
    );
  }
}

void main() {
  final realClient = http.Client();
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({
      SandboxedExecutionEnv env,
      HttpServer server,
      List<String> seen,
    })
  >
  boot() async {
    final dir = await Directory.systemTemp.createTemp('fah_337_it');
    final seen = <String>[];
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seen.add(
        '${req.method} ${req.uri.path} ct='
        '${req.headers.contentType} body=<$body>',
      );
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"number":42,"title":"t","ok":true,"n":42}');
      await req.response.close();
    });
    final shell = await WasiSandboxShell.load(
      workingDirectory: '/',
      sandboxHostPath: dir.path,
      httpClient: HttpsToLoopbackClient(realClient, server.port),
    );
    final env = SandboxedExecutionEnv(
      LocalExecutionEnv(cwd: dir.path, shell: shell),
      dir.path,
    );
    addTearDown(() async {
      await server.close();
      await dir.delete(recursive: true);
    });
    return (env: env, server: server, seen: seen);
  }

  test('python urllib https through the bridge, scripted via write tool',
      () async {
    final (:env, :server, :seen) = await boot();
    await env.writeFile(
      '/tmp/create_issue.py',
      'import json\n'
          'import urllib.request\n'
          'payload = json.dumps('
          '{"title": "From sandbox", "body": "# Markdown\\n\\n- a\\n"}).encode()\n'
          'req = urllib.request.Request(\n'
          '    "https://api.example.com/repos/o/r/issues",\n'
          '    data=payload,\n'
          '    headers={"Content-Type": "application/json"},\n'
          ')\n'
          'with urllib.request.urlopen(req) as resp:\n'
          '    result = json.load(resp)\n'
          'print("created", result["number"])\n',
    );
    final r = await env.exec('python3 /tmp/create_issue.py');
    final res = r.valueOrNull!;
    expect(res.exitCode, 0, reason: res.stderr);
    expect(res.stdout, contains('created 42'));
    expect(seen, hasLength(1));
    expect(seen.single, startsWith('POST /repos/o/r/issues'));
    expect(seen.single, contains('application/json'));
    expect(seen.single, contains('"title": "From sandbox"'));
    // Control lines never leak into the captured stdout.
    expect(res.stdout.contains('\x01'), isFalse);
  });

  test('curl posts a JSON body from a written file byte-exact (AC3)',
      () async {
    final (:env, :server, :seen) = await boot();
    await env.writeFile(
      '/tmp/issue.json',
      '{"title":"t","body":"# Heading\\n\\n- a\\n- b\\n"}',
    );
    final r = await env.exec(
      'curl -s -X POST -H "Content-Type: application/json" '
      '-d @/tmp/issue.json https://api.example.com/issues',
    );
    final res = r.valueOrNull!;
    expect(res.exitCode, 0, reason: res.stderr);
    expect(res.stdout, contains('"number":42'));
    expect(seen.single, contains('ct=application/json'));
    expect(seen.single, contains('"body":"# Heading\\n\\n- a\\n- b\\n"}'));
  });

  test('curl -d inline multiline JSON reaches the server intact (AC3)',
      () async {
    final (:env, :server, :seen) = await boot();
    final r = await env.exec(
      'curl -s -X POST -H "Content-Type: application/json" '
      '-d \'{"body":"line1\nline2"}\' https://api.example.com',
    );
    expect(r.valueOrNull!.exitCode, 0, reason: r.valueOrNull!.stderr);
    expect(seen.single, contains('"body":"line1\nline2"}'));
  });

  test('write tool and bash see one filesystem (AC4)', () async {
    final (:env, :server, :seen) = await boot();
    await env.writeFile('/tmp/seam.txt', 'from-write');
    final wc = await env.exec('wc -c /tmp/seam.txt');
    expect(wc.valueOrNull!.stdout.trim(), startsWith('10'));

    final back = await env.exec('echo from-bash > /tmp/back.txt');
    expect(back.valueOrNull!.exitCode, 0);
    final read = await env.readTextFile('/tmp/back.txt');
    expect(read.valueOrNull, 'from-bash\n');
  });

  test('binary files survive the seam in both directions (E5)', () async {
    final (:env, :server, :seen) = await boot();
    final bytes = <int>[0, 1, 2, 255, 254, 10, 13, 128, 7, 0];
    await env.writeBinaryFile(
      '/tmp/blob.bin',
      Uint8List.fromList(bytes),
    );
    final r = await env.exec(
      'cat /tmp/blob.bin > /tmp/copy.bin && wc -c /tmp/copy.bin',
    );
    expect(r.valueOrNull!.stdout.trim(), startsWith('10'));
    final round = await env.readBinaryFile('/tmp/copy.bin');
    expect(round.valueOrNull, bytes);
  });

  test('pipeline SIGPIPE noise is translated away (AC5)', () async {
    final (:env, :server, :seen) = await boot();
    await env.writeFile(
      '/tmp/big.txt',
      List.filled(5000, 'hello world').join('\n'),
    );
    final r = await env.exec('grep o /tmp/big.txt | head -1');
    final res = r.valueOrNull!;
    expect(res.exitCode, 0);
    expect(res.stdout.trim(), 'hello world');
    expect(res.stderr, isEmpty, reason: res.stderr);
  });

  test('agent-style issue creation: write, curl, jq (AC7)', () async {
    final (:env, :server, :seen) = await boot();
    await env.writeFile(
      '/tmp/issue.json',
      '{"title":"t","body":"# Markdown body\\n\\n- item\\n"}',
    );
    final r = await env.exec(
      'curl -s -X POST -H "Content-Type: application/json" '
      '-d @/tmp/issue.json https://api.example.com/repos/o/r/issues '
      '| jq -r .number',
    );
    final res = r.valueOrNull!;
    expect(res.exitCode, 0, reason: res.stderr);
    expect(res.stdout.trim(), '42');
    expect(seen.single, contains('"title":"t"'));
  });
}
