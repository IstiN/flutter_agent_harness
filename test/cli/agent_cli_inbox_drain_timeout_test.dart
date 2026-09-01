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

  /// The lost-mail half of the trade-off: the timeout must drop ONLY the
  /// hub batch — fabric mail pending for `main` survives the poll.
  test(
    'a wedged hub drain timeout drops only the hub batch, not the fabric mail',
    () async {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          plugins: [_WedgedHubPlugin()],
        ),
        io: io,
      );
      const pending = 3;
      final sentAt = DateTime.now().toUtc().toIso8601String();
      for (var i = 1; i <= pending; i++) {
        await cli.subagentManager.enqueueMessage(
          'main',
          SubagentMessage(
            fromId: 'worker',
            text: 'fabric mail $i',
            sentAt: sentAt,
          ),
        );
      }
      expect(await cli.subagentManager.pendingInboxCount('main'), pending);

      final steering = cli.agent.externalSteeringSource;
      expect(steering, isNotNull);

      final sw = Stopwatch()..start();
      final messages = await steering!();
      sw.stop();

      // The poll settles inside the drain ceiling: the timeout skipped the
      // hub poll instead of holding the run's settle hostage.
      expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
      expect(
        io.out.toString(),
        contains('[mail] hub drain timeout — skipping this poll'),
      );
      // Every fabric message came through as a steering line — none lost,
      // none duplicated, no hub batch substituted for them.
      expect(messages, hasLength(pending));
      final lines = [
        for (final message in messages)
          (message as UserMessage).content as String,
      ];
      for (var i = 1; i <= pending; i++) {
        expect(lines, contains('from worker: fabric mail $i'));
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
