@TestOn('vm')
library;

/// gh-1459: headless `fa -p` must DRAIN live background shell jobs the
/// same way it already drains in-flight subagents — wait for the settles,
/// let `_onShellJobSettled` steer each result into a fresh idle turn, let
/// the reaction run finish, then exit. The gh-1440 shape: the model ends
/// its turn while its full test suite still runs in the background; the
/// pre-fix headless exit detached (killed) the job and the deliverable
/// gated on it was never written.
///
/// Covered with a controllable fake [BackgroundShell]: settle mid-drain →
/// the notice is steered → the reaction run executes → the exit code
/// lands only AFTER that run; a nonzero settle steers the same way; a
/// suppressed job ([ShellJobEntry.suppressSettleNotification] — an inline
/// consumer already reported the result) is not awaited; a never-settling
/// job hits the `headless.shellJobDrainMs` ceiling and the run detaches
/// with the summary (the documented degradation).

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/headless_config.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The user-visible tail of the settle notice the CLI steers into the
/// reaction run (`_onShellJobSettled`).
const _noticeMarker = 'Background shell job ';

/// A [StreamFunction] routing every run by its last user message:
/// - the reaction run (the shell-job settle notice is its payload)
///   answers 'suite finished green — response.md written';
/// - the lead runs (the prompt, the tool rounds) replay [leadTurns];
/// - anything unscripted answers 'noted.' so nothing wedges.
/// Every context is recorded — assertions read the transcript with eyes.
class _RoutingStream {
  _RoutingStream({required List<List<AssistantMessageEvent>> leadTurns})
    : _leadTurns = List.of(leadTurns);

  final List<List<AssistantMessageEvent>> _leadTurns;
  final contexts = <Context>[];

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
    final script = _lastUserText(context).contains(_noticeMarker)
        ? textTurn('suite finished green — response.md written')
        : _leadTurns.isNotEmpty
        ? _leadTurns.removeAt(0)
        : textTurn('noted.');
    final stream = AssistantMessageEventStream();
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [Shell] + [BackgroundShell] whose detached jobs stay RUNNING until
/// the test finishes them with an explicit exit code — the controllable
/// background job.
class _DrainShell implements Shell, BackgroundShell {
  final jobs = <_DrainJob>[];

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    // Foreground exec stays unavailable so boot probes stay out of the
    // way; only detached jobs work here.
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'No shell is available in this environment',
      ),
    );
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _DrainJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _DrainJob implements ShellJob {
  _DrainJob({required this.id, required this.command, required this.logPath});

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

  /// The test's settle trigger: the job exits with [code].
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
}) async {
  for (var i = 0; i < 4000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: $reason');
}

/// A [StreamFunction] for the round-cap shape: the reaction run of job
/// k's settle notice SPAWNS job k+1 (a tool round), so every drain round
/// ends with a fresh live job — the drain only ends via the 10-round
/// cap, while the wall-clock ceiling still has budget.
class _ChainedRouter {
  _ChainedRouter({required List<List<AssistantMessageEvent>> freshTurns})
    : _freshTurns = List.of(freshTurns);

  final List<List<AssistantMessageEvent>> _freshTurns;
  final contexts = <Context>[];

  String _lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) return messageText(message);
    }
    return '';
  }

  /// A continuation call's messages carry a [ToolResultMessage] ahead of
  /// the last user message; a fresh call's last message IS the user
  /// payload that started the run.
  bool _isToolContinuation(Context context) {
    for (final message in context.messages.reversed) {
      if (message is ToolResultMessage) return true;
      if (message is UserMessage) return false;
    }
    return false;
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final last = _lastUserText(context);
    final List<AssistantMessageEvent> script;
    if (!_isToolContinuation(context) &&
        (last.contains(_noticeMarker) || last.contains(' elapsed · tail: '))) {
      // A settle or liveness notice run: its reaction spawns the NEXT
      // background job (or answers once the chain is scripted out).
      script = _freshTurns.isNotEmpty
          ? _freshTurns.removeAt(0)
          : textTurn('noted.');
    } else if (!_isToolContinuation(context) && _freshTurns.isNotEmpty) {
      // The initial lead run (the headless prompt).
      script = _freshTurns.removeAt(0);
    } else {
      // Tool continuations: acknowledge the spawn result, end the turn.
      script = textTurn('ack.');
    }
    final stream = AssistantMessageEventStream();
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [StreamFunction] for the subagent leg: the child run (its
/// assignment carries [childMarker]) does timed work then settles; the
/// wake run (the `<task-result` notice) acknowledges; parent runs
/// replay [parentTurns].
class _SubagentDrainRouter {
  _SubagentDrainRouter({
    required this.childMarker,
    required List<List<AssistantMessageEvent>> parentTurns,
  }) : _parentTurns = List.of(parentTurns);

  final String childMarker;
  final List<List<AssistantMessageEvent>> _parentTurns;
  final contexts = <Context>[];

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
    final stream = AssistantMessageEventStream();
    // The async-result notice QUOTES the child's task text, so the
    // wake branch must win over the child-marker match.
    if (last.contains('<task-result')) {
      for (final event in textTurn('results acknowledged')) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
    if (last.contains(childMarker)) {
      // The child: does its (timed) work, then settles with findings.
      stream.push(StartEvent(partial: testAssistant()));
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          for (final event in textTurn('findings')) {
            stream.push(event);
          }
          stream.end();
        }),
      );
      return stream;
    }
    final script = _parentTurns.isNotEmpty
        ? _parentTurns.removeAt(0)
        : textTurn('ack.');
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// The transcript's user-message text of a run context — the settle
/// notice is a persisted user message, so this is where it shows.
String _userTexts(Context context) => [
  for (final message in context.messages)
    if (message is UserMessage) messageText(message),
].join('\n');

void main() {
  /// The gh-1440 shape: the model starts the "full test suite" as a
  /// background job and ends its turn saying it waits on the result.
  /// Returns the pieces the drain tests steer from outside.
  Future<(AgentCli, FakeCliIO, _RoutingStream, _DrainShell, Future<int>)>
  gh1440Shape() async {
    final io = FakeCliIO();
    final shell = _DrainShell();
    final stream = _RoutingStream(
      leadTurns: [
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'bash',
            arguments: {
              'command': 'dart test --exclude-tags integration',
              'background': true,
            },
          ),
        ]),
        textTurn(
          'Started the full suite in the background. Waiting on it before '
          'writing outputs/response.md.',
        ),
      ],
    );
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work', shell: shell),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
      ),
      io: io,
      streamFunction: stream.call,
    );
    final run = cli.runHeadless('run the full test suite');
    // The lead turn ended; the job is live — the drain is now parked on
    // it.
    await _waitFor(() => shell.jobs.isNotEmpty, reason: 'the job registers');
    return (cli, io, stream, shell, run);
  }

  test(
    'headless drains a live shell job: settle → notice steered → '
    'reaction run executes → exit 0 AFTER the result landed',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (cli, io, stream, shell, run) = await gh1440Shape();
      final job = shell.jobs.single;

      // The job settles mid-drain, exit 0.
      job.finish(0);
      final code = await run;

      expect(code, 0, reason: 'the last completed turn succeeded');
      expect(
        stream.contexts.length,
        3,
        reason:
            'the settle notice must be steered into a fresh reaction '
            'turn BEFORE the process exits (lead prompt + tool round + '
            'reaction run)',
      );
      final reactionText = _userTexts(stream.contexts.last);
      expect(
        reactionText,
        contains(_noticeMarker),
        reason: 'the reaction run carries the settle notice',
      );
      expect(reactionText, contains('exit code 0'));
      expect(job.exitCode, 0);
      expect(
        io.out.toString(),
        contains('⏳ waiting:'),
        reason: 'the drain names what it waits for (#1055 parity)',
      );
      expect(
        io.out.toString(),
        isNot(contains('detached')),
        reason: 'the job was drained, never detached',
      );
      io.close();
    },
  );

  test(
    'an error settle (nonzero exit) steers as an error result the model '
    'can react to',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (cli, io, stream, shell, run) = await gh1440Shape();
      shell.jobs.single.finish(1);
      final code = await run;

      expect(code, 0, reason: 'a failing job is data, not a run failure');
      expect(stream.contexts.length, 3);
      expect(_userTexts(stream.contexts.last), contains('exit code 1'));
      io.close();
    },
  );

  test(
    'a suppressed job (the result already landed in-turn) is not '
    'awaited — no reaction run for it',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (cli, io, stream, shell, run) = await gh1440Shape();
      // The inline-consumer shape: a foreground bash already consumed the
      // job's result — the registry clears the settle notice.
      final entry = cli.shellJobsRegistryForTest.job(shell.jobs.single.id);
      entry!.suppressSettleNotification();
      shell.jobs.single.finish(0);
      final code = await run;

      expect(code, 0);
      expect(
        stream.contexts.length,
        2,
        reason: 'no reaction run: the result was already reported',
      );
      expect(
        io.out.toString(),
        isNot(contains('exit code 0')),
        reason: 'no settle notice is steered for a suppressed job',
      );
      io.close();
    },
  );

  /// The never-settling watch shape: the model starts a watch-loop job
  /// and ends its turn. [drainMs] configures the ceiling under test.
  Future<(FakeCliIO, _RoutingStream, _DrainShell, int)> watchShape(
    HeadlessConfig headless,
  ) async {
    final io = FakeCliIO();
    final shell = _DrainShell();
    final stream = _RoutingStream(
      leadTurns: [
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'bash',
            arguments: {'command': 'gh run watch 42', 'background': true},
          ),
        ]),
        textTurn('watching the CI run in the background'),
      ],
    );
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work', shell: shell),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
        headless: headless,
      ),
      io: io,
      streamFunction: stream.call,
    );
    final code = await cli.runHeadless('watch the CI run');
    return (io, stream, shell, code);
  }

  test(
    'a job that never settles hits the shellJobDrainMs ceiling and the '
    'run detaches with the summary (the documented degradation)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (io, stream, shell, code) = await watchShape(
        const HeadlessConfig(shellJobDrainMs: 60),
      );
      // Well past the 60 ms ceiling: the run gave up on the job.
      expect(shell.jobs.single.isRunning, isTrue);
      expect(code, 0);
      expect(
        io.out.toString(),
        contains('drain ceiling'),
        reason: 'the ceiling exit is observable, not a silent detach',
      );
      expect(io.out.toString(), contains('1 background job detached'));
      expect(
        stream.contexts.length,
        2,
        reason: 'no reaction run — the job never settled',
      );
      io.close();
    },
  );

  test(
    'shellJobDrainMs: 0 disables the drain — a live job detaches '
    'immediately (the pre-gh-1459 behavior as a kill switch)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (io, stream, shell, code) = await watchShape(
        const HeadlessConfig(shellJobDrainMs: 0),
      );
      expect(shell.jobs.single.isRunning, isTrue);
      expect(code, 0);
      expect(stream.contexts.length, 2);
      expect(io.out.toString(), contains('1 background job detached'));
      expect(
        io.out.toString(),
        isNot(contains('⏳ waiting:')),
        reason: 'the disabled drain never enters a wait',
      );
      io.close();
    },
  );

  test(
    'the drain ended by the 10-round cap names the cap (not the '
    'ceiling) — chained background jobs keep every round busy',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final shell = _DrainShell();
      final stream = _ChainedRouter(
        freshTurns: [
          // The initial lead run spawns job 1; every settle reaction
          // spawns the next job (9 chained spawns for 10 rounds).
          toolTurn([
            const ToolCall(
              id: 't1',
              name: 'bash',
              arguments: {'command': 'stage-1', 'background': true},
            ),
          ]),
          for (var k = 2; k <= 10; k++)
            toolTurn([
              ToolCall(
                id: 't$k',
                name: 'bash',
                arguments: {'command': 'stage-$k', 'background': true},
              ),
            ]),
        ],
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(cwd: '/work', shell: shell),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          // A long ceiling and a 1s quiet cadence: the cap, not the
          // wall clock, ends this drain.
          headless: const HeadlessConfig(
            shellJobDrainMs: 30 * 60 * 1000,
            shellJobQuietMs: 1000,
          ),
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.runHeadless('run the staged pipeline');
      await _waitFor(() => shell.jobs.isNotEmpty, reason: 'job 1 registers');
      // Rounds 1..9: finish each job as its successor registers — every
      // round ends with a settle and a fresh live job.
      for (var k = 0; k < 9; k++) {
        shell.jobs[k].finish(0);
        await _waitFor(
          () => shell.jobs.length == k + 2,
          reason: 'job ${k + 2} registers (the chained spawn)',
        );
      }
      // Round 10: job 10 never settles; the drain wakes at the 1s
      // liveness threshold, and the 10-round cap ends the loop while
      // the 30-minute ceiling still has budget.
      final code = await run;

      expect(code, 0);
      expect(shell.jobs.length, 10);
      final out = io.out.toString();
      expect(
        out,
        contains('round cap (10 rounds)'),
        reason: 'the detach line names the real cause (debuggability)',
      );
      expect(out, isNot(contains('drain ceiling')));
      expect(out, contains('1 background job detached'));
      io.close();
    },
  );

  test(
    'shellJobDrainMs: 0 keeps the legacy subagent drain — an in-flight '
    'subagent still drains before exit (the kill switch is '
    'shell-job-scoped)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      const childMarker = 'CHILDTASK investigate the flake';
      final stream = _SubagentDrainRouter(
        childMarker: childMarker,
        parentTurns: [
          toolTurn([
            const ToolCall(
              id: 't1',
              name: 'task',
              arguments: {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {
                    'name': 'fix503',
                    'agent': 'task',
                    'task': 'CHILDTASK investigate the flake',
                  },
                ],
              },
            ),
          ]),
          textTurn('delegated in the background, ending my turn'),
        ],
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(
            cwd: '/work',
            shell: const UnavailableShell(),
          ),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headless: const HeadlessConfig(shellJobDrainMs: 0),
        ),
        io: io,
        streamFunction: stream.call,
      );
      final code = await cli.runHeadless('delegate the investigation');

      expect(code, 0);
      expect(
        stream.contexts.any(
          (context) => _userTexts(context).contains('<task-result'),
        ),
        isTrue,
        reason:
            'the subagent result still re-enters before exit — the '
            '0 kill switch must not detach an in-flight subagent',
      );
      expect(io.out.toString(), contains('results acknowledged'));
      expect(
        io.out.toString(),
        isNot(contains('detaching')),
        reason: 'nothing detached: the subagent drained',
      );
      io.close();
    },
  );
}
