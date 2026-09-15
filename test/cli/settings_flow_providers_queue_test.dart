// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The provider queue's settings-hub integration (issue #418): the hub
/// row exists, carries a live status description, and has a wired
/// handler — a hub row without a handler is a dead menu entry.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    ProviderQueueRuntime? queueRuntime,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providersQueueRuntime: queueRuntime,
        envVarValue: (name) => null,
        modelsHttpClient: http.Client(),
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('no queue set: the hub row reads "not set" and the line-mode summary '
      'keeps a queue row', () {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final rows = cli.settingsHubItemsForTest();
    final row = rows.where((item) => item.key == 'providers-queue').toList();
    expect(row, hasLength(1));
    expect(row.single.label, 'Provider queue');
    expect(row.single.description, 'not set');
    expect(
      cli.settingsPickerHandlerKeysForTest(),
      contains('providers-queue'),
      reason: 'a hub row without a handler is a dead menu entry',
    );
  });

  test('queue set: the hub row names the entry count and current head', () {
    final runtime = ProviderQueueRuntime.build(
      ProviderQueueResolution(
        scope: ProviderQueueScope.user,
        entries: [
          ProviderQueueEntry(
            providerType: 'openai-completions',
            model: 'queue-a',
            apiKeyEnv: 'K_A',
          ),
          ProviderQueueEntry(
            providerType: 'openai-completions',
            model: 'queue-b',
            apiKeyEnv: 'K_B',
          ),
        ],
        notices: const [],
      ),
      secrets: const {'K_A': 'a', 'K_B': 'b'},
      streamFactory: (kind, key) => FakeStreamFunction([textTurn('ok')]).call,
    );
    final cli = cliFor(
      FakeStreamFunction([textTurn('ok')]).call,
      queueRuntime: runtime,
    );
    final row = cli
        .settingsHubItemsForTest()
        .where((item) => item.key == 'providers-queue')
        .toList()
        .single;
    expect(row.key, 'providers-queue');
    expect(row.description, contains('2 entries'));
    expect(row.description, contains('current: queue-a'));
  });

  test('line-mode /settings summary prints the queue status row', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final run = cli.run();
    io.sendLine('/settings');
    await waitForIt(() => io.out.toString().contains('queue:'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('queue: not set'));
  });
}
