@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1412 UT-1 (gh-1516 amendment): the FinalizeGate contract rides the
/// system prompt iff the run is UNATTENDED (`AgentCliConfig.headlessRun` —
/// `fa -p`/bench), never off the approval mode: an interactive TUI session
/// stays contract-free under EVERY approval mode, including autopilot
/// (`ApprovalMode.unattended`); a headless run carries it under any mode.
void main() {
  AgentCli cliFor(
    FakeCliIO io,
    FakeStreamFunction fake, {
    required ApprovalMode approvalMode,
    bool headlessRun = false,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: MemoryExecutionEnv(cwd: '/work'),
      sessionRoot: '/sessions',
      approvalMode: approvalMode,
      headlessRun: headlessRun,
    ),
    io: io,
    streamFunction: fake.call,
  );

  Future<String> promptOf(ApprovalMode mode, {bool headlessRun = false}) async {
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(io, fake, approvalMode: mode, headlessRun: headlessRun);
    final run = cli.run();
    io.sendLine('anything');
    await waitForIt(() => fake.calls >= 1);
    final prompt = fake.contexts[0].systemPrompt ?? '';
    io.sendLine('/exit');
    await run;
    return prompt;
  }

  test(
    'unattended headless boot prompt carries the FinalizeGate contract',
    () async {
      final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
      expect(prompt, contains('FinalizeGate'));
      expect(prompt, contains(finalizeGateContractPrompt));
    },
  );

  test(
    'gh-1516 req #1: the trivial-turn clause carries concrete negative '
    'examples — a "why did you…" and a "what does X do" question',
    () async {
      expect(finalizeGateContractPrompt, contains('почему ты баш команды'));
      expect(finalizeGateContractPrompt, contains('why did you'));
      expect(finalizeGateContractPrompt, contains('what does the'));
      // gh-1516 review: the exemption wording matches the telemetry —
      // "no tool calls at all", not "no state-changing commands".
      expect(finalizeGateContractPrompt, contains('NO tool calls at all'));
      expect(
        finalizeGateContractPrompt,
        isNot(contains('state-changing commands')),
      );
    },
  );

  test('headless boots carry the contract under any approval mode', () async {
    for (final mode in [ApprovalMode.alwaysAsk, ApprovalMode.write]) {
      final prompt = await promptOf(mode, headlessRun: true);
      expect(prompt, contains(finalizeGateContractPrompt), reason: '$mode');
    }
  });

  test('interactive boots never carry the contract', () async {
    for (final mode in [
      ApprovalMode.alwaysAsk,
      ApprovalMode.write,
      ApprovalMode.yolo,
      // gh-1516: autopilot in an interactive TUI is attended — the gate
      // must key off attendance, never off the approval mode.
      ApprovalMode.unattended,
    ]) {
      final prompt = await promptOf(mode);
      expect(prompt, isNot(contains('FinalizeGate')), reason: '$mode');
    }
  });
}
