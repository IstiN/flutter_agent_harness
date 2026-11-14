import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An immediately-ending stream: every call emits one text turn.
void main() {
  test(
    '/queue prints the queue hint; /queue clear without a TUI is a no-op',
    () async {
      final io = FakeCliIO();
      final stream = FakeStreamFunction([textTurn('idle')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 128000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      io.sendLine('/queue');
      await io.out.waitUntilContains('Queued messages render');
      expect(io.out.toString(), contains('Queued messages render'));
      expect(io.out.toString(), contains('/queue clear'));
      io.sendLine('/queue clear');
      await io.out.waitUntilContains('No interactive TUI session');
      expect(io.out.toString(), contains('No interactive TUI session'));
      // Settle the REPL loop, then release the fake IO.
      io.sendLine('/exit');
      await io.out.waitUntilContains('bye');
      await run; // must return bounded — bounded-exit guarantees the settle
      await io.close();
    },
  );
}
