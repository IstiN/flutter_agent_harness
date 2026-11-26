// TEMPORARY calibration probe (rework lap) — measures the merged tree's
// request overhead for the tinyPrompt + tinyTools seam via the exported
// estimator over the CLI's own composed request. Deleted after
// calibration; never committed.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'cli/agent_cli_test_support.dart';

void main() {
  test('probe: overhead + transcript pricing for the seam fixture', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    env.writeFile('big.txt', List.filled(1000, 'x' * 40).join('\n'));
    final io = FakeCliIO();
    final fake = FakeStreamFunction([
      toolTurn([
        const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
      ]),
      textTurn('done reading'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        systemPrompt: tinyPrompt,
        runtimeTools: tinyTools(const ['read']),
        model: const Model(
          id: 'tiny',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 16384,
          maxTokens: 4096,
        ),
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
    );
    final code = await cli.runHeadless('q');
    await io.close();
    // ignore: avoid_print
    print('PROBE_EXIT=$code CALLS=${fake.contexts.length}');
    for (var i = 0; i < fake.contexts.length; i++) {
      final c = fake.contexts[i];
      final est = estimateRequestTokens(
        c.messages,
        systemPrompt: c.systemPrompt,
        tools: c.tools ?? const [],
      );
      final oh = estimateRequestOverheadTokens(
        c.systemPrompt,
        c.tools ?? const [],
      );
      final promptChars = c.systemPrompt?.length ?? 0;
      // ignore: avoid_print
      print(
        'PROBE_CTX$i: msgs=${c.messages.length} promptChars=$promptChars '
        'tools=${(c.tools ?? const []).length} overhead=$oh estimate=$est '
        'promptTokens=${c.systemPrompt == null ? null : estimateStringTokens(c.systemPrompt!)}',
      );
    }
  });
}
