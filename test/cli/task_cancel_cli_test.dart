@TestOn('vm')
library;

/// `/tasks cancel` through the REAL [AgentCli] loop (issue #332): a
/// retained registry row whose runner died with a previous host process
/// (interrupted before start) is tombstoned as aborted instead of lying
/// 'unknown job'. Cancels of live task jobs and background shell jobs, and
/// the honest 'unknown job' fallbacks, ride the same command — this suite
/// covers every branch of ApprovalCommands._cancelTaskJobById.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [StreamFunction] that routes by run:
/// - a CHILD run whose last user message is exactly [childTask] hangs
///   until its cancel token fires (then reports aborted) — the live
///   background job to cancel;
/// - any PARENT run (settle notices, follow-ups) replays [leadTurns] and
///   then answers 'noted.' forever, so unscripted steering never wedges.
class _RoutingStreamFunction {
  _RoutingStreamFunction({
    this.childTask,
    List<List<AssistantMessageEvent>>? leadTurns,
  }) : _leadTurns = List.of(leadTurns ?? const []);

  final String? childTask;
  final List<List<AssistantMessageEvent>> _leadTurns;

  String _lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) {
        final content = message.content;
        return content is String
            ? content
            : content is List<ContentBlock>
            ? [
                for (final block in content)
                  if (block is TextContent) block.text,
              ].join('\n')
            : '';
      }
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    if (childTask != null && _lastUserText(context) == childTask) {
      // The child: alive until cancelled, then aborted.
      stream.push(StartEvent(partial: testAssistant()));
      cancelToken?.onCancel.then((_) {
        stream
          ..push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: testAssistant(
                stopReason: StopReason.aborted,
                errorMessage: 'Operation aborted',
              ),
            ),
          )
          ..end();
      });
      return stream;
    }
    final events = _leadTurns.isNotEmpty
        ? _leadTurns.removeAt(0)
        : textTurn('noted.');
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [Shell] + [BackgroundShell] whose detached jobs stay RUNNING until
/// [ShellJob.stop] is called (exit code 9) — the live shell job to cancel.
class _BgShell implements Shell, BackgroundShell {
  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    // Foreground exec behaves like an unavailable shell; only detached
    // jobs work (keeps boot probes out of the way).
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
    return Ok(_CtrlJob(id: id, command: command, logPath: logPath));
  }
}

final class _CtrlJob implements ShellJob {
  _CtrlJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;

  var _stopped = false;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_stopped;

  @override
  int? get exitCode => _stopped ? 9 : null;

  @override
  Future<void> get settled => _settled.future;

  @override
  String? get stopReason => _stopped ? 'cancelled' : null;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 6000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  AgentCli buildCli(StreamFunction stream, {Shell? shell}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: shell ?? const UnavailableShell(),
        ),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
      ),
      io: io,
      streamFunction: stream,
    );
  }

  /// Boots the CLI and waits until the REPL answers a slash command.
  /// Returns the cli and its `run()` future — await the future after the
  /// final `/exit` (an early unawaited exit races the assertions).
  Future<(AgentCli, Future<void>)> bootedCli(
    StreamFunction stream, {
    Shell? shell,
  }) async {
    final cli = buildCli(stream, shell: shell);
    final run = cli.run();
    io.sendLine('/help');
    await _waitFor(
      () => io.out.toString().contains('/tasks'),
      reason: 'REPL is up and lists /tasks',
    );
    return (cli, run);
  }

  group('/tasks cancel (ApprovalCommands._cancelTaskJobById)', () {
    test(
      'usage without an id; unknown ids stay honestly unknown',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final (cli, run) = await bootedCli(_RoutingStreamFunction().call);
        io.sendLine('/tasks cancel');
        await _waitFor(
          () => io.out.toString().contains('usage: /tasks cancel <id>'),
          reason: 'missing-argument usage line',
        );
        io.sendLine('/tasks cancel nope');
        await _waitFor(
          () => io.out.toString().contains('unknown job: nope'),
          reason: 'no job, no shell job, no registry row',
        );
        io.sendLine('/exit');
        await run;
      },
    );

    test(
      'an orphaned running registry row is tombstoned as aborted '
      '(issue #332)',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final (cli, run) = await bootedCli(_RoutingStreamFunction().call);
        // A child interrupted before its first request: the registry row
        // says running, but the runner died with the previous host
        // process — no live task job, no shell job.
        final manager = cli.subagentManager;
        await manager.register(
          id: 'Task-18',
          name: 'Task-18',
          agentType: 'task',
          task: 'never ran',
        );
        await manager.update('Task-18', status: SubagentStatus.running);
        expect(manager['Task-18']!.isTerminal, isFalse);

        io.sendLine('/tasks cancel Task-18');
        await _waitFor(
          () => io.out.toString().contains('tombstoned Task-18 as aborted'),
          reason: 'the tombstone fallback fires',
        );

        // The registry row is terminal now — no more zombie 'running'.
        final handle = manager['Task-18']!;
        expect(handle.isTerminal, isTrue);
        expect(handle.status, SubagentStatus.aborted);
        expect(handle.error, contains('no live runner'));

        // A repeat cancel of the settled row falls through to the honest
        // 'unknown job' (nothing left to clear).
        io.sendLine('/tasks cancel Task-18');
        await _waitFor(
          () => io.out.toString().contains('unknown job: Task-18'),
          reason: 'terminal row reports unknown, not tombstone again',
        );
        io.sendLine('/exit');
        await run;
      },
    );

    test(
      'an already-terminal registry row is not tombstoned again',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final (cli, run) = await bootedCli(_RoutingStreamFunction().call);
        final manager = cli.subagentManager;
        await manager.register(
          id: 'Task-19',
          name: 'Task-19',
          agentType: 'task',
          task: 'failed earlier',
        );
        await manager.update('Task-19', status: SubagentStatus.failed);
        expect(manager['Task-19']!.isTerminal, isTrue);

        io.sendLine('/tasks cancel Task-19');
        await _waitFor(
          () => io.out.toString().contains('unknown job: Task-19'),
          reason: 'terminal rows keep their settled state',
        );
        expect(manager['Task-19']!.status, SubagentStatus.failed);
        io.sendLine('/exit');
        await run;
      },
    );

    test(
      'a live background task job is cancelled and settles aborted',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        const childTask = 'child-task: hang until cancelled';
        final (cli, run) = await bootedCli(
          _RoutingStreamFunction(childTask: childTask).call,
        );
        // Spawn the child through the session's REAL task wiring (same
        // job manager and registry the /tasks command consults).
        await taskTool(config: cli.taskConfig).execute(
          {
            'context': 'ctx',
            'background': true,
            'tasks': [
              {'name': 'Scout', 'task': childTask},
            ],
          },
          null,
          null,
        );
        await _waitFor(
          () => cli.taskConfig.jobManager.job('Scout') != null,
          reason: 'the background job registers',
        );

        io.sendLine('/tasks cancel Scout');
        await _waitFor(
          () => io.out.toString().contains('cancelled Scout'),
          reason: 'the live-job cancel path',
        );
        final job = cli.taskConfig.jobManager.job('Scout')!;
        await job.settled;
        expect(job.status, TaskJobStatus.aborted);
        // The settle notice steers the idle parent into one 'noted.' run.
        await _waitFor(
          () => io.out.toString().contains('noted.'),
          reason: 'the async-result notice is acknowledged',
        );
        io.sendLine('/exit');
        await run;
      },
    );

    test(
      'a running background shell job is stopped; a finished one reports '
      'its exit code',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final (cli, run) = await bootedCli(
          _RoutingStreamFunction(
            leadTurns: [
              toolTurn([
                const ToolCall(
                  id: 't1',
                  name: 'bash',
                  arguments: {'command': 'sleep 30', 'background': true},
                ),
              ]),
              textTurn('job started'),
            ],
          ).call,
          shell: _BgShell(),
        );
        io.sendLine('start one');
        final running = RegExp(r'bash (sh-1-\S+) · running');
        await _waitFor(
          () => running.hasMatch(io.out.toString()),
          reason: 'the background shell job start block',
        );
        final id = running.firstMatch(io.out.toString())!.group(1)!;

        io.sendLine('/tasks cancel $id');
        await _waitFor(
          () => io.out.toString().contains('stopped $id'),
          reason: 'the shell-job stop path',
        );
        // The settle notice steers the idle parent into one 'noted.' run.
        await _waitFor(
          () => io.out.toString().contains('noted.'),
          reason: 'the shell-job settle notice is acknowledged',
        );

        // Now finished: cancel reports the exit code instead of stopping.
        io.sendLine('/tasks cancel $id');
        await _waitFor(
          () => io.out.toString().contains(
            '$id already finished (exit code '
            '9)',
          ),
          reason: 'the already-finished shell-job path',
        );
        io.sendLine('/exit');
        await run;
      },
    );
  });
}
