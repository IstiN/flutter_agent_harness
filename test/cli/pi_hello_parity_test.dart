// The hello-token-parity gate (issue #679, owner requirement / AC2):
// fa-pi's initial context (the composed bare prompt) must cost no more
// tokens than pi's own bare default prompt for the identical scenario,
// measured with the SAME estimator on both sides — the chars/4 heuristic
// (`token_estimation.dart`, ported FROM pi-mono, so it is pi's own
// measure of both prompts).
//
// The pinned pi baseline was produced 2026-09-19 from the pi-mono
// reference checkout by running pi's real builder:
//
//   import { buildSystemPrompt } from "packages/coding-agent/src/system-prompt.ts";
//   await buildSystemPrompt({ cwd: "/tmp/hello-bench", contextFiles: [], skills: [] });
//   // → systemPrompt.join("\n\n").length == 9481
//
// with an isolated HOME (no user context files/skills inject), then
// est_tokens = ceil(9481 / 4) = 2371. An AGENTS.md in the project adds
// the same chars to BOTH sides (both load it), so the comparison holds
// for any project. Re-derive the baseline the same way when the
// reference moves.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// pi's bare default prompt, chars/4-estimated (see the library comment).
const piBarePromptBaselineTokens = 2371;

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction, {String? agentMode}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        agentMode: agentMode,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test(
    'AC2: fa-pi initial context ≤ pi bare prompt baseline (chars/4 both sides)',
    () async {
      final fake = FakeStreamFunction([textTurn('hello')]);
      final cli = cliFor(fake.call, agentMode: 'pi');
      final run = cli.run();
      await waitForIt(
        () => io.out.toString().contains('pi benchmark: initial context'),
        reason: 'pi boot',
      );
      io.sendLine('/exit');
      await run;

      final faTokens = estimateStringTokens(cli.systemPrompt);
      expect(
        faTokens,
        lessThanOrEqualTo(piBarePromptBaselineTokens),
        reason:
            'fa-pi initial context ($faTokens tok) must not exceed pi\'s '
            'bare default prompt ($piBarePromptBaselineTokens tok, chars/4 '
            'on both sides) — fa-pi wastes zero extra tokens vs the '
            'reference (issue #679 AC2).',
      );
    },
  );

  test('fa-pi initial context is strictly leaner than default mode', () async {
    final piFake = FakeStreamFunction([textTurn('hello')]);
    final piCli = cliFor(piFake.call, agentMode: 'pi');
    final piRun = piCli.run();
    await waitForIt(
      () => io.out.toString().contains('pi benchmark: initial context'),
      reason: 'pi boot',
    );
    io.sendLine('/exit');
    await piRun;
    final piPrompt = piCli.systemPrompt;
    final piTokens = estimateStringTokens(piPrompt);

    io = FakeCliIO();
    final defaultFake = FakeStreamFunction([textTurn('hello')]);
    final defaultCli = cliFor(defaultFake.call);
    final defaultRun = defaultCli.run();
    await waitForIt(
      () => defaultCli.systemPrompt.contains('You are Fa'),
      reason: 'default boot',
    );
    io.sendLine('/exit');
    await defaultRun;
    final defaultTokens = estimateStringTokens(defaultCli.systemPrompt);

    // The bare profile is a real reduction, not a re-labeling — and it
    // stays whole-prompt (pi strips sections, never re-adds them later).
    expect(piTokens, lessThan(defaultTokens));
    expect(piCli.systemPrompt.length, lessThan(defaultCli.systemPrompt.length));
  });
}
