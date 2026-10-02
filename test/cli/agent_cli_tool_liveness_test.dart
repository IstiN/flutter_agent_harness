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
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
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

  AgentCli cliFor(
    StreamFunction fake, {
    bool useTui = false,
    WaitingConfig waiting = const WaitingConfig(),
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      waiting: waiting,
    ),
    io: io,
    streamFunction: fake,
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
      final cli = cliFor(stuckCallFake().call);
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
      final cli = cliFor(stuckCallFake().call);
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
      final cli = cliFor(stuckCallFake().call);
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
      final cli = cliFor(stuckCallFake().call);
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

  test('TUI mode: the watch arms for the #1185 nudge (AC4), the console '
      'lines stay out', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call, useTui: true);
    cli.toolCallStartedForTest('t1', 'bash', 'sleep 500');
    now = now.add(const Duration(seconds: 120));
    cli.toolLivenessTickForTest();
    expect(io.out, isEmpty, reason: 'the TUI waiting row owns this surface');
    cli.toolCallEndedForTest('t1');
    expect(cli.toolLivenessCallsForTest, isEmpty);
    cli.toolLivenessTickForTest();
    expect(io.out, isEmpty);
  });

  test('line mode (non-TUI): the watch prints through the seams', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    cli.toolCallStartedForTest('t1', 'bash', 'sleep 500');
    now = now.add(const Duration(seconds: 120));
    cli.toolLivenessTickForTest();
    expect(io.out.toString(), contains('⏳ [bash] sleep 500 — running 120s'));
    cli.toolCallEndedForTest('t1');
    cli.toolLivenessTickForTest();
    expect(livenessLines(io.out.toString()), hasLength(1));
  });

  group('#1185: escalation nudges the model', () {
    /// The `[liveness watchdog]` texts among a context's user messages.
    List<String> nudgeTexts(Context context) => [
      for (final message in context.messages)
        if (message is UserMessage &&
            _messageText(message).contains(nudgeAnchor))
          _messageText(message),
    ];

    /// Two bash calls the mock shell holds until released, then the wrap.
    FakeStreamFunction twoStuckCallsFake() => FakeStreamFunction([
      toolTurn([
        const ToolCall(
          id: 't1',
          name: 'bash',
          arguments: {'command': 'sleep 500'},
        ),
      ]),
      toolTurn([
        const ToolCall(
          id: 't2',
          name: 'bash',
          arguments: {'command': 'sleep 900'},
        ),
      ]),
      textTurn('done'),
    ]);

    test('AC1: an escalated call steers ONE nudge — the model sees it next '
        'turn and the session records it', () async {
      final fake = twoStuckCallsFake();
      final cli = cliFor(fake.call);
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.isNotEmpty,
        reason: 'the foreground call is being watched',
      );

      now = now.add(const Duration(seconds: 300));
      cli.toolLivenessTickForTest();
      expect(cli.toolNudgesSentForTest, 1);
      // The operator surface is unchanged: the escalation line still
      // prints, and the nudge itself never prints — it rides steering.
      expect(io.out.toString(), contains('background candidate:'));
      expect(io.out.toString(), isNot(contains(nudgeAnchor)));

      // The call is still stuck (gated). Ending it lets the run reach the
      // step boundary where the queued nudge delivers (the non-yield tool
      // path; the yield-aware bash path backgrounds instead and delivers
      // the same way).
      shell.release();
      await waitForIt(
        () => fake.calls >= 2,
        reason: 'the nudge reached the next request',
      );
      final nudges = nudgeTexts(fake.contexts[1]);
      expect(nudges, hasLength(1));
      expect(nudges.single, contains('`bash`'));
      expect(nudges.single, contains('"sleep 500"'));
      expect(nudges.single, contains('running 300s'));
      // AC3: the model's «keep waiting» turn must not re-nudge the call,
      // and nothing force-kills it — the call completed on its own.
      await run;
      expect(cli.toolNudgesSentForTest, 1);

      // The session JSONL records the merged nudge as a user message.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      final session = await repo.open(sessions.first);
      final recorded = [
        for (final entry in await session.getEntries())
          if (entry is MessageRecord &&
              entry.message is UserMessage &&
              _messageText(entry.message as UserMessage).contains(nudgeAnchor))
            _messageText(entry.message as UserMessage),
      ];
      expect(recorded, hasLength(1));
    });

    test('AC2: ladder extensions never re-nudge a stuck call; a NEW stuck '
        'call gets its own single injection', () async {
      final shell = PerCallGatedShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final io = FakeCliIO();
      final fake = twoStuckCallsFake();
      final cli = AgentCli(
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
      );
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.any((call) => call.id == 't1'),
        reason: 't1 is being watched',
      );

      now = now.add(const Duration(seconds: 300));
      cli.toolLivenessTickForTest();
      expect(cli.toolNudgesSentForTest, 1);
      // Two more escalation-tier ticks (the ladder keeps reminding) —
      // still exactly one nudge for t1.
      now = now.add(const Duration(seconds: 60));
      cli.toolLivenessTickForTest();
      now = now.add(const Duration(seconds: 60));
      cli.toolLivenessTickForTest();
      expect(cli.toolNudgesSentForTest, 1);

      shell.releaseNext();
      await waitForIt(
        () => cli.toolLivenessCallsForTest.any((call) => call.id == 't2'),
        reason: 't2 started',
      );
      now = now.add(const Duration(seconds: 300));
      cli.toolLivenessTickForTest();
      expect(cli.toolNudgesSentForTest, 2, reason: 'a new call nudges afresh');
      expect(
        io.out.toString(),
        contains('⏳ [bash] sleep 900 — running 300s'),
        reason: 'the second call escalates on the same console channel',
      );
      shell.releaseNext();
      await run;
    });

    test(
      'E2: at most three nudges per turn; the budget refills next turn',
      () async {
        final shell = PerCallGatedShell();
        final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
        final io = FakeCliIO();
        ToolCall call(String id) =>
            ToolCall(id: id, name: 'bash', arguments: {'command': 'sleep 500'});
        final fake = FakeStreamFunction([
          toolTurn([call('t1')]),
          toolTurn([call('t2')]),
          toolTurn([call('t3')]),
          toolTurn([call('t4')]),
          textTurn('done'),
          toolTurn([call('t5')]),
          textTurn('done'),
        ]);
        final cli = AgentCli(
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
        );
        final run = cli.run();
        io.sendLine('hi');
        // Turn 1: four distinct stuck calls — the cap holds at three.
        for (var i = 1; i <= 4; i++) {
          final id = 't$i';
          await waitForIt(
            () => cli.toolLivenessCallsForTest.any((c) => c.id == id),
            reason: '$id is being watched',
          );
          now = now.add(const Duration(seconds: 300));
          cli.toolLivenessTickForTest();
          shell.releaseNext();
          await waitForIt(
            () => !cli.toolLivenessCallsForTest.any((c) => c.id == id),
            reason: '$id ended',
          );
        }
        expect(cli.toolNudgesSentForTest, 3, reason: 'the E2 storm cap');
        await waitForIt(() => !cli.isBusy, reason: 'turn 1 settles');

        // Turn 2: a fresh turn refills the budget — one stuck call nudges.
        io.sendLine('again');
        await waitForIt(
          () => cli.toolLivenessCallsForTest.any((c) => c.id == 't5'),
          reason: 'the second turn stuck call is watched',
        );
        now = now.add(const Duration(seconds: 300));
        cli.toolLivenessTickForTest();
        expect(cli.toolNudgesSentForTest, 4);
        shell.releaseNext();
        await waitForIt(() => !cli.isBusy, reason: 'turn 2 settles');
        io.sendLine('/exit');
        await run;
      },
    );

    test('E5: waiting.toolNudge false keeps the console line, drops the '
        'injection', () async {
      final cli = cliFor(
        stuckCallFake().call,
        waiting: const WaitingConfig(toolNudge: false),
      );
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.toolLivenessCallsForTest.isNotEmpty,
        reason: 'the foreground call is being watched',
      );
      now = now.add(const Duration(seconds: 300));
      cli.toolLivenessTickForTest();
      expect(io.out.toString(), contains('background candidate:'));
      expect(cli.toolNudgesSentForTest, 0);
      shell.release();
      await run;
    });

    test('AC4: the nudge fires in TUI runs too — only the console lines '
        'stay out', () async {
      final hang = AbortableStreamFunction();
      final cli = cliFor(hang.call, useTui: true);
      final run = cli.runHeadless('hi');
      await waitForIt(() => hang.started, reason: 'the run is streaming');
      cli.toolCallStartedForTest('t1', 'bash', 'sleep 500');
      now = now.add(const Duration(seconds: 300));
      cli.toolLivenessTickForTest();
      expect(cli.toolNudgesSentForTest, 1, reason: 'TUI parity');
      expect(
        io.out.toString(),
        isNot(contains('⏳ [')),
        reason: 'the TUI waiting row owns the presentation',
      );
      io.interrupt();
      await run;
    });
  });
}

/// A [Shell] whose every exec blocks on its own gate: each tool call is
/// individually holdable, so a second stuck call stays observable in
/// flight (the shared [GatedShell] single gate releases every later call
/// at once).
final class PerCallGatedShell implements Shell {
  final _pending = <Completer<void>>[];

  /// Completes the oldest pending exec.
  void releaseNext() {
    if (_pending.isNotEmpty) _pending.removeAt(0).complete();
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final gate = Completer<void>();
    _pending.add(gate);
    await gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

/// The nudge's sender anchor (issue #1185).
const String nudgeAnchor = '[liveness watchdog]';

/// The text of a user message (string or content-block content).
String _messageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
}
