// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final class _RecordingNetworkPlugin implements FahPlugin {
  final List<List<String>> calls = [];

  @override
  String get name => 'network-recorder';

  @override
  void register(PluginContext context) {
    context.registerSlashCommand('/network', (args) async {
      calls.add(args);
    });
  }
}

void main() {
  const invite = 'wss://hub.fa1.dev/ws?channel=team';

  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late _RecordingNetworkPlugin plugin;
  late AgentCli cli;

  setUp(() {
    env = MemoryExecutionEnv();
    io = FakeCliIO();
    plugin = _RecordingNetworkPlugin();
    cli = AgentCli(
      config: AgentCliConfig(
        model: Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test',
          baseUrl: 'https://example.com',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        plugins: [plugin],
      ),
      io: io,
      streamFunction: (model, context, {cancelToken}) =>
          AssistantMessageEventStream(),
    );
  });

  tearDown(() => io.close());

  test(
    'AC7: a pasted invite opens the /network wizard, never the agent',
    () async {
      await cli.handleLineForTest(invite);
      expect(plugin.calls, [
        ['join', invite],
      ]);
      expect(
        cli.agent.state.messages.where((m) => m.toString().contains(invite)),
        isEmpty,
      );
    },
  );

  test('AC7: a pasted fa dap import command takes the same path', () async {
    final pasted = "fa dap import '$invite'";
    await cli.handleLineForTest(pasted);
    expect(plugin.calls, [
      ['join', pasted],
    ]);
  });

  test('ordinary prose and non-invite urls are NOT intercepted', () async {
    await cli.handleLineForTest('team standup notes');
    await cli.handleLineForTest('wss://hub.fa1.dev/ws (no channel param)');
    expect(plugin.calls, isEmpty);
  });
}
