@TestOn('vm')
library;

/// gh-1947 — `schedule_message` recipient resolution on the MAIN agent:
///
/// - The default recipient ("your own mailbox") must be the caller's own
///   mailbox — for the orchestrator that is `<sessionId>/main`, NEVER a
///   task-spawned child's mailbox.
/// - An explicit `to:` must be honored verbatim, and the tool response
///   must name the recipient the record actually carries.
/// - THE LEAK (gh-1947): a background shell job started by a CHILD
///   registers its settle continuation inside the child's subagent zone;
///   when the job settles after the child's run ended, the CLI's settle
///   wake (`_onShellJobSettled` → `_startRun`) starts the MAIN run inside
///   the finished child's zone, and every schedule_message in it
///   misroutes to the child ("keyed off the most recent context
///   participant").
///
/// Driven through the REAL AgentCli (the same wiring the REPL boots:
/// `scheduleSenderMailbox: _childSenderMailbox` over the zone scope).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

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

/// Polls [condition] until it holds or the budget expires.
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

/// A [Shell] whose background jobs settle only when the test releases
/// them — so a job started by a child outlives the child's run.
final class _SettleableJobShell implements Shell, BackgroundShell {
  final jobs = <_SettleableJob>[];

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
        'No foreground shell in this test',
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
    final job = _SettleableJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _SettleableJob implements ShellJob {
  _SettleableJob({
    required this.id,
    required this.command,
    required this.logPath,
  });

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
  int? get exitCode => _stopped ? 0 : null;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => _stopped ? 'finished' : null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  void settle() {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }

  @override
  Future<void> stop() async => settle();
}

/// Routes every model call by its last non-empty message:
/// - child assignments (`Complete the assignment below`) replay
///   [childTurns];
/// - task-result reaction runs replay [taskResultTurns];
/// - shell-settle wake runs replay [shellSettleTurns];
/// - anything else pops [leadTurns], then answers a plain text turn.
class _Router {
  _Router({
    required List<List<AssistantMessageEvent>> leadTurns,
    List<List<AssistantMessageEvent>>? childTurns,
    List<List<AssistantMessageEvent>>? taskResultTurns,
    List<List<AssistantMessageEvent>>? shellSettleTurns,
  }) : _leadTurns = List.of(leadTurns),
       _childTurns = List.of(childTurns ?? const []),
       _taskResultTurns = List.of(taskResultTurns ?? const []),
       _shellSettleTurns = List.of(shellSettleTurns ?? const []);

  final List<List<AssistantMessageEvent>> _leadTurns;
  final List<List<AssistantMessageEvent>> _childTurns;
  final List<List<AssistantMessageEvent>> _taskResultTurns;
  final List<List<AssistantMessageEvent>> _shellSettleTurns;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final text = context.messages.reversed
        .map(messageText)
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    final stream = AssistantMessageEventStream();
    for (final event in _route(text)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }

  List<AssistantMessageEvent> _route(String text) {
    // Order matters: the completion notice embeds the task text too.
    if (text.contains('<task-result')) {
      if (_taskResultTurns.isNotEmpty) return _taskResultTurns.removeAt(0);
    }
    if (text.contains('Background shell job')) {
      if (_shellSettleTurns.isNotEmpty) return _shellSettleTurns.removeAt(0);
    }
    if (text.contains('Complete the assignment below')) {
      if (_childTurns.isNotEmpty) return _childTurns.removeAt(0);
    }
    if (_leadTurns.isNotEmpty) return _leadTurns.removeAt(0);
    return textTurn('done');
  }
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

  /// Every scheduled record currently pending in the test messages root.
  Future<Map<String, Map<String, dynamic>>> scheduledRecords(
    MemoryExecutionEnv env,
  ) async {
    final dir = '/sessions/${encodeSessionCwd('/work')}/messages/_scheduled';
    final records = <String, Map<String, dynamic>>{};
    final entries = (await env.listDir(dir)).valueOrNull ?? const [];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      final name = entry.path.split('/').last;
      final text = (await env.readTextFile('$dir/$name')).valueOrNull;
      if (text == null) continue;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        records[name] = decoded;
      }
    }
    return records;
  }

  test(
    'gh-1947 AC1: a main-agent schedule defaults to MAIN, not the child',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      const childTask = 'child-task: qjs_race race run';
      final router = _Router(
        leadTurns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'task',
              arguments: const {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {'name': 'qjs_race', 'agent': 'task', 'task': childTask},
                ],
              },
            ),
          ]),
          textTurn('spawned qjs_race in the background'),
        ],
        childTurns: [
          toolTurn([
            ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: const {
                'command': 'watch-release.sh',
                'background': true,
              },
            ),
          ]),
          textTurn('child done'),
        ],
        taskResultTurns: [textTurn('noted the result, standing by')],
        shellSettleTurns: [
          toolTurn([
            ToolCall(
              id: 's1',
              name: 'schedule_message',
              arguments: const {'text': 'check the release', 'delay': '10m'},
            ),
          ]),
          textTurn('scheduled the follow-up'),
        ],
      );
      final shell = _SettleableJobShell();
      final (cli, run) = await bootedCli(router.call, shell: shell);

      io.sendLine('spawn qjs_race');
      await waitForIt(
        () =>
            cli.taskConfig.jobManager.job('qjs_race')?.status ==
            TaskJobStatus.completed,
        reason: 'the child completes',
      );
      await waitForIt(
        () => !cli.isBusy,
        reason: 'the task-result reaction settles',
      );
      // The child started a background shell job inside ITS run; the job
      // is still running. Settle it now — the CLI's settle wake starts a
      // MAIN run whose scripted reaction schedules a timer.
      expect(shell.jobs, isNotEmpty, reason: 'the child started a job');
      for (final job in shell.jobs) {
        job.settle();
      }
      await waitForIt(
        () => router.contexts.any(
          (context) =>
              messageText(context.messages.last).contains('scheduled '),
        ),
        reason: 'the settle wake executed schedule_message',
        seconds: 30,
      );
      await waitForIt(() => !cli.isBusy, reason: 'the wake run settles');

      final env = cli.config.env as MemoryExecutionEnv;
      final records = await scheduledRecords(env);
      expect(records, hasLength(1));
      final to = records.values.single['to'] as String;
      expect(
        to.endsWith('/main'),
        isTrue,
        reason:
            'gh-1947: the default recipient must be the caller’s own '
            'mailbox (<session>/main) — got $to',
      );
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'gh-1947 AC2: an explicit to: is honored and the response names the '
    'recorded recipient',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      const childTask = 'child-task: qjs_race race run';
      final router = _Router(
        leadTurns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'task',
              arguments: const {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {'name': 'qjs_race', 'agent': 'task', 'task': childTask},
                ],
              },
            ),
          ]),
          textTurn('spawned qjs_race in the background'),
        ],
        taskResultTurns: [
          toolTurn([
            ToolCall(
              id: 't2',
              name: 'schedule_message',
              arguments: const {
                'text': 'check the release',
                'delay': '10m',
                'to': 'explicit-session/main',
              },
            ),
          ]),
          textTurn('scheduled the follow-up'),
        ],
      );
      final (cli, run) = await bootedCli(router.call);

      io.sendLine('spawn qjs_race');
      await waitForIt(
        () => router.contexts.any(
          (context) =>
              messageText(context.messages.last).contains('scheduled '),
        ),
        reason: 'the reaction run executed schedule_message',
        seconds: 30,
      );
      await waitForIt(() => !cli.isBusy, reason: 'the reaction settles');

      final env = cli.config.env as MemoryExecutionEnv;
      final records = await scheduledRecords(env);
      expect(records, hasLength(1));
      expect(records.values.single['to'], 'explicit-session/main');
      // The tool result (in the transcript) names the RECORDED recipient —
      // never a zone participant (the gh-1947 response printed the
      // sender's mailbox even when the explicit to: was honored).
      final scheduledLine = router.contexts
          .map((c) => messageText(c.messages.last))
          .firstWhere((t) => t.contains('scheduled '));
      expect(scheduledLine, contains('in explicit-session/main'));
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'gh-970 preserved: a live child scheduling inside its own run keeps '
    'the child mailbox (the in-flight guard only rejects STALE scopes)',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      const childTask = 'child-task: monitor pass';
      final router = _Router(
        leadTurns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'task',
              arguments: const {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {'name': 'monitor', 'agent': 'task', 'task': childTask},
                ],
              },
            ),
          ]),
          textTurn('spawned the monitor'),
        ],
        // The child schedules its OWN next pass mid-run (gh-970).
        childTurns: [
          toolTurn([
            ToolCall(
              id: 'c1',
              name: 'schedule_message',
              arguments: const {'text': 'next pass', 'delay': '15m'},
            ),
          ]),
          textTurn('child done'),
        ],
        taskResultTurns: [textTurn('noted')],
      );
      final (cli, run) = await bootedCli(router.call);

      io.sendLine('spawn the monitor');
      await waitForIt(
        () => router.contexts.any(
          (context) =>
              messageText(context.messages.last).contains('scheduled '),
        ),
        reason: 'the child executed schedule_message',
        seconds: 30,
      );
      await waitForIt(
        () =>
            cli.taskConfig.jobManager.job('monitor')?.status ==
            TaskJobStatus.completed,
        reason: 'the child completes',
      );

      final env = cli.config.env as MemoryExecutionEnv;
      final records = await scheduledRecords(env);
      expect(records, hasLength(1));
      final to = records.values.single['to'] as String;
      expect(
        to.endsWith('/monitor'),
        isTrue,
        reason:
            'gh-970: a LIVE child’s self-reminder must still default to '
            'its own mailbox — got $to',
      );
      io.sendLine('/exit');
      await run;
    },
  );
}
