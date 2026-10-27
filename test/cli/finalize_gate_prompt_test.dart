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
    // No internal issue refs ride the model-facing prompt (owner review).
    expect(finalizeGateContractPrompt, isNot(contains('gh-1646')));
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

  test('gh-1834 C1: conformance coverage is a numbered step (2.6) between '
      'grader parity and fix', () {
    // The self-certification blind spot: a run declared "behavioral
    // parity confirmed" off a happy-path-only suite; the external
    // evaluation then failed exactly the unprobed branches — mutually
    // exclusive option pairs never rejected, "must error" inputs never
    // run. The gate must make negative + combination coverage a
    // NUMBERED step (flash executes numbered steps, skims the bullet
    // list — gh-1652).
    expect(
      finalizeGateContractPrompt,
      contains('2.6. **Conformance coverage**'),
    );
    expect(
      finalizeGateContractPrompt,
      isNot(contains('- **Conformance coverage**')),
    );
    final parityAt = finalizeGateContractPrompt.indexOf(
      '2.5. **Grader parity**',
    );
    final coverageAt = finalizeGateContractPrompt.indexOf('2.6. **Conformance');
    final fixAt = finalizeGateContractPrompt.indexOf('3. **Fix every unmet');
    expect(coverageAt, greaterThan(parityAt));
    expect(fixAt, greaterThan(coverageAt));
    // AC1: the checklist classes a conformance claim must quote.
    expect(
      finalizeGateContractPrompt,
      contains('negative and combination checks'),
    );
    expect(finalizeGateContractPrompt, contains('incompatible'));
    expect(finalizeGateContractPrompt, contains('mutually exclusive'));
    expect(finalizeGateContractPrompt, contains('empty and corrupt inputs'));
    expect(finalizeGateContractPrompt, contains('boundary values'));
    expect(finalizeGateContractPrompt, contains('"must NOT work"'));
    // A blanket "everything matches" is not a verified item.
    expect(
      finalizeGateContractPrompt,
      contains('without such coverage is not verified'),
    );
  });

  test('gh-1834 C2: the principle is taught abstractly; no benchmark or '
      'task-specific names in the prompt', () {
    // AC2 — happy-path agreement certifies nothing about rejection paths
    // and combinations; the example is abstract (a port agreeing on every
    // well-formed input), never a real benchmark/task/flag name.
    expect(
      finalizeGateContractPrompt,
      contains('certifies nothing about rejection paths'),
    );
    expect(finalizeGateContractPrompt, contains('well-formed'));
    for (final banned in [
      'terminal-bench',
      'harbor',
      'compcert',
      'crack-7z',
      'TB-2',
      'gh-18',
    ]) {
      expect(
        finalizeGateContractPrompt,
        isNot(contains(banned)),
        reason: banned,
      );
    }
  });

  test('gh-1834 C3: tasks with no conformance claim see no gate change', () {
    // The new requirement is CONDITIONAL — it binds only when the final
    // claim includes conformance/parity. A task with no such claim keeps
    // today's checklist shape (no new mandatory requirements).
    expect(finalizeGateContractPrompt, contains('applies ONLY when'));
  });

  test('gh-1834 C4: the composed headless prompt carries the conformance '
      'coverage step', () async {
    final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
    expect(prompt, contains('2.6. **Conformance coverage**'));
    expect(prompt, contains('negative and combination checks'));
  });

  test('headless boots carry the contract under any approval mode', () async {
    for (final mode in [ApprovalMode.alwaysAsk, ApprovalMode.write]) {
      final prompt = await promptOf(mode, headlessRun: true);
      expect(prompt, contains(finalizeGateContractPrompt), reason: '$mode');
    }
  });

  test(
    'gh-1646: the composed headless prompt carries work-to-the-wall',
    () async {
      // Snapshot of the composed system-prompt section (C1): the
      // harness-owned clock rides the prompt the unattended agent sees.
      final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
      expect(prompt, contains('Work to the wall'));
      expect(prompt, contains('time-left notices'));
      expect(prompt, contains('interrupted automatically when time expires'));
      expect(prompt, isNot(contains('FA_DEADLINE_EPOCH_MS')));
    },
  );

  test('gh-1652 C1: grader parity is numbered step 2.5 between verify '
      'and fix', () {
    // The CLEAN-WRONG regression (41% of bench failures): the agent
    // validated through its own oracle and never ran the grader's
    // invocation. Parity is a NUMBERED step, not a named-check bullet.
    expect(finalizeGateContractPrompt, contains('2.5. **Grader parity**'));
    expect(finalizeGateContractPrompt, isNot(contains('- **Grader parity**')));
    final verifyAt = finalizeGateContractPrompt.indexOf(
      '2. **Verify each item',
    );
    final parityAt = finalizeGateContractPrompt.indexOf('2.5. **Grader');
    final fixAt = finalizeGateContractPrompt.indexOf('3. **Fix every unmet');
    expect(parityAt, greaterThan(verifyAt));
    expect(fixAt, greaterThan(parityAt));
    expect(finalizeGateContractPrompt, contains('neutral cwd'));
  });

  test(
    'gh-1652 C2: the composed headless prompt carries the parity step',
    () async {
      final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
      expect(prompt, contains('2.5. **Grader parity**'));
    },
  );

  test('gh-1670 C1: feasibility before commitment — the contract names the '
      'long-pole classes and the cheaper-strategy fallback', () {
    // The regression (compile-compcert / crack-7z-hash transcripts): the
    // agent committed to a from-source build / brute-force crack without
    // estimating whether the path fit the remaining budget, and learned
    // infeasibility only at the wall. The gate must teach the comparison
    // at COMMITMENT time.
    expect(
      finalizeGateContractPrompt,
      contains('Feasibility before commitment'),
    );
    // The two concrete long-pole classes.
    expect(finalizeGateContractPrompt, contains('from-source builds'));
    expect(finalizeGateContractPrompt, contains('large downloads'));
    expect(finalizeGateContractPrompt, contains('brute-force searches'));
    // The comparison target is the harness's clock (the time-left
    // notices), not the agent's own bookkeeping.
    expect(finalizeGateContractPrompt, contains('time-left notices'));
    // The fallback: a cheaper strategy, never a gamble on a known-
    // infeasible path.
    expect(finalizeGateContractPrompt, contains('cheaper strategy'));
    expect(
      finalizeGateContractPrompt,
      contains('never gamble the whole window on a path you already know'),
    );
    // The ticket's "(or the next-best partial)" leg (PR #1673 review
    // thread): "reduced scope the task allows" only covers tasks whose
    // text explicitly permits reduced scope — the compcert /
    // crack-7z-hash transcripts are exactly the cases where even the
    // cheapest satisfying strategy may not exist and the best move is
    // a partial artifact plus an honest ledger row. That leg must be
    // explicit in the contract.
    expect(
      finalizeGateContractPrompt,
      contains('when no satisfying strategy fits, the next-best partial'),
    );
    // No internal issue refs ride the model-facing prompt (owner review).
    expect(finalizeGateContractPrompt, isNot(contains('gh-1670')));
  });

  test(
    'gh-1670 C2: the composed headless prompt carries the feasibility gate',
    () async {
      final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
      expect(prompt, contains('Feasibility before commitment'));
      expect(prompt, contains('brute-force searches'));
    },
  );

  test('gh-1668 C1: the no-teardown rule — final state is the deliverable', () {
    // The observed antipattern (terminal-bench configure-git-webserver,
    // 2/2): the agent verified end-to-end, then RESET its own setup
    // "so the checker's commands run exactly as written" — the produced
    // state no longer existed at grading.
    expect(
      finalizeGateContractPrompt,
      contains('Final state is the deliverable'),
    );
    expect(
      finalizeGateContractPrompt,
      contains('never uninstall, stop, reset'),
    );
    expect(finalizeGateContractPrompt, contains('read-only or additive'));
    expect(
      finalizeGateContractPrompt,
      contains('only if the task explicitly requires it'),
    );
    // The negative example pins the wrong pattern by name.
    expect(finalizeGateContractPrompt, contains('verified, then reset'));
  });

  test(
    'gh-1668 C2: the no-teardown rule is numbered step 4 inside the loop',
    () {
      // Skim-proof, mirroring the gh-1652 C1 placement guard: flash
      // executes numbered steps but skims the bullet list — the rule must
      // ride the numbered loop, not the named-checks section or a
      // floating paragraph after the ledger spec.
      final fixAt = finalizeGateContractPrompt.indexOf('3. **Fix every unmet');
      final ruleAt = finalizeGateContractPrompt.indexOf(
        '4. **Final state is the deliverable**',
      );
      final wallAt = finalizeGateContractPrompt.indexOf(
        '**Work to the wall.**',
      );
      expect(ruleAt, greaterThan(fixAt));
      expect(wallAt, greaterThan(ruleAt));
      expect(
        finalizeGateContractPrompt,
        isNot(contains('- **Final state is the deliverable**')),
      );
    },
  );

  test('gh-1668 C3: "Content, not existence" cross-references the '
      'no-teardown rule', () {
    // A file that existed mid-run but is deleted at finalization is a
    // fail — the cross-reference lives in the SAME bullet, not a
    // distant section the model may never connect.
    final bulletAt = finalizeGateContractPrompt.indexOf(
      '- **Content, not existence**',
    );
    final refAt = finalizeGateContractPrompt.indexOf(
      'deleted at finalization is a `fail`',
    );
    expect(bulletAt, isNot(-1));
    expect(refAt, greaterThan(bulletAt));
    // PRT_kwDOTXdlLc6tir-L: anchor the upper bound on structural
    // markers instead of an arbitrary char window — a legitimate bullet
    // extension or a generator re-wrap must not fail the test, and a
    // move into the NEXT bullet (or past the section) must. The
    // "Content, not existence" bullet is the last one in the named
    // checks, so the bound is the nearest of the next bullet and the
    // end of the current paragraph.
    final nextBulletAt = finalizeGateContractPrompt.indexOf(
      '\n- **',
      bulletAt + 1,
    );
    final paragraphEndAt = finalizeGateContractPrompt.indexOf(
      '\n\n',
      bulletAt + 1,
    );
    final upperBound = [
      if (nextBulletAt != -1) nextBulletAt,
      if (paragraphEndAt != -1) paragraphEndAt,
    ].fold(finalizeGateContractPrompt.length, (a, b) => a < b ? a : b);
    expect(refAt, lessThan(upperBound));
    expect(finalizeGateContractPrompt, contains('(step 4)'));
  });

  test(
    'gh-1668 C4: the composed headless prompt carries the no-teardown rule',
    () async {
      final prompt = await promptOf(ApprovalMode.unattended, headlessRun: true);
      expect(prompt, contains('Final state is the deliverable'));
      expect(prompt, contains('verified, then reset'));
    },
  );

  test('gh-1669: archive extraction completeness rides the contract as a '
      'named check', () {
    // CLEAN-WRONG regression (terminal-bench build-pov-ray, 2/2): the
    // agent extracted the meaningful subtrees but dropped the archive's
    // root-level `file_id.diz`, then marked the extraction step `pass`
    // off an `ls` of the target. The contract now pins extraction
    // completeness as a named check, next to "Canonical artifacts".
    expect(
      finalizeGateContractPrompt,
      contains('- **Archive extraction is complete**'),
    );
    // The check names the verification command shape — an archive
    // listing diffed against the extracted tree, not an aspirational
    // "make sure everything extracted".
    expect(finalizeGateContractPrompt, contains('unzip -l'));
    expect(finalizeGateContractPrompt, contains('tar -tf'));
    // Root-level marker/manifest files are called out explicitly.
    expect(finalizeGateContractPrompt, contains('file_id.diz'));
    // PR #1672 review threads PRRT_kwDOTXdlLc6thCGY / PRRT_kwDOTXdlLc6thIHv:
    // plain `ls` of the target is non-recursive, so a literal diff of the
    // archive's recursive listing against it degrades to "root-level
    // entries match" for nested archives. The command shape must name a
    // recursive counterpart.
    expect(finalizeGateContractPrompt, contains('ls -R'));
    expect(finalizeGateContractPrompt, contains('find <target> -type f'));
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
