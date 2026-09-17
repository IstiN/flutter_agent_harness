@TestOn('vm')
library;

/// Issue #520 e2e: the incident shape — a main agent with a running child
/// and a never-returning watcher, with owner steering in flight.
///
/// - AC1: after a background spawn the main agent's turn ENDS (idle,
///   inbox-open) while the child still runs; owner mail arriving during
///   the idle wait is consumed within the inbox-poll budget (the 2s
///   watcher tick) and starts a turn.
/// - AC2: the owner's request is routed to the child via `task_send` (a
///   real record in the child's fabric inbox) and the main agent reports
///   back («передал fix503»).
/// - AC1 wedge variant: a never-returning foreground bash + mid-run
///   steering — the soft-yield fires, the command moves to a background
///   job (NOT killed), the steered message is delivered at the step
///   boundary, and the turn continues to a normal settle.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The text carried by a transcript message or a fabric mail record.
String messageText(Object message) {
  final content = switch (message) {
    UserMessage() => message.content,
    AssistantMessage() => message.content,
    ToolResultMessage() => message.content,
    AgentMessage() => message.text,
    _ => '',
  };
  return content is String
      ? content
      : content is List<ContentBlock>
      ? [
          for (final block in content)
            if (block is TextContent) block.text,
        ].join('\n')
      : '';
}

/// A [StreamFunction] routing every run by its last user message:
/// - a CHILD run (the assignment wraps [childTask]) hangs until its
///   cancel token fires — the live background job being awaited;
/// - the WAKE run (the owner mail is its payload) replays [wakeTurns];
/// - any other parent run (spawn prompt, settle notices, stray steering)
///   replays [leadTurns] then answers 'noted.' so nothing wedges.
/// Every context is recorded — assertions read the transcript with eyes.
class _RoutingStream {
  _RoutingStream({
    required this.childTask,
    required this.mailMarker,
    required List<List<AssistantMessageEvent>> leadTurns,
    List<List<AssistantMessageEvent>>? wakeTurns,
  }) : _leadTurns = List.of(leadTurns),
       _wakeTurns = List.of(wakeTurns ?? const []);

  final String childTask;
  final String mailMarker;
  final List<List<AssistantMessageEvent>> _leadTurns;
  final List<List<AssistantMessageEvent>> _wakeTurns;
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
    final lastUser = _lastUserText(context);
    final stream = AssistantMessageEventStream();
    if (childTask.isNotEmpty && lastUser.contains(childTask)) {
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
    final script = lastUser.contains(mailMarker) ? _wakeTurns : _leadTurns;
    final events = script.isNotEmpty ? script.removeAt(0) : textTurn('noted.');
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [Shell] + [BackgroundShell] whose detached jobs NEVER settle until
/// stopped — the wedged watcher (`flutter test` that never returns). The
/// foreground exec stays unavailable so boot probes stay out of the way.
class _HangShell implements Shell, BackgroundShell {
  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
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
    return Ok(_HangJob(id: id, command: command, logPath: logPath));
  }
}

final class _HangJob implements ShellJob {
  _HangJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

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
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }
}

Future<void> waitForIt(
  bool Function() condition, {
  String? reason,
  int seconds = 20,
}) async {
  for (var i = 0; i < seconds * 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  Future<(AgentCli, Future<void>)> bootedCli(
    StreamFunction stream, {
    Shell? shell,
  }) async {
    final cli = AgentCli(
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
    final run = cli.run();
    io.sendLine('/help');
    await waitForIt(
      () => io.out.toString().contains('/tasks'),
      reason: 'REPL is up',
    );
    return (cli, run);
  }

  test(
    'AC1+AC2: background spawn ends the turn; owner mail wakes and is '
    'routed to the child via task_send with a report',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      const childTask = 'child-task: fix503 test run';
      const routeText = 'owner просит собрать отчёт по fix503';
      const mailText = 'скажи fix503 чтобы собрал отчёт';
      final stream = _RoutingStream(
        childTask: childTask,
        mailMarker: mailText,
        leadTurns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'task',
              arguments: const {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {'name': 'fix503', 'agent': 'task', 'task': childTask},
                ],
              },
            ),
          ]),
          textTurn('spawned fix503 in the background, ending my turn'),
        ],
        wakeTurns: [
          toolTurn([
            ToolCall(
              id: 't2',
              name: 'task_send',
              arguments: {'id': 'fix503', 'message': routeText},
            ),
          ]),
          textTurn('передал fix503'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call);

      // The spawn: the model's own background task call through the real
      // tool surface.
      io.sendLine('spawn the fix503 child');
      await waitForIt(
        () => cli.taskConfig.jobManager.job('fix503') != null,
        reason: 'the background child registers',
      );
      // AC1: the main agent's turn ENDS while the child still runs —
      // waiting is an idle, inbox-open state, never a blocked turn.
      await waitForIt(() => !cli.isBusy, reason: 'the spawn turn settles');
      expect(cli.isBusy, isFalse, reason: 'idle while the child works');
      expect(
        cli.taskConfig.jobManager.job('fix503')!.status,
        TaskJobStatus.running,
      );
      // AC3: the waiting row names the awaited child while idle.
      final snap = await cli.waitersSnapshotForTest();
      expect(snap.jobs.single, contains('fix503'));

      // AC1: owner mail arrives during the idle wait...
      await cli.subagentManager.enqueueMessage(
        'main',
        SubagentMessage(
          fromId: 'owner-app',
          text: mailText,
          sentAt: DateTime.now().toUtc().toIso8601String(),
          isUserInput: true,
        ),
      );
      // ...and is consumed within the inbox-poll budget: the watcher wake
      // starts a run whose model call carries the attributed mail.
      await waitForIt(
        () => stream.contexts.any(
          (context) => context.messages.any(
            (message) =>
                messageText(message).contains('[from ') &&
                messageText(message).contains(mailText),
          ),
        ),
        reason: 'the owner mail is drained into a wake run',
      );
      final wakeContext = stream.contexts.lastWhere(
        (context) => context.messages.any(
          (message) =>
              messageText(message).contains('[from ') &&
              messageText(message).contains(mailText),
        ),
      );
      final mailMessage = wakeContext.messages.firstWhere(
        (message) =>
            message is UserMessage &&
            messageText(message).contains('[from ') &&
            messageText(message).contains(mailText),
      );
      expect(
        messageText(mailMessage),
        startsWith('[from '),
        reason:
            'the owner mail is attributed as the user\'s own words '
            '(user-kind survives the fabric)',
      );

      // AC2: the routing is real — a task_send record lands in the
      // child's fabric inbox, and the main agent reports back.
      await waitForIt(
        () => io.out.toString().contains('передал fix503'),
        reason: 'the main agent reports the routing back to the owner',
      );
      final pending = await cli.subagentManager.pendingInbox('fix503');
      expect(pending, isNotEmpty, reason: 'the task_send record exists');
      expect(messageText(pending.first), contains(routeText));
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC1 wedge: steering during a never-returning foreground bash moves '
    'it to background and the turn continues',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      final stream = _RoutingStream(
        childTask: '',
        mailMarker: '@@never@@',
        leadTurns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'bash',
              arguments: const {'command': 'flutter test --tag never-returns'},
            ),
          ]),
          textTurn('test still running in background; I will report'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call, shell: _HangShell());

      io.sendLine('run the wedged test suite');
      await waitForIt(() => stream.contexts.isNotEmpty && cli.isBusy);
      // The wedge: the job never settles, so the tool call would park the
      // turn forever. Steering mid-run must soft-yield it.
      io.sendLine('how is it going?');
      await waitForIt(
        () => stream.contexts.length >= 2,
        reason: 'the yield delivered the steered message at the boundary',
      );
      await waitForIt(() => !cli.isBusy, reason: 'the turn continued');
      final turnContext = stream.contexts[1];
      final texts = [
        for (final message in turnContext.messages) messageText(message),
      ];
      expect(
        texts.where((t) => t.contains('moved to background job')),
        isNotEmpty,
        reason: 'the wedged command became a background job, not a corpse',
      );
      expect(
        texts.where((t) => t.contains('how is it going?')),
        isNotEmpty,
        reason: 'the steered message was delivered at the boundary',
      );
      // The command was NOT killed: the job still runs (a waiter).
      final snap = await cli.waitersSnapshotForTest();
      expect(
        snap.jobs.where((j) => j.contains('flutter test')),
        isNotEmpty,
        reason: 'the moved job keeps running',
      );
      expect(
        io.out.toString(),
        isNot(contains('aborted')),
        reason: 'the run settled normally — no watchdog kill',
      );

      io.sendLine('/exit');
      await run;
    },
  );
}
