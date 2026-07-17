// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration test for Dart-native shell builtins: curl, jq, yq.
library;

import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ExecutionEnv> makeEnv({http.Client? httpClient}) async =>
      createPlatformEnv(httpClient: httpClient);

  Future<ShellExecResult> runCmd(ExecutionEnv env, String command) async {
    final result = await env.exec(command);
    if (result.isErr) {
      fail('"$command" failed: ${result.errorOrNull!}');
    }
    return result.valueOrNull!;
  }

  testWidgets('curl --version and --help exit 0', (tester) async {
    final env = await makeEnv();

    var result = await runCmd(env, 'curl --version');
    expect(result.exitCode, 0);
    expect(result.stdout, contains('curl'));
    expect(result.stdout, contains('fah'));

    result = await runCmd(env, 'curl --help');
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Usage: curl'));

    result = await runCmd(env, 'wget --version');
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Wget'));

    result = await runCmd(env, 'curl');
    expect(result.exitCode, 2);
    expect(result.stderr, contains('no URL specified'));
  });

  testWidgets('curl GET returns body and status', (tester) async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.example.com/items');
      expect(request.method, 'GET');
      return http.Response('{"items":[1,2,3]}', 200);
    });
    final env = await makeEnv(httpClient: client);

    final result = await runCmd(env, 'curl -s https://api.example.com/items');
    expect(result.exitCode, 0);
    expect(result.stdout, contains('"items":[1,2,3]'));
    expect(result.stderr, isEmpty);
  });

  testWidgets('curl POST with body and headers', (tester) async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.example.com/items');
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer token');
      expect(request.headers['content-type'], 'application/json');
      expect(request.body, '{"name":"fah"}');
      return http.Response('{"id":42}', 201);
    });
    final env = await makeEnv(httpClient: client);

    final result = await runCmd(
      env,
      r'''curl -X POST -H 'Authorization: Bearer token' -H 'Content-Type: application/json' -d '{"name":"fah"}' https://api.example.com/items''',
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains('"id":42'));
  });

  testWidgets('curl -o writes response to file', (tester) async {
    final client = MockClient(
      (request) async => http.Response('hello from server', 200),
    );
    final env = await makeEnv(httpClient: client);

    final result = await runCmd(
      env,
      'curl -s -o /server.txt https://api.example.com/hello',
    );
    expect(result.exitCode, 0);
    expect(result.stdout, isEmpty);

    final cat = await runCmd(env, 'cat /server.txt');
    expect(cat.stdout.trim(), 'hello from server');
  });

  testWidgets('jq extracts fields and arrays', (tester) async {
    final env = await makeEnv();
    await env.writeFile(
      'data.json',
      '{\n'
          '  "name": "fah",\n'
          '  "tags": ["dart", "agent"],\n'
          '  "nested": {"value": 42}\n'
          '}\n',
    );

    expect(
      (await runCmd(env, 'jq . /data.json')).stdout,
      contains('"name": "fah"'),
    );
    expect((await runCmd(env, 'jq .name /data.json')).stdout.trim(), '"fah"');
    expect(
      (await runCmd(env, 'jq .nested.value /data.json')).stdout.trim(),
      '42',
    );
    expect(
      (await runCmd(env, 'jq .tags.[] /data.json')).stdout.trim().split('\n'),
      ['"dart"', '"agent"'],
    );
    expect(
      (await runCmd(env, 'jq .tags.length /data.json')).stdout.trim(),
      '2',
    );
  });

  testWidgets('yq converts YAML to JSON and filters', (tester) async {
    final env = await makeEnv();
    await env.writeFile(
      'data.yaml',
      'name: fah\n'
          'tags:\n'
          '  - dart\n'
          '  - agent\n'
          'nested:\n'
          '  value: 42\n',
    );

    expect(
      (await runCmd(env, 'yq . /data.yaml')).stdout,
      contains('"name": "fah"'),
    );
    expect((await runCmd(env, 'yq .name /data.yaml')).stdout.trim(), '"fah"');
    expect(
      (await runCmd(env, 'yq .nested.value /data.yaml')).stdout.trim(),
      '42',
    );
  });

  testWidgets('curl through pipe to jq', (tester) async {
    final client = MockClient(
      (request) async => http.Response('{"result":true}', 200),
    );
    final env = await makeEnv(httpClient: client);

    final result = await runCmd(
      env,
      'curl -s https://api.example.com/flag | jq .result',
    );
    expect(result.exitCode, 0);
    expect(result.stdout.trim(), 'true');
  });
}
