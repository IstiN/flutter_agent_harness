/// CLI integration tests for the foreground-call budget's CLI surface
/// (issue #1786): the liveness watchdog's escalate rung hands the action
/// to the budget ladder's one-key offer instead of the display-only
/// nudge (IT-4/AC4), the accept hands the call back and the queued
/// steering drains (AC2), every beat lands in the session JSONL with the
/// deterministic announcement (REG-1), and the ladder-declined cadence
/// stays byte-identical (REG-3).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_steering_persistence_test.dart' show waitForSessions;
import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late GatedShell shell;
  var now = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    shell = GatedShell();
    env = MemoryExecutionEnv(cwd: '/work', shell: shell);
    io = FakeCliIO();
    now = DateTime.utc(2026, 1, 1, 12);
  });
  tearDown(() => io.close());

  // The budget config rides the config object directly (issue #1786): the
  // default B keeps the loop's REAL rung timers out of the test window —
  // the watchdog rung is driven deterministically by the liveness tick
  // seam, not the clock — and the short cancel grace bounds the mock
  // shell's token-ignoring unwind after an accept.
  AgentCli cliFor(FakeStreamFunction fake) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      foregroundCall: const ForegroundCallBudgetConfig(
        budget: Duration(minutes: 10),
        cancelGrace: Duration(milliseconds: 120),
      ),
    ),
    io: io,
    streamFunction: fake.call,
    waitingClock: () => now,
  );

  /// One bash call the mock shell holds until the ladder acts, then the
  /// wrap-up answer and the steering-drain extension turn (consumed only
  /// when the boundary opens one; an unused trailing turn is harmless).
  FakeStreamFunction budgetFake() => FakeStreamFunction([
    toolTurn([
      const ToolCall(
        id: 't1',
        name: 'bash',
        // A legitimate long build, not a bare sleep (issue #1349).
        arguments: {'command': 'make release'},
      ),
    ]),
    textTurn('done'),
    textTurn('steered reply'),
  ]);

  test('IT-4+AC2+REG-1: the watchdog surfaces the offer (no duplicate '
      'nudge), the accept hands the call back with the steering draining, '
      'and the session records the announcement', () async {
    final fake = budgetFake();
    final cli = cliFor(fake);
    final run = cli.run();
    await waitForSessions(env);
    io.sendLine('hi');
    await waitForIt(
      () => cli.toolLivenessCallsForTest.isNotEmpty,
      reason: 'the foreground call is being watched',
    );

    // Mid-run steering: the offer rung is only eligible with steering
    // pending (UT-1) — this is what makes the watchdog hand over.
    await cli.steerForTest('switch to plan b');

    now = now.add(const Duration(seconds: 300));
    cli.toolLivenessTickForTest();

    // IT-4/AC4: the escalation routed through the ladder — the offer is
    // the real action (record + terminal line + `b` affordance), so the
    // legacy beats stay out: no escalation line, no model nudge. The
    // requestOffer hand-over is synchronous; the offer EVENT rides the
    // agent event stream, so affordance state lands a turn later.
    expect(cli.budgetOfferRequestedForTest, isTrue);
    await waitForIt(
      () => cli.hasOutstandingBudgetOffer,
      reason: 'the offer event reached the CLI surface',
    );
    final out = io.out.toString();
    expect(out, contains('[foreground-budget]'));
    expect(out, contains('rung 3'));
    expect(
      out,
      isNot(contains('background candidate:')),
      reason:
          'the escalation line is skipped when the offer IS the '
          'action',
    );
    expect(cli.toolNudgesSentForTest, 0);

    // AC2: the one-key accept escalates the offered call now.
    expect(cli.acceptOutstandingBudgetOffer(), isTrue);
    await waitForIt(
      () => !cli.isBusy,
      reason: 'the call handed back and the steering drained',
    );
    io.sendLine('/exit');
    await run;

    // No offer outlives its call (the abort outcome cleared it).
    expect(cli.hasOutstandingBudgetOffer, isFalse);
    // The queued steering reached a model request (the boundary drain).
    expect(
      fake.contexts.any(
        (context) => context.messages.any(
          (message) =>
              message is UserMessage &&
              messageText(message).contains('switch to plan b'),
        ),
      ),
      isTrue,
    );

    // REG-1: the raw session JSONL carries the foreground_budget record
    // with the deterministic announcement (a direct env read, no repo
    // open — the stuck-session suite's pattern).
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    final sessionJsonl = (await env.readTextFile(
      sessions.first.path,
    )).getOrThrow();
    expect(sessionJsonl, contains('foreground_budget'));
    expect(sessionJsonl, contains('[foreground-budget]'));
    expect(sessionJsonl, contains('watchdog'));
  });

  test('REG-3: with the ladder unable to act (no pending steering) the '
      'escalation keeps its legacy cadence', () async {
    final cli = cliFor(budgetFake());
    final run = cli.runHeadless('hi');
    await waitForIt(
      () => cli.toolLivenessCallsForTest.isNotEmpty,
      reason: 'the foreground call is being watched',
    );

    now = now.add(const Duration(seconds: 300));
    cli.toolLivenessTickForTest();

    // The ladder declined (silent call, but no steering pending) — the
    // budget-not-hit cadence is byte-identical: escalation line + ONE
    // model nudge, no budget record, no offer affordance.
    expect(cli.budgetOfferRequestedForTest, isFalse);
    expect(cli.hasOutstandingBudgetOffer, isFalse);
    final out = io.out.toString();
    expect(out, contains('background candidate:'));
    expect(cli.toolNudgesSentForTest, 1);
    expect(out, isNot(contains('[foreground-budget]')));

    shell.release();
    await run;
  });

  test('the affordance state machine: nothing to accept, a stale offer '
      'clears on a declined accept', () async {
    final cli = cliFor(budgetFake());
    expect(cli.hasOutstandingBudgetOffer, isFalse);
    expect(cli.acceptOutstandingBudgetOffer(), isFalse);

    cli.budgetOfferSurfaced('t9');
    expect(cli.hasOutstandingBudgetOffer, isTrue);
    // A stale id (no such in-flight call) declines and clears — the `b`
    // key must not stay armed on a dead offer.
    expect(cli.acceptOutstandingBudgetOffer(), isFalse);
    expect(cli.hasOutstandingBudgetOffer, isFalse);

    cli.budgetOfferCleared();
    expect(cli.hasOutstandingBudgetOffer, isFalse);
  });
}
