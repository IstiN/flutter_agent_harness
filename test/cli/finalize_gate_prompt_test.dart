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

  test('gh-1516 req #1: the trivial-turn clause carries concrete negative '
      'examples — a "why did you…" and a "what does X do" question', () async {
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
  });

  test('gh-1646 C2: "report" is no longer an alternative to "fix"', () {
    // The regression: "fixes or explicitly reports every unmet item"
    // made an honest ledger gate-compliant at ANY moment — 49% of the
    // bench failures exited cleanly with unmet ledgers and budget left.
    expect(finalizeGateContractPrompt, isNot(contains('Fix or report')));
    expect(
      finalizeGateContractPrompt,
      isNot(contains('or explicitly reported as unmet')),
    );
  });

  test('gh-1646 C1: work to the wall — the harness owns the clock', () {
    // The owner CHANGE REQUEST dropped the deadline self-policing
    // (shell arithmetic on FA_DEADLINE_EPOCH_MS) and the violation
    // framing ("exit license"/"protocol violation"/blocker
    // bookkeeping): the harness reports the clock (the time-left
    // notice ladder) and interrupts the run at the wall — the prompt
    // points at that, never at the agent's own deadline tracking.
    expect(finalizeGateContractPrompt, contains('Work to the wall'));
    expect(
      finalizeGateContractPrompt,
      contains('time-left notices report the remaining budget'),
    );
    expect(
      finalizeGateContractPrompt,
      contains('the next compliant action is another approach'),
    );
    expect(
      finalizeGateContractPrompt,
      contains('you are interrupted automatically when time expires'),
    );
    expect(
      finalizeGateContractPrompt,
      contains('A final answer is written when the task is done'),
    );
    // The rejected self-policing machinery and violation framing stay
    // out of the contract.
    expect(finalizeGateContractPrompt, isNot(contains('FA_DEADLINE_EPOCH_MS')));
    expect(finalizeGateContractPrompt, isNot(contains('date +%s')));
    expect(finalizeGateContractPrompt, isNot(contains('exit license')));
    expect(finalizeGateContractPrompt, isNot(contains('protocol violation')));
    expect(finalizeGateContractPrompt, isNot(contains('NAMES the blocker')));
    // The ledger semantics line stays short — no new violation
    // conditions on the `fail` status.
    expect(
      finalizeGateContractPrompt,
      contains('`fail` = could not meet it before the deadline, reported'),
    );
  });

  test('headless boots carry the contract under any approval mode', () async {
    for (final mode in [ApprovalMode.alwaysAsk, ApprovalMode.write]) {
      final prompt = await promptOf(mode, headlessRun: true);
      expect(prompt, contains(finalizeGateContractPrompt), reason: '$mode');
    }
  });

  test('gh-1646: the composed headless prompt carries work-to-the-wall',
      () async {
    // Snapshot of the composed system-prompt section (C1): the
    // harness-owned clock rides the prompt the unattended agent sees.
    final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
    expect(prompt, contains('Work to the wall (gh-1646)'));
    expect(prompt, contains('time-left notices'));
    expect(prompt, contains('interrupted automatically when time expires'));
    expect(prompt, isNot(contains('FA_DEADLINE_EPOCH_MS')));
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
