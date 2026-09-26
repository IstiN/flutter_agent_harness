@TestOn('vm')
library;

/// Issue #958: background subagents finish, but the parent orchestrator
/// sits idle until the user pings — the async-result injection never wakes
/// it. The omp contract (docs + tool result text): a settled `task` job
/// re-enters the parent conversation as an async-result system-notice
/// (`<task-result id=...>` + `agent://<id>` pointer).
///
/// - AC-A (idle parent): the spawn turn ends while two background children
///   still run; when they settle, the parent must START a wake run whose
///   prompt carries the async-result notices — no user ping involved.
/// - AC-B (mid-turn parent): a background child settles while the parent
///   is parked mid-turn on a long tool call; the async-result must be
///   steered and delivered at the next step boundary.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The text carried by a transcript message.
String _messageText(Object message) {
  final content = switch (message) {
    UserMessage() => message.content,
    AssistantMessage() => message.content,
    ToolResultMessage() => message.content,
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

/// The last user message's text, or '' — test-side transcript probe.
String lastUserText(Context context) {
  for (final message in context.messages.reversed) {
    if (message is UserMessage) return _messageText(message);
  }
  return '';
}

/// A [StreamFunction] routing every run by its last user message:
/// - a CHILD run (assignment contains its task marker) replays a delayed
///   text turn — the background job doing real (timed) work, then settling;
/// - a WAKE run (the async-result notice is its payload) replays
///   [wakeTurns];
/// - any other parent run (the spawn turn) replays [spawnTurns] in order.
/// Every context is recorded — assertions read the transcript.
class _CompletionRouter {
  _CompletionRouter({
    required this.childMarkers,
    required List<List<AssistantMessageEvent>> spawnTurns,
    List<List<AssistantMessageEvent>>? wakeTurns,
  }) : _spawnTurns = List.of(spawnTurns),
       _wakeTurns = List.of(wakeTurns ?? const []);

  final List<String> childMarkers;
  final List<List<AssistantMessageEvent>> _spawnTurns;
  final List<List<AssistantMessageEvent>> _wakeTurns;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final lastUser = lastUserText(context);
    final stream = AssistantMessageEventStream();
    String? childMarker;
    for (final marker in childMarkers) {
      if (lastUser.contains(marker)) {
        childMarker = marker;
        break;
      }
    }
    // The async-result notice QUOTES the child's task text, so the wake
    // branch must win over the child-marker match.
    if (lastUser.contains('<task-result')) {
      final events = _wakeTurns.isNotEmpty
          ? _wakeTurns.removeAt(0)
          : textTurn('results acknowledged');
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
    if (childMarker != null) {
      // The child: does its (timed) work, then settles with its findings.
      stream.push(StartEvent(partial: testAssistant()));
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          for (final event in textTurn('findings for $childMarker')) {
            stream.push(event);
          }
          stream.end();
        }),
      );
      return stream;
    }
    final events = _spawnTurns.isNotEmpty
        ? _spawnTurns.removeAt(0)
        : textTurn('noted.');
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [Shell] whose `exec` parks on a gate — the parent mid-turn wedge.
class _GatedShell implements Shell {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  bool get isPending => !_gate.isCompleted;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

Future<void> _waitForIt(
  bool Function() condition, {
  String reason = 'condition',
  int seconds = 20,
}) async {
  for (var i = 0; i < seconds * 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: $reason');
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
    await _waitForIt(
      () => io.out.toString().contains('/tasks'),
      reason: 'REPL is up',
    );
    return (cli, run);
  }

  ToolCall backgroundSpawn(List<String> names) => ToolCall(
    id: 't1',
    name: 'task',
    arguments: {
      'context': 'ctx',
      'background': true,
      'tasks': [
        for (final name in names)
          {'name': name, 'agent': 'task', 'task': 'TASKMARK-$name do work'},
      ],
    },
  );

  test(
    'AC-A: idle parent wakes when a background child settles — async-result '
    're-enters as a fresh run (issue #958 repro)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _CompletionRouter(
        childMarkers: const ['TASKMARK-alpha', 'TASKMARK-beta'],
        spawnTurns: [
          toolTurn([backgroundSpawn(['alpha', 'beta'])]),
          textTurn('spawned both in the background, ending my turn'),
        ],
        wakeTurns: [textTurn('results acknowledged')],
      );
      final (cli, run) = await bootedCli(stream.call);

      io.sendLine('spawn both children');
      await _waitForIt(
        () =>
            cli.taskConfig.jobManager.job('alpha') != null &&
            cli.taskConfig.jobManager.job('beta') != null,
        reason: 'both background children register',
      );
      // The spawn turn ends while the children still run — the repro's
      // idle state.
      await _waitForIt(() => !cli.isBusy, reason: 'the spawn turn settles');
      expect(cli.isBusy, isFalse);

      // NO user ping. The children settle on their own; each settlement
      // must re-enter the parent: the first as a fresh wake run, the
      // second as steering delivered within it.
      await _waitForIt(
        () => stream.contexts.any(
          (context) =>
              lastUserText(context).contains('<task-result') &&
              lastUserText(context).contains('alpha'),
        ),
        reason: 'the settled child re-enters as an async-result run',
        seconds: 15,
      );
      final wake = stream.contexts.lastWhere(
        (context) =>
            lastUserText(context).contains('<task-result') &&
            lastUserText(context).contains('alpha'),
      );
      final wakeTexts = [
        for (final message in wake.messages) _messageText(message),
      ].join('\n');
      expect(
        wakeTexts,
        contains('finished with status: completed'),
        reason: 'the notice names the settlement',
      );
      expect(
        lastUserText(wake),
        contains('<system-notice>'),
        reason: 'the wake prompt IS the async-result notice',
      );
      await _waitForIt(
        () => io.out.toString().contains('results acknowledged'),
        reason: 'the wake run reaches the model and answers',
      );
      // The second child's result must reach the parent too — steered into
      // the wake run or a follow-up wake run, never dropped.
      await _waitForIt(
        () => stream.contexts.any(
          (context) =>
              lastUserText(context).contains('<task-result') &&
              lastUserText(context).contains('beta'),
        ),
        reason: 'the second child re-enters as well',
        seconds: 15,
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC-B: mid-turn parent receives the settled child as steering at the '
    'next step boundary (issue #958, busy path)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final gate = _GatedShell();
      final stream = _CompletionRouter(
        childMarkers: const ['TASKMARK-gamma'],
        spawnTurns: [
          toolTurn([backgroundSpawn(['gamma'])]),
          // The parent stays busy on a long tool call while the child
          // settles underneath it.
          toolTurn([
            ToolCall(
              id: 't2',
              name: 'bash',
              arguments: const {'command': 'long-running step'},
            ),
          ]),
          textTurn('turn complete'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call, shell: gate);

      io.sendLine('spawn gamma then run the long step');
      await _waitForIt(
        () => cli.taskConfig.jobManager.job('gamma') != null,
        reason: 'the background child registers',
      );
      await _waitForIt(
        () => gate.isPending,
        reason: 'the parent is parked mid-turn on the long tool call',
      );
      expect(cli.isBusy, isTrue);

      // The child settles WHILE the parent is mid-turn: the async-result
      // must steer, and the boundary after the tool call must deliver it.
      await _waitForIt(
        () =>
            cli.taskConfig.jobManager.job('gamma')!.status ==
            TaskJobStatus.completed,
        reason: 'the child settles under the busy parent',
        seconds: 15,
      );
      gate.release();
      await _waitForIt(
        () => stream.contexts.any(
          (context) => lastUserText(context).contains('<task-result'),
        ),
        reason: 'the async-result is delivered at the next step boundary',
        seconds: 15,
      );
      await _waitForIt(() => !cli.isBusy, reason: 'the turn settles');

      io.sendLine('/exit');
      await run;
    },
  );
}
