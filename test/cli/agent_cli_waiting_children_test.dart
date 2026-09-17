/// «waiting: fix503 (test run)» instead of silence.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [StreamFunction] that routes by run:
/// - a CHILD run whose last user message is exactly [childTask] hangs
///   until its cancel token fires (then reports aborted) — the live
///   background job being awaited;
/// - any PARENT run (settle notices, follow-ups) answers 'noted.' so
///   unscripted steering never wedges.
class _RoutingStreamFunction {
  _RoutingStreamFunction({required this.childTask});

  final String childTask;

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
    if (_lastUserText(context) == childTask) {
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
    for (final event in textTurn('noted.')) {
      stream.push(event);
    }
    stream.end();
    return stream;
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

  Future<(AgentCli, Future<void>)> bootedCli(StreamFunction stream) async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work', shell: const UnavailableShell()),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
      ),
      io: io,
      streamFunction: stream,
    );
    final run = cli.run();
    io.sendLine('/help');
    await _waitFor(
      () => io.out.toString().contains('/tasks'),
      reason: 'REPL is up',
    );
    return (cli, run);
  }

  test(
    'a running background child is a waiter with its live status '
    '(issue #520 AC3)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const childTask = 'child-task: the fix503 test run';
      final (cli, run) = await bootedCli(
        _RoutingStreamFunction(childTask: childTask).call,
      );
      await taskTool(config: cli.taskConfig).execute(
        {
          'context': 'ctx',
          'background': true,
          'tasks': [
            {'name': 'fix503', 'task': childTask},
          ],
        },
        null,
        null,
      );
      await _waitFor(
        () => cli.taskConfig.jobManager.job('fix503') != null,
        reason: 'the background child registers',
      );

      final snap = await cli.waitersSnapshotForTest();
      expect(snap.jobs, hasLength(1), reason: 'the awaited child is a waiter');
      expect(snap.jobs.single, contains('fix503'), reason: 'child id named');
      expect(
        snap.jobs.single,
        contains('test run'),
        reason: 'the task preview names the work',
      );
      expect(
        snap.jobs.single,
        contains('running'),
        reason: 'live status, not silence',
      );
      expect(snap.isEmpty, isFalse);

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a settled child drops out of the waiting snapshot',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const childTask = 'child-task: hang until cancelled';
      final (cli, run) = await bootedCli(
        _RoutingStreamFunction(childTask: childTask).call,
      );
      await taskTool(config: cli.taskConfig).execute(
        {
          'context': 'ctx',
          'background': true,
          'tasks': [
            {'name': 'fix503', 'task': childTask},
          ],
        },
        null,
        null,
      );
      await _waitFor(
        () => cli.taskConfig.jobManager.job('fix503') != null,
        reason: 'the background child registers',
      );

      final job = cli.taskConfig.jobManager.job('fix503')!;
      job.cancel();
      await job.settled;
      final snap = await cli.waitersSnapshotForTest();
      expect(snap.jobs, isEmpty, reason: 'a settled child is not awaited');
      expect(snap.isEmpty, isTrue);

      io.sendLine('/exit');
      await run;
    },
  );
}
