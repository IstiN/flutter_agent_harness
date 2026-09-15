// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the line-mode provider queue editor (issue #418):
/// `/providers queue list|add|remove|move|test` against a REAL temp
/// config file — the same three-scope resolution the boot applies. The
/// PTY IT drives the same surface end to end; these cover the branches
/// (bad indexes, guard arms, probe failures) a PTY session cannot reach
/// deterministically.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late Directory home;
  late Directory project;
  late LocalExecutionEnv env;
  late FakeCliIO io;

  const seedConfig = '''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:1/v1
allowedTools: []
providersQueue:
  - provider_type: openai-completions
    provider_config:
      model: queue-a
      apiKeyEnv: K_A
      baseUrl: http://127.0.0.1:1/v1
  - provider_type: openai-completions
    provider_config:
      model: queue-b
      apiKeyEnv: K_B
''';

  setUp(() {
    home = Directory.systemTemp.createTempSync('queue_editor_home');
    project = Directory.systemTemp.createTempSync('queue_editor_proj');
    File('${home.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(seedConfig);
    env = LocalExecutionEnv(cwd: project.path);
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
  });

  ProviderQueueRuntime runtimeFromBoot() {
    final queue = resolveProviderQueueAtBoot(
      projectDir: project.path,
      homeDir: home.path,
      env: const <String, String>{},
    );
    return ProviderQueueRuntime.build(
      queue,
      secrets: const {'K_A': 'a', 'K_B': 'b', 'K_X': 'x'},
      streamFactory: (kind, key) => FakeStreamFunction([textTurn('ok')]).call,
    );
  }

  AgentCli cliFor({ProviderQueueRuntime? runtime}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        homeDir: home.path,
        sessionRoot: '${home.path}/sessions',
        providersQueueRuntime: runtime,
        envVarValue: (name) => switch (name) {
          'K_A' || 'K_B' || 'K_C' || 'K_X' => 'secret-$name',
          _ => null,
        },
        modelsHttpClient: http.Client(),
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
  }

  Future<void> runCli(AgentCli cli, String command) async {
    await cli.handleLineForTest(command);
  }

  test('no queue: bare /providers queue prints the unset hint', () async {
    final cli = cliFor();
    await runCli(cli, '/providers queue');
    expect(io.out.toString(), contains('no provider queue set'));
  });

  test('unknown subcommand prints usage', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue bogus');
    expect(io.out.toString(), contains('usage: /providers queue'));
  });

  test('guard arms fall through to usage', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue add onlykind');
    await runCli(cli, '/providers queue remove 9 9');
    expect(
      io.out.toString().split('usage: /providers queue').length,
      greaterThanOrEqualTo(3),
    );
  });

  test('list renders both entries with badges and the key env names', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue');
    final out = io.out.toString();
    expect(out, contains('0. openai-completions/queue-a [current]'));
    expect(out, contains('1. openai-completions/queue-b [healthy]'));
    expect(out, contains(r'key:$K_A'));
    // AC9: values never surface.
    expect(out.contains('secret-'), isFalse);
  });

  test('remove 0 persists the shortened queue to the USER file', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue remove 0');
    final out = io.out.toString();
    expect(out, contains('providersQueue updated (1 entries)'));
    expect(out, contains('live from the next turn'));
    final body = File('${home.path}/.fah/config.yaml').readAsStringSync();
    expect(body.contains('queue-a'), isFalse);
    expect(body.contains('queue-b'), isTrue);
    expect(
      body.contains('provider: openai-completions'),
      isTrue,
      reason: 'the upsert keeps the rest of the file byte-for-byte',
    );
  });

  test('add appends a validated entry and persists it', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(
      cli,
      '/providers queue add anthropic queue-c K_C '
      'https://api.example/v1',
    );
    final out = io.out.toString();
    expect(out, contains('providersQueue updated (3 entries)'));
    final body = File('${home.path}/.fah/config.yaml').readAsStringSync();
    expect(body.contains('queue-c'), isTrue);
  });

  test('add with a bad provider type refuses the write', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue add nonsense queue-c K_C');
    expect(io.out.toString(), contains('/providers queue add refused'));
    final body = File('${home.path}/.fah/config.yaml').readAsStringSync();
    expect(body.contains('queue-c'), isFalse);
  });

  test('remove with an out-of-range index refuses the write', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue remove 9');
    expect(io.out.toString(), contains('not applied'));
  });

  test('move reorders and persists', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue move 1 0');
    expect(io.out.toString(), contains('providersQueue updated (2 entries)'));
    final body = File('${home.path}/.fah/config.yaml').readAsStringSync();
    final aIndex = body.indexOf('queue-a');
    final bIndex = body.indexOf('queue-b');
    expect(bIndex, lessThan(aIndex), reason: 'queue-b moved to the head');
  });

  test('test with an out-of-range index says so without probing', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue test 9');
    expect(io.out.toString(), contains('no such queue entry: 9'));
  });

  test('test probes the entry and reports a connection failure', () async {
    // queue-a points at 127.0.0.1:1 (nothing listens) — the probe must
    // fail LOUDLY with the error text, never hang or lie.
    final cli = cliFor(runtime: runtimeFromBoot());
    await runCli(cli, '/providers queue test 0');
    final out = io.out.toString();
    expect(
      out.contains('openai-completions/queue-a: FAILED') ||
          out.contains('openai-completions/queue-a: cannot probe'),
      isTrue,
      reason: 'the probe reports the outcome: ${io.out.toString()}',
    );
  });

  test(
    'test probes a live stub endpoint and reports ok with the latency',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen((request) async {
        // A minimal SSE stream: one delta, then [DONE].
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        const id = 'chatcmpl-probe';
        final parts = [
          {
            'id': id,
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'queue-x',
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant'},
                'finish_reason': null,
              },
            ],
          },
          {
            'id': id,
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'queue-x',
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'pong'},
                'finish_reason': null,
              },
            ],
          },
          {
            'id': id,
            'object': 'chat.completion.chunk',
            'created': 1,
            'model': 'queue-x',
            'choices': [
              {
                'index': 0,
                'delta': <String, dynamic>{},
                'finish_reason': 'stop',
              },
            ],
          },
        ];
        for (final part in parts) {
          request.response.add(utf8.encode('data: ${jsonEncode(part)}\n\n'));
        }
        request.response.add(utf8.encode('data: [DONE]\n\n'));
        await request.response.close();
      });

      final keyless =
          '''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:1/v1
providersQueue:
  - provider_type: openai-completions
    provider_config:
      model: queue-x
      apiKeyEnv: K_X
      baseUrl: http://127.0.0.1:${server.port}/v1
''';
      File('${home.path}/.fah/config.yaml').writeAsStringSync(keyless);
      final cli = cliFor(runtime: runtimeFromBoot());
      await runCli(cli, '/providers queue test 0');
      expect(io.out.toString(), contains('openai-completions/queue-x: ok ('));
    },
  );

  test('the settings-hub handler opens the same queue surface', () async {
    final cli = cliFor(runtime: runtimeFromBoot());
    await cli.pickSettingForTest('providers-queue');
    // The bare editor prints the queue list — the hub selection shares it.
    expect(io.out.toString(), contains('0. openai-completions/queue-a'));
  });
}
