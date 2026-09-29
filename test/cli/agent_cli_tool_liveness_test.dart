/// CLI integration tests for the per-call foreground liveness reminders
/// (gh-1055): a headless or line-mode run whose shell call outlasts the
/// threshold emits grep-friendly single-line reminders, then exactly one
/// background escape-hatch hint per stuck call. Every elapsed value rides
/// the waiting-clock seam (no second clock), and the console records are
/// identical across the headless and REPL line-mode paths.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tool_liveness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The liveness console records: every single-line reminder/hint the run
/// printed (the `⏳` marker is the waiting layer's grep anchor).
List<String> livenessLines(String out) =>
    out.split('\n').where((line) => line.contains('⏳ [')).toList();

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

  AgentCli cliFor(FakeStreamFunction fake, {bool useTui = false}) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
    ),
    io: io,
    streamFunction: fake.call,
    waitingClock: () => now,
    useTui: useTui,
  );

  /// The stuck-call scenario: one bash call the mock shell holds until the
  /// test releases it, then the run wraps up.
  FakeStreamFunction stuckCallFake() => FakeStreamFunction([
    toolTurn([
      const ToolCall(
        id: 't1',
        name: 'bash',
        arguments: {'command': 'sleep 500'},
      ),
    ]),
    textTurn('done'),
  ]);

  group('headless (fa "prompt")', () {
    test('AC1: a call outlasting the threshold emits single-line reminders '
        'at the cadence', () async {
      final cli = cliFor(stuckCallFake());
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.isNotEmpty,
        reason: 'the foreground call is being watched',
      );

      now = now.add(const Duration(seconds: 120));
      cli.toolLivenessTickForTest();
      expect(io.out.toString(), contains('⏳ [bash] sleep 500 — running 120s'));

      now = now.add(const Duration(seconds: 60));
      cli.toolLivenessTickForTest();
      expect(io.out.toString(), contains('⏳ [bash] sleep 500 — running 180s'));

      shell.release();
      await run;
    });

    test('AC2: a call finishing under the threshold stays quiet', () async {
      final cli = cliFor(stuckCallFake());
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.isNotEmpty,
        reason: 'the foreground call is being watched',
      );

      now = now.add(const Duration(seconds: 30));
      cli.toolLivenessTickForTest();
      expect(livenessLines(io.out.toString()), isEmpty);

      shell.release();
      await run;
      // After the call ends the watch is silent too — no stale reminders.
      cli.toolLivenessTickForTest();
      expect(livenessLines(io.out.toString()), isEmpty);
    });

    test('AC3+AC6: the escalation names the background hatch and the '
        'cancellation levers exactly once per stuck call', () async {
      final cli = cliFor(stuckCallFake());
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.isNotEmpty,
        reason: 'the foreground call is being watched',
      );

      now = now.add(const Duration(seconds: 300));
      cli.toolLivenessTickForTest();
      final out = io.out.toString();
      expect(
        out,
        contains(
          'background candidate: bash background: true, '
          'job board /tasks, --wait-for-jobs',
        ),
      );
      // AC6: the cancellation affordance rides the same line — the
      // background stop lever (job id once backgrounded) and the two
      // foreground levers with the honest unwinding caveat (until #1053).
      expect(out, contains('cancel: fa bash_job stop <id> once backgrounded'));
      expect(out, contains('Ctrl+C / inbox steering'));
      expect(out, contains('takes effect once the call unwinds'));
      expect(out, contains('#1053'));
      expect('background candidate'.allMatches(out), hasLength(1));
      expect('cancel:'.allMatches(out), hasLength(1));

      // Later ticks keep the liveness line but never re-escalate.
      now = now.add(const Duration(seconds: 60));
      cli.toolLivenessTickForTest();
      expect(
        'background candidate'.allMatches(io.out.toString()),
        hasLength(1),
      );
      expect('cancel:'.allMatches(io.out.toString()), hasLength(1));
      expect(io.out.toString(), contains('⏳ [bash] sleep 500 — running 360s'));

      shell.release();
      await run;
    });

    test('AC5: the printed elapsed cites the waiting clock — the same '
        'value the tracker state carries', () async {
      final cli = cliFor(stuckCallFake());
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.isNotEmpty,
        reason: 'the foreground call is being watched',
      );

      now = now.add(const Duration(seconds: 150));
      cli.toolLivenessTickForTest();
      expect(io.out.toString(), contains('running 150s'));
      final call = cli.toolLivenessCallsForTest.single;
      expect(now.difference(call.startedAt).inSeconds, 150);
      // The formatter over the SAME state reproduces the printed line —
      // one clock, one source of truth.
      expect(
        toolLivenessReminderLine(call, now),
        '⏳ [bash] sleep 500 — running 150s',
      );

      shell.release();
      await run;
    });
  });

  test('AC4: the same scenario through headless and line mode produces '
      'the same console records', () async {
    Future<List<String>> drive({required bool headless}) async {
      final shell = GatedShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final io = FakeCliIO();
      addTearDown(io.close);
      var clock = DateTime.utc(2026, 1, 1, 12);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: stuckCallFake().call,
        waitingClock: () => clock,
      );
      if (headless) {
        final run = cli.runHeadless('hi');
        await waitForIt(
          () => cli.toolLivenessCallsForTest.isNotEmpty,
          reason: 'headless: the call is being watched',
        );
        clock = clock.add(const Duration(seconds: 120));
        cli.toolLivenessTickForTest();
        clock = clock.add(const Duration(seconds: 180));
        cli.toolLivenessTickForTest();
        shell.release();
        await run;
      } else {
        final run = cli.run();
        io.sendLine('hi');
        await waitForIt(
          () => cli.toolLivenessCallsForTest.isNotEmpty,
          reason: 'line mode: the call is being watched',
        );
        clock = clock.add(const Duration(seconds: 120));
        cli.toolLivenessTickForTest();
        clock = clock.add(const Duration(seconds: 180));
        cli.toolLivenessTickForTest();
        shell.release();
        await waitForIt(() => !cli.isBusy, reason: 'the turn settles');
        io.sendLine('/exit');
        await run;
      }
      return livenessLines(io.out.toString());
    }

    final headless = await drive(headless: true);
    final lineMode = await drive(headless: false);
    expect(headless, [
      '⏳ [bash] sleep 500 — running 120s',
      '⏳ [bash] sleep 500 — running 300s · background candidate: '
          'bash background: true, job board /tasks, --wait-for-jobs · '
          'cancel: fa bash_job stop <id> once backgrounded; '
          'Ctrl+C / inbox steering takes effect once the call unwinds '
          '(until #1053)',
    ]);
    expect(lineMode, headless);
  });

  test('TUI mode is untouched: neither seam of the pair feeds there', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]), useTui: true);
    cli.toolCallStartedForTest('t1', 'bash', 'sleep 500');
    now = now.add(const Duration(seconds: 120));
    cli.toolLivenessTickForTest();
    expect(io.out, isEmpty, reason: 'the TUI waiting row owns this job');
    // The symmetric end seam is gated too: an end-without-start in TUI
    // mode must not touch the (idle) chain.
    cli.toolCallEndedForTest('t1');
    expect(cli.toolLivenessCallsForTest, isEmpty);
    cli.toolLivenessTickForTest();
    expect(io.out, isEmpty);
  });

  test('line mode (non-TUI): the watch prints through the seams', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.toolCallStartedForTest('t1', 'bash', 'sleep 500');
    now = now.add(const Duration(seconds: 120));
    cli.toolLivenessTickForTest();
    expect(io.out.toString(), contains('⏳ [bash] sleep 500 — running 120s'));
    cli.toolCallEndedForTest('t1');
    cli.toolLivenessTickForTest();
    expect(livenessLines(io.out.toString()), hasLength(1));
  });
}
