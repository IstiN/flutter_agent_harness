import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A plugin whose hub inbox never answers a drain: models a hub RPC that
/// wedges instead of returning.
class _WedgedHubPlugin implements FahPlugin {
  @override
  String get name => 'wedged_hub';

  @override
  void register(PluginContext context) {
    context.registerExternalInbox(
      ExternalInbox(drain: () => Completer<List<AgentMessage>>().future),
    );
  }
}

void main() {
  test(
    'a wedged hub drain cannot hold the steering poll past the timeout',
    () async {
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          plugins: [_WedgedHubPlugin()],
        ),
        io: FakeCliIO(),
      );
      final steering = cli.agent.externalSteeringSource;
      expect(steering, isNotNull);

      final sw = Stopwatch()..start();
      final messages = await steering!();
      sw.stop();

      expect(messages, isEmpty);
      // The drain ceiling is 5s; anything past 6s means the run settle is
      // hostage to the wedged hub again.
      expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
