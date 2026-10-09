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
}
