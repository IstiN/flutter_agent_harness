/// Issue #1761 AC2 — the project-context truncation notice reaches the
/// user at boot, never silently. Line mode prints the dim notice directly
/// (this test, the same shape as the #1552 AC4 roles-drop boot test); the
/// TUI re-prints the same method's lines after the banner; the app logs
/// them through its AppLog boot-notice seam.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart' show FakeCliIO;

void main() {
  test('line mode prints the truncation notice at boot', () async {
    final env = MemoryExecutionEnv(cwd: '/work/app');
    await env.createDir('/work/.git');
    await env.createDir('/work/app');
    await env.writeFile('/work/AGENTS.md', 'x' * (40 * 1024));

    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: Model(
          id: 'placeholder',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        apiKey: 'unused',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
    );
    final run = cli.run();
    try {
      var printed = false;
      for (var i = 0; i < 2000 && !printed; i++) {
        printed = io.out.toString().contains(
          'project context truncated: AGENTS.md ',
        );
        if (!printed) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      expect(
        printed,
        isTrue,
        reason:
            'the truncation notice must reach the IO '
            'stream (line mode) — silent loss is the failure mode',
      );
      expect(io.out.toString(), contains('(full file stays on disk)'));
    } finally {
      io.sendLine('/exit');
      await run;
      await io.close();
    }
  });
}
