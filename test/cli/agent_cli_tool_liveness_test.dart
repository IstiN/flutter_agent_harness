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
    out.split('\n').where((line) => line.contains('○ [')).toList();

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
  /// test releases it, then the run wraps up. A slow build — issue #1349
  /// denies a bare long foreground `sleep` at validation, so the stand-in
  /// for a long-running call must be legitimate work.
  FakeStreamFunction stuckCallFake() => FakeStreamFunction([
    toolTurn([
      const ToolCall(
        id: 't1',
        name: 'bash',
        arguments: {'command': 'make release'},
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
      expect(
        io.out.toString(),
        contains('○ [bash] make release — running 120s'),
      );

      now = now.add(const Duration(seconds: 60));
      cli.toolLivenessTickForTest();
      expect(
        io.out.toString(),
        contains('○ [bash] make release — running 180s'),
      );

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
      expect(
        io.out.toString(),
        contains('○ [bash] make release — running 360s'),
      );

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
        '○ [bash] make release — running 150s · $toolLivenessForegroundHint',
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
      '○ [bash] make release — running 120s · $toolLivenessForegroundHint',
      '○ [bash] make release — running 300s · background candidate: '
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
    expect(io.out.toString(), contains('○ [bash] sleep 500 — running 120s'));
    cli.toolCallEndedForTest('t1');
    cli.toolLivenessTickForTest();
    expect(livenessLines(io.out.toString()), hasLength(1));
  });

  group('#1185: escalation nudges the model', () {
    /// The `[liveness watchdog]` texts among a context's user messages.
    List<String> nudgeTexts(Context context) => [
      for (final message in context.messages)
        if (message is UserMessage &&
            _messageText(message).contains(toolNudgeAnchor))
          _messageText(message),
    ];

    /// Two bash calls the mock shell holds until released, then the wrap.
    FakeStreamFunction twoStuckCallsFake() => FakeStreamFunction([
      toolTurn([
        const ToolCall(
          id: 't1',
          name: 'bash',
          arguments: {'command': 'make release'},
        ),
      ]),
      toolTurn([
        const ToolCall(
          id: 't2',
          name: 'bash',
          arguments: {'command': 'make docker-pull'},
        ),
      ]),
      textTurn('done'),
      // The follow-up queue drains one message per stop-check: each
      // pending nudge delivers in its own extension turn.
      textTurn('noted'),
      textTurn('noted'),
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
      // prints, and the nudge itself never prints — it rides the
      // follow-up queue.
      expect(io.out.toString(), contains('background candidate:'));
      expect(io.out.toString(), isNot(contains(toolNudgeAnchor)));

      // The call is still stuck (gated). Ending it lets the run unwind:
      // t2 fires and answers, then the stop-check drains the follow-up
      // queue and the nudge reaches the model in its own turn — for BOTH
      // tool flavors, with no soft-yield interruption (the no-yield
      // regression below pins that a yield-aware bash is never
      // backgrounded by the notice).
      shell.release();
      await run;
      final nudges = nudgeTexts(fake.contexts.last);
      expect(nudges, hasLength(1));
      expect(nudges.single, contains('`bash`'));
      expect(nudges.single, contains('"make release"'));
      expect(nudges.single, contains('running 300s'));
      // The turn BEFORE the drain must not carry the nudge: it delivered
      // at the boundary, not retroactively into the tool-result turn.
      expect(nudgeTexts(fake.contexts[1]), isEmpty);
      // AC3: the model's «keep waiting» turn must not re-nudge the call,
      // and nothing force-kills it — the call completed on its own.
      expect(cli.toolNudgesSentForTest, 1);

      // The session JSONL records the delivered nudge as a user message.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      final session = await repo.open(sessions.first);
      final recorded = [
        for (final entry in await session.getEntries())
          if (entry is MessageRecord &&
              entry.message is UserMessage &&
              _messageText(
                entry.message as UserMessage,
              ).contains(toolNudgeAnchor))
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
        contains('○ [bash] make docker-pull — running 300s'),
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
        ToolCall call(String id) => ToolCall(
          id: id,
          name: 'bash',
          arguments: {'command': 'make release'},
        );
        final fake = FakeStreamFunction([
          toolTurn([call('t1')]),
          toolTurn([call('t2')]),
          toolTurn([call('t3')]),
          toolTurn([call('t4')]),
          textTurn('done'),
          // The follow-up queue drains one message per stop-check: each
          // pending nudge delivers in its own extension turn.
          textTurn('noted'),
          textTurn('noted'),
          textTurn('noted'),
          toolTurn([call('t5')]),
          textTurn('done'),
          // Turn 2's drained nudge delivers in its own extension turn.
          textTurn('noted'),
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

    test(
      'no-yield: the nudge must NOT fire the soft-yield token — a stuck '
      'yield-aware bash stays in the foreground until the model decides',
      () async {
        final shell = YieldAwareGatedShell();
        final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
        final io = FakeCliIO();
        final fake = FakeStreamFunction([
          toolTurn([
            const ToolCall(
              id: 't1',
              name: 'bash',
              arguments: {'command': 'make release'},
            ),
          ]),
          textTurn('done'),
          // The follow-up queue drains one message per stop-check: the
          // single pending nudge delivers in its own extension turn.
          textTurn('noted'),
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
        final run = cli.runHeadless('hi');
        await waitForIt(
          () => cli.toolLivenessCallsForTest.any((call) => call.id == 't1'),
          reason: 'the yield-aware bash is being watched',
        );

        now = now.add(const Duration(seconds: 300));
        cli.toolLivenessTickForTest();
        expect(cli.toolNudgesSentForTest, 1);
        // The soft-yield cancel fires synchronously on a steer enqueue — a
        // beat later, nothing may have moved to the background and the
        // model must not have been re-entered.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(fake.calls, 1, reason: 'no soft-yield interruption');
        expect(
          shell.hasUnsettledJobs,
          isTrue,
          reason: 'the job is still awaited in the foreground',
        );

        // The call ends on its own; the transcript never shows the
        // moved-to-background result, and the nudge delivers at the
        // stop-check in its own turn.
        shell.settleAll();
        await run;
        for (final context in fake.contexts) {
          expect(
            [
              for (final m in context.messages)
                if (m is UserMessage) _messageText(m),
            ].join('\n'),
            isNot(contains('moved to background job')),
            reason: 'the nudge must not background the call',
          );
        }
        expect(nudgeTexts(fake.contexts.last), hasLength(1));
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
        isNot(contains('○ [')),
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

/// A [Shell] + [BackgroundShell] for the yield-aware bash path: every
/// foreground call takes `_shellViaJob` (jobs supported + a live yield
/// token) and the detached job NEVER settles until the test settles it —
/// the production stuck shape the soft-yield would interrupt.
final class YieldAwareGatedShell implements Shell, BackgroundShell {
  final _jobs = <_GatedJob>[];

  /// Whether any detached job is still awaited (never settled).
  bool get hasUnsettledJobs => _jobs.any((job) => job.isRunning);

  /// Completes every pending job (the command finished on its own).
  void settleAll() {
    for (final job in _jobs) {
      job.settle();
    }
  }

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _GatedJob(id: id, command: command, logPath: logPath);
    _jobs.add(job);
    return Ok(job);
  }
}

final class _GatedJob implements ShellJob {
  _GatedJob({required this.id, required this.command, required this.logPath});

  final _settled = Completer<void>();

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;
  @override
  bool get isRunning => !_settled.isCompleted;
  @override
  int? get exitCode => _settled.isCompleted ? 0 : null;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  void settle() {
    if (!_settled.isCompleted) _settled.complete();
  }

  @override
  Future<void> stop() async => settle();
}

/// The text of a user message (string or content-block content).
String _messageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
}
