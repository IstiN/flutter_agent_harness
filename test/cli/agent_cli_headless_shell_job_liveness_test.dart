@TestOn('vm')
library;

/// gh-1459 ask #4: a draining headless `fa -p` run must not leave the
/// model blind between "final answer" and "settle" — every
/// `headless.shellJobQuietMs` (default 5 min) of a still-running awaited
/// shell job, ONE compact system-notice is steered into a fresh turn
/// (`job <id> running · <elapsed> elapsed · tail: …` + the bash_job
/// escape hatch), so the model can keep waiting, inspect, or kill.
///
/// Covered with a manually-advanced fake clock (`waitingClock`/
/// `waitingSleep`): a 12-minute quiet job at a 5-minute cadence steers
/// exactly TWO notices (at 5m and 10m, with the right id/elapsed/tail);
/// a model probe (`bash_job status`) after the first notice suppresses
/// the 10m one — one steer budget per threshold crossing, never a spam
/// loop.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/headless_config.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The user-visible marker of an interim liveness notice
/// (`_steerHeadlessLiveness`).
const _livenessMarker = ' running · ';

/// Routes every run by its last user message: liveness notices replay
/// [livenessScripts] in order, the settle notice replays [settleScript],
/// the lead runs replay [leadScripts], anything unscripted answers
/// 'noted.' so nothing wedges. Every context is recorded.
class _LivenessRoutingStream {
  _LivenessRoutingStream({
    required List<List<AssistantMessageEvent>> leadScripts,
    required List<List<AssistantMessageEvent>> livenessScripts,
    required List<AssistantMessageEvent> settleScript,
  }) : _leadScripts = List.of(leadScripts),
       // SHARED, not copied: the caller populates the liveness reactions
       // after boot, once the job id is known — the router pops them in
       // order as the interim notices are steered.
       _livenessScripts = livenessScripts,
       _settleScript = settleScript;

  final List<List<AssistantMessageEvent>> _leadScripts;
  final List<List<AssistantMessageEvent>> _livenessScripts;
  final List<AssistantMessageEvent> _settleScript;
  final contexts = <Context>[];

  /// The last user-message text AT call time, per [contexts] entry. The
  /// Context objects themselves are mutated as a run progresses (tool
  /// results append user messages), so call-time snapshots are the only
  /// reliable way to know what a run was steered for.
  final lastUserTexts = <String>[];
  String _lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) return messageText(message);
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final last = _lastUserText(context);
    lastUserTexts.add(last);
    final List<AssistantMessageEvent> script;
    if (last.contains(_livenessMarker)) {
      script = _livenessScripts.isNotEmpty
          ? _livenessScripts.removeAt(0)
          : textTurn('noted.');
    } else if (last.contains('finished with exit code')) {
      script = _settleScript;
    } else if (_leadScripts.isNotEmpty) {
      script = _leadScripts.removeAt(0);
    } else {
      script = textTurn('noted.');
    }
    final stream = AssistantMessageEventStream();
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [Shell] + [BackgroundShell] whose detached jobs stay RUNNING until
/// the test finishes them with an explicit exit code.
class _LivenessShell implements Shell, BackgroundShell {
  final jobs = <_LivenessJob>[];

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async => const Err(
    ExecutionError(
      ExecutionErrorCode.shellUnavailable,
      'No shell is available in this environment',
    ),
  );

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _LivenessJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _LivenessJob implements ShellJob {
  _LivenessJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

  int? _exitCode;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_settled.isCompleted;
  @override
  int? get exitCode => _exitCode;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  void finish(int code) {
    if (_settled.isCompleted) return;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Future<void> stop() async => finish(9);
}

Future<void> _waitFor(
  bool Function() condition, {
  required String reason,
  String Function()? dump,
}) async {
  for (var i = 0; i < 4000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: $reason${dump == null ? '' : '\n${dump()}'}');
}

/// The fake-clock/gated-sleep harness of a liveness drain run. Time only
/// advances when [releaseNextSleep] lets a drain sleep complete, so the
/// test observes every steer deterministically.
class _LivenessHarness {
  _LivenessHarness._({
    required this.cli,
    required this.io,
    required this.stream,
    required this.shell,
    required this.env,
    required this.run,
    required DateTime Function() clockOf,
    required List<Completer<void>> gates,
    required this.livenessScripts,
    required this.runCode,
    required this.runFailure,
  }) : _clockOf = clockOf,
       _gates = gates;

  final AgentCli cli;
  final FakeCliIO io;
  final _LivenessRoutingStream stream;
  final _LivenessShell shell;
  final MemoryExecutionEnv env;
  final Future<int> run;
  final DateTime Function() _clockOf;
  final List<Completer<void>> _gates;
  final int Function() runCode;
  final Object? Function() runFailure;

  /// The router's liveness reaction queue — populate after the job id is
  /// known; popped in order as the interim notices are steered.
  final List<List<AssistantMessageEvent>> livenessScripts;

  DateTime get clock => _clockOf();
  int get pendingSleeps => _gates.where((g) => !g.isCompleted).length;

  /// Debug dump for wait timeouts.
  String dump() =>
      'runCode=${runCode()} runFailure=${runFailure()}\n'
      'clock=$clock\n'
      'contexts=${stream.contexts.length}\n'
      'lastUserTexts:\n${stream.lastUserTexts.join('\n---\n')}\n'
      'io.out:\n${io.out.toString()}';

  /// Lets the oldest parked drain sleep complete (time advances by the
  /// duration the drain asked for).
  void releaseNextSleep() {
    for (final gate in _gates) {
      if (!gate.isCompleted) {
        gate.complete();
        return;
      }
    }
    fail('no parked drain sleep to release');
  }

  /// The runs steered by interim liveness notices (in order), classified
  /// by the CALL-TIME user text (the Context objects mutate as tool
  /// rounds append results).
  List<Context> get livenessRuns => [
    for (var i = 0; i < stream.contexts.length; i++)
      if (stream.lastUserTexts[i].contains(_livenessMarker)) stream.contexts[i],
  ];

  /// The call-time user text of the n-th liveness run (1-based).
  String livenessNotice(int n) {
    var seen = 0;
    for (var i = 0; i < stream.contexts.length; i++) {
      if (stream.lastUserTexts[i].contains(_livenessMarker)) {
        seen++;
        if (seen == n) return stream.lastUserTexts[i];
      }
    }
    fail('only $seen liveness notice(s) were steered');
  }
}

/// Boots the gh-1459 drain shape under a fake clock: the model starts a
/// long background job and ends its turn; the drain then parks on the
/// gated sleeps. The caller populates [h.livenessScripts] (and
/// [h.settleScript]) once the job id is known — the router pops them in
/// order when the matching notices are steered.
Future<_LivenessHarness> livenessShape({
  HeadlessConfig headless = const HeadlessConfig(
    shellJobDrainMs: 20 * 60 * 1000,
  ),
}) async {
  final io = FakeCliIO();
  final shell = _LivenessShell();
  final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
  final livenessScripts = <List<AssistantMessageEvent>>[];
  final stream = _LivenessRoutingStream(
    leadScripts: [
      toolTurn([
        const ToolCall(
          id: 't1',
          name: 'bash',
          arguments: {'command': 'dart test --exclude-tags integration', 'background': true},
        ),
      ]),
      textTurn('Started the suite in the background. Waiting on it.'),
    ],
    livenessScripts: livenessScripts,
    settleScript: textTurn('suite finished green — response.md written'),
  );
  // The fake clock starts at real now — job.startedAt (real DateTime.now
  // at registration) sits a few ms ahead, so each wake lands EXACTLY on
  // its threshold (5m, 10m, …) regardless of the offset.
  var clock = DateTime.now();
  final gates = <Completer<void>>[];
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      headless: headless,
    ),
    io: io,
    streamFunction: stream.call,
    waitingClock: () => clock,
    waitingSleep: (d) {
      clock = clock.add(d);
      final gate = Completer<void>();
      gates.add(gate);
      return gate.future;
    },
  );
  final runFuture = cli.runHeadless('run the full test suite');
  // Surface a crashed run to the waits instead of hanging silently.
  Object? runFailure;
  var runCode = -1;
  final run = runFuture.then((c) {
    runCode = c;
    return c;
  }, onError: (Object e) {
    runFailure = e;
    return 999;
  });
  await _waitFor(() => shell.jobs.isNotEmpty, reason: 'the job registers');
  return _LivenessHarness._(
    cli: cli,
    io: io,
    stream: stream,
    shell: shell,
    env: env,
    run: run,
    livenessScripts: livenessScripts,
    runCode: () => runCode,
    runFailure: () => runFailure,
    clockOf: () => clock,
    gates: gates,
  );
}

void main() {
  test(
    'a 12m quiet job at a 5m cadence steers exactly 2 interim notices '
    '(at 5m and 10m) with the correct id/elapsed/tail, then the settle '
    'still drains normally',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final h = await livenessShape();
      final job = h.shell.jobs.single;
      // Six log lines — the notice tail shows the LAST FIVE.
      await h.env.writeFile(job.logPath, [
        for (var i = 1; i <= 6; i++) 'log-line-$i',
      ].join('\n'));
      h.livenessScripts.add(textTurn('still waiting.'));
      h.livenessScripts.add(textTurn('still waiting.'));

      // Release the 5m sleep → the first notice is steered.
      await _waitFor(() => h.pendingSleeps >= 1, reason: 'the first drain sleep parks');
      h.releaseNextSleep();
      await _waitFor(() => h.livenessRuns.length == 1, reason: 'the 5m notice is steered');
      expect(h.livenessNotice(1), contains(job.id));
      expect(h.livenessNotice(1), contains('5m elapsed'));
      expect(h.livenessNotice(1), contains('log-line-2'));
      expect(h.livenessNotice(1), isNot(contains('log-line-1')));
      expect(h.livenessNotice(1), contains('bash_job'));
      expect(h.livenessNotice(1), contains('stop'));

      // Release the 10m sleep → the second notice is steered.
      await _waitFor(() => h.pendingSleeps >= 1, reason: 'the second drain sleep parks');
      h.releaseNextSleep();
      await _waitFor(() => h.livenessRuns.length == 2, reason: 'the 10m notice is steered');
      expect(h.livenessNotice(2), contains(job.id));
      expect(h.livenessNotice(2), contains('10m elapsed'));

      // The job settles at 12m (mid-way to the 15m threshold): the drain
      // wakes on the settle, never steers a third time, and the settle
      // notice drains normally.
      job.finish(0);
      final code = await h.run;

      expect(code, 0);
      expect(h.livenessRuns.length, 2, reason: 'exactly one steer per threshold crossing');
      final texts = h.stream.lastUserTexts.last;
      expect(
        texts,
        contains('finished with exit code'),
        reason: 'the settle notice still steers the final reaction run',
      );
      expect(
        h.io.out.toString(),
        isNot(contains('detached')),
        reason: 'the job was drained, never detached',
      );
      h.io.close();
    },
  );

  test(
    'a model probe (bash_job status) after the first notice suppresses '
    'the next threshold crossing',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // The reaction to the 5m notice: the model probes the job itself
      // through the real bash_job tool path — that counts as liveness
      // (gh-1459 ask #4).
      final h = await livenessShape();
      final job = h.shell.jobs.single;
      h.livenessScripts.add(
        toolTurn([
          ToolCall(
            id: 'p1',
            name: 'bash_job',
            arguments: {'action': 'status', 'id': job.id},
          ),
        ]),
      );
      await h.env.writeFile(job.logPath, 'quiet so far');

      // Release the 5m sleep → the first notice is steered; the model
      // answers it with a bash_job status probe.
      await _waitFor(
        () => h.pendingSleeps >= 1,
        reason: 'the first drain sleep parks',
        dump: h.dump,
      );
      h.releaseNextSleep();
      await _waitFor(
        () => h.livenessRuns.length == 1,
        reason: 'the 5m notice is steered',
        dump: h.dump,
      );
      // The probe executed through the real bash_job tool path.
      await _waitFor(
        () => h.cli.shellJobsRegistryForTest.job(job.id)!.probeGeneration > 0,
        reason: 'the model probe marks the job probed',
        dump: h.dump,
      );

      // Release the 10m sleep → the crossing is SKIPPED (the model
      // probed since the 5m steer); the drain parks on the next sleep.
      await _waitFor(() => h.pendingSleeps >= 1, reason: 'the second drain sleep parks');
      h.releaseNextSleep();
      await _waitFor(
        () => h.pendingSleeps >= 1 || !job.isRunning,
        reason: 'the drain re-parks (the skipped steer starts no run)',
      );
      expect(
        h.livenessRuns.length,
        1,
        reason: 'the 10m steer is suppressed by the model probe',
      );

      job.finish(0);
      final code = await h.run;

      expect(code, 0);
      expect(h.livenessRuns.length, 1, reason: 'steer budget respected: 1, never 2');
      expect(
        h.stream.lastUserTexts.last,
        contains('finished with exit code'),
      );
      h.io.close();
    },
  );
}
