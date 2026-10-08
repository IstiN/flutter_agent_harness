@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1412 UT-1: the FinalizeGate contract rides the system prompt iff the
/// session runs unattended (the bench / headless autopilot mode). An
/// interactive boot must NOT carry the contract (no interactive-mode
/// behavior change, no prompt noise).
void main() {
  AgentCli cliFor(
    FakeCliIO io,
    FakeStreamFunction fake, {
    required ApprovalMode approvalMode,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'k',
      env: MemoryExecutionEnv(cwd: '/work'),
      sessionRoot: '/sessions',
      approvalMode: approvalMode,
    ),
    io: io,
    streamFunction: fake.call,
  );

  Future<String> promptOf(ApprovalMode mode) async {
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(io, fake, approvalMode: mode);
    final run = cli.run();
    io.sendLine('anything');
    await waitForIt(() => fake.calls >= 1);
    final prompt = fake.contexts[0].systemPrompt ?? '';
    io.sendLine('/exit');
    await run;
    return prompt;
  }

  test('unattended boot prompt carries the FinalizeGate contract', () async {
    final prompt = await promptOf(ApprovalMode.unattended);
    expect(prompt, contains('FinalizeGate'));
    expect(prompt, contains(finalizeGateContractPrompt));
  });

  test('interactive boots never carry the contract', () async {
    for (final mode in [
      ApprovalMode.alwaysAsk,
      ApprovalMode.write,
      ApprovalMode.yolo,
    ]) {
      final prompt = await promptOf(mode);
      expect(prompt, isNot(contains('FinalizeGate')), reason: '$mode');
    }
  });
}
