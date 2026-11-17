import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';
import 'wedge_env.dart';

/// Issue #2248, CLI-level: the session-IO wedge must fail the turn FAST
/// and VISIBLY, and the gauges must render.
///
/// - AC1: the EMFILE-shaped FileError rides the SessionException AND the
///   `provider error raw` fa.log line.
/// - AC2: a hung session append ends the turn at the configured bound —
///   named error, run settles, composer returns, next prompt accepted
///   (the 21-minute wedge regression).
/// - AC5: a session-IO failure inside the stall window reclassifies the
///   stall banner into the fs variant (restart levers, not /compact).
///   Per-session isolation: a sibling session's failure never relabels.
/// - AC6: /stats + the boot fa.log line render the fd gauge, the
///   per-minute fs-failure counter, and the sessions-container size.
void main() {
  const emfileMessage = 'Cannot open file (errno 24: Too many open files)';

  late MemoryExecutionEnv mem;
  late WedgeEnv env;
  late FakeCliIO io;

  setUp(() {
    mem = MemoryExecutionEnv(cwd: '/work');
    env = WedgeEnv(mem);
    io = FakeCliIO();
    SessionIoHealth.resetForTests();
  });

  tearDown(() async {
    SessionIoHealth.resetForTests();
    await io.close();
  });

  AgentCli buildCli({
    StreamFunction? stream,
    Duration sessionIoTimeout = const Duration(milliseconds: 400),
    Duration steeringStaleAfter = const Duration(minutes: 2),
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
        sessionIoTimeout: sessionIoTimeout,
        steeringStaleAfter: steeringStaleAfter,
        logging: const ResolvedLogSettings(consoleLevel: LogLevel.info),
      ),
      io: io,
      streamFunction: stream,
    );
  }

  Future<String> faLog() async =>
      (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';

  Future<String> firstSessionId() async {
    final repo = JsonlSessionRepo(fs: mem, sessionsRoot: '/sessions');
    for (var i = 0; i < 2000; i++) {
      final sessions = await repo.list(cwd: '/work');
      if (sessions.isNotEmpty) return sessions.first.id;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting: session persisted');
  }

  test(
    'AC1: a failing session append surfaces errno through the '
    'SessionException and the provider-error-raw fa.log line',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      env.failSessionAppendsWith = FileError(
        FileErrorCode.unknown,
        emfileMessage,
      );
      final fake = FakeStreamFunction([textTurn('should never render')]);
      final cli = buildCli(stream: fake.call);
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
      io.sendLine('hello');
      // The surfaced append failure renders on the console (unclassified
      // passthrough keeps the raw text).
      await io.out.waitUntilContains('Too many open files');

      final log = await faLog();
      expect(log, contains('provider error raw'));
      expect(log, contains('Too many open files'));
      expect(log, contains('errno 24'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC2: a hung session append ends the turn at the bound — named '
    'error, run settles, the next prompt is accepted',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      env.hangSessionAppends = true;
      // The wedged prompt dies at its persist (before any model call);
      // the NEXT prompt consumes the first scripted turn and settles.
      final fake = FakeStreamFunction([textTurn('next prompt answered')]);
      final cli = buildCli(stream: fake.call);
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      final wall = DateTime.now();
      io.sendLine('wedged please');
      // The bounded append failure renders named on the console — the
      // wait IS the wedge regression's observable.
      await io.out.waitUntilContains(
        'session IO timed out',
        seconds: 20,
        reason: 'the hung append must fail the turn at the 400ms bound',
      );
      await waitForIt(() => !cli.isBusy);
      // The 21-minute wedge regression: the settle is bounded.
      expect(
        DateTime.now().difference(wall),
        lessThan(const Duration(seconds: 30)),
      );

      final log = await faLog();
      expect(log, contains('provider error raw'));
      expect(log, contains('session IO timed out after 400ms'));
      // The console carries the raw (unclassified) error text too.
      expect(io.out.toString(), contains('session IO timed out'));

      // The composer returns: the next prompt is accepted and answered.
      env.hangSessionAppends = false;
      io.sendLine('hello again');
      await io.out.waitUntilContains('next prompt answered');

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC5: THIS session failing inside the stall window flips the banner '
    'to the fs variant — restart levers, never /compact',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final gate = Completer<void>();
      final gated = _GateKeeper([textTurn('wedge answer')], gate: gate);
      final cli = buildCli(
        stream: gated.call,
        steeringStaleAfter: const Duration(milliseconds: 80),
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      io.sendLine('start');
      await waitForIt(() => gated.calls >= 1 && cli.isBusy);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // This session's fresh fs failure, noted BEFORE the watchdog tick:
      // the first banner of the episode is the fs variant.
      SessionIoHealth.noteFailure(await firstSessionId(), emfileMessage);
      cli.checkPendingSteeringHealthForTest();
      final out = io.out.toString();
      expect(out, contains('session IO failing: $emfileMessage'));
      expect(out, contains('restart the host'));
      expect(out, contains('esc aborts'));
      expect(out, isNot(contains('/compact')));

      gate.complete();
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC5 isolation: a SIBLING session failure never relabels this '
    'run’s stall — the provider-stall banner stays',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final gate = Completer<void>();
      final gated = _GateKeeper([textTurn('wedge answer')], gate: gate);
      final cli = buildCli(
        stream: gated.call,
        steeringStaleAfter: const Duration(milliseconds: 80),
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      io.sendLine('start');
      await waitForIt(() => gated.calls >= 1 && cli.isBusy);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      SessionIoHealth.noteFailure('sibling-session', emfileMessage);
      cli.checkPendingSteeringHealthForTest();
      final out = io.out.toString();
      expect(out, contains('agent stalled'));
      expect(out, isNot(contains('session IO failing')));

      gate.complete();
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC6: /stats renders the three IO gauges (fds, fs failures, '
    'container size)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = buildCli(stream: fake.call);
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      // Seed container weight + a real failure count for the gauges.
      await env.writeFile('/sessions/extra/blob.bin', 'x' * 2048);
      SessionIoHealth.noteFailure('s1', 'boom');
      SessionIoHealth.noteFailure('s1', 'boom 2');

      io.sendLine('/stats');
      await io.out.waitUntilContains('sessions container:');
      final out = io.out.toString();
      expect(
        out,
        contains('open fds: -'),
        reason: 'the memory env exposes no fd dir',
      );
      expect(out, contains('fs-op failures (1m): 2'));
      expect(out, contains('sessions container:'));
      expect(out, matches(RegExp(r'sessions container: .+ in \d+ files')));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC6: the boot fa.log line carries the fd gauge and the fs-failure '
    'counter; the container-size line lands',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      // Seed a Linux-style fd dir: the gauge reads /proc/self/fd first.
      for (final fd in ['0', '1', '2']) {
        await env.writeFile('/proc/self/fd/$fd', '');
      }
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = buildCli(stream: fake.call);
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      final log = await faLog();
      final bootLine = log
          .split('\n')
          .firstWhere((line) => line.contains('fa boot'));
      expect(bootLine, contains('fds=3'));
      expect(bootLine, contains('fs_fail_1m='));

      // The container walk started unawaited at boot; the line lands.
      await waitForIt(
        () async => (await faLog()).contains('sessions_container bytes='),
        reason: 'the boot container-size line',
      );
      final containerLine = (await faLog())
          .split('\n')
          .firstWhere((line) => line.contains('sessions_container'));
      expect(containerLine, contains('files='));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC6 REG (RC round-1): the container walk never gates boot — boot '
    'completes while the walk is still pending on a gated .trash '
    'listing (boot discovery skips trash; the container walk does not), '
    'and the sessions_container line lands once the gate opens',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      await env.createDir('/sessions/.trash');
      await env.writeFile('/sessions/.trash/blob.bin', 'x' * 512);
      env.gatedListDirPaths = {'/sessions/.trash'};
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = buildCli(stream: fake.call);
      final run = cli.run();
      // Boot must NOT wait on the container walk: boot's own discovery
      // skips .trash, so a gated .trash listing can only hold the
      // container-size walk — and boot still completes.
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
      final bootLog = await faLog();
      expect(
        bootLog,
        contains('fa boot'),
        reason: 'boot landed while the walk was still gated',
      );
      expect(bootLog, isNot(contains('sessions_container')));

      env.listDirGate.complete();
      await waitForIt(
        () async => (await faLog()).contains('sessions_container bytes='),
        reason: 'the unawaited walk lands once the gate opens',
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC4 REG (RC round-1): fail→ok→hang — a hang mid-recovery-flush '
    'fails bounded and never wedges the append chain or the exit drain',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      env.failNextLogAppends = 1; // call #0 (boot line) fails → buffering.
      env.failLogMessage = emfileMessage;
      env.hangLogAppendsFrom = 2; // call #1 (the container line) succeeds
      // → recovery fires; the FLUSH (call #2) and everything after hang.
      final cli = buildCli(
        stream: FakeStreamFunction([textTurn('ok')]).call,
        sessionIoTimeout: const Duration(milliseconds: 300),
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
      cli.logDiagnosticForTest('probe-1');
      cli.logDiagnosticForTest('probe-2');
      // The wedge-proof: with the flush unbounded this await never
      // returns (the gh-2097 chain + the exit drain would be wedged).
      await cli.flushDiagnosticLog().timeout(const Duration(seconds: 10));

      final log = await faLog();
      // Exactly the line whose LIVE append succeeded landed; everything
      // after the hang buffered and exits via the drain.
      expect(log, contains('sessions_container'));
      expect(log, isNot(contains('probe-1')));
      expect(log, isNot(contains('probe-2')));
      expect(log, isNot(contains('fa boot')));
      final out = io.out.toString();
      expect(out, contains('fa_log_sink=fail(errno='));
      // The recovery marker hung — the sink stays failing and the
      // buffered lines exit-drain.
      expect(out, contains('(marker failed)'));
      expect(out, contains('fa_log_sink=exit_drain buffered='));

      io.sendLine('/exit');
      await run;
    },
  );
}

/// The gated stream of agent_cli_stalled_run_test: one call hangs on
/// [gate] (or until the run aborts) — the wedge shape.
class _GateKeeper {
  _GateKeeper(this.turns, {required this.gate});

  final List<List<AssistantMessageEvent>> turns;
  final Completer<void> gate;
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == 1) {
      unawaited(() async {
        while (!(cancelToken?.isCancelled ?? false)) {
          if (gate.isCompleted) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final cancelled = cancelToken?.isCancelled ?? false;
        final empty = testAssistant();
        final partial = testAssistant(
          content: const [TextContent(text: '')],
          stopReason: StopReason.aborted,
        );
        emit(
          cancelled
              ? [
                  StartEvent(partial: empty),
                  DoneEvent(reason: StopReason.aborted, message: partial),
                ]
              : turns.removeAt(0),
        );
      }());
    } else if (turns.isEmpty) {
      stream.end();
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}
