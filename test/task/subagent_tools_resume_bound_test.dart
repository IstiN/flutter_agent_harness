import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #1923 AC2: `task_resume` must never hang the parent on a wedged
/// child — the resume wait is capped (the same bound `task_send` already
/// applies, issue #647). Past the cap the tool reports a background
/// receipt: the resumed run keeps going and is never restarted; a late
/// failure is recorded on the child by resumeChild itself, which returns
/// the child to failed-and-resumable.
void main() {
  late SubagentManager manager;

  /// The host resume runner, swapped per test.
  Future<void> Function(String id, String message) resumeChild =
      (id, message) async {};

  setUp(() {
    manager = SubagentManager(parentSessionId: 'parent');
    resumeChild = (id, message) async {};
  });

  /// Registers a failed child so task_resume takes the resume path.
  Future<void> failedChild(String id) async {
    final handle = await manager.register(
      id: id,
      name: id,
      agentType: 'task',
      task: 'long work',
    );
    handle.status = SubagentStatus.failed;
  }

  /// The result text of a task_resume call with a fast cap.
  Future<String> resume(String id) async {
    final tools = subagentMonitoringTools(
      manager: manager,
      resumeChild: resumeChild,
      taskSendWaitCap: const Duration(milliseconds: 50),
    );
    final tool = tools.firstWhere((tool) => tool.name == 'task_resume');
    final result = await tool.execute(
      {'id': id, 'message': 'continue'},
      null,
      null,
    );
    return [
      for (final block in result.content)
        if (block is TextContent) block.text,
    ].join();
  }

  test(
    'AC: task_resume on a wedged child returns the background receipt '
    'within the cap',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await failedChild('wedged');
      // The child never finishes its session boot: the resume hangs.
      resumeChild = (id, message) => Completer<void>().future;

      final stopwatch = Stopwatch()..start();
      final text = await resume('wedged');
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason:
            'the receipt returns within the 50ms cap + slack, not '
            'after the hang',
      );
      expect(text, contains('not responding within the wait cap'));
      expect(text, contains('background'));
      expect(text, contains('NOT be restarted'));
      expect(text, contains('task_status'));
      // The success receipt must not leak over the timeout one.
      expect(text, isNot(contains('resumed "wedged"')));
    },
  );

  test(
    'a resume that throws synchronously still reports the failure text',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await failedChild('doomed');
      resumeChild = (id, message) => throw StateError('provider quota');

      final text = await resume('doomed');

      expect(text, contains('resume of "doomed" failed'));
      expect(text, contains('provider quota'));
      expect(text, contains('stays failed'));
    },
  );

  test(
    'a resume whose future errors still reports the failure text',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await failedChild('flaky');
      resumeChild = (id, message) async => throw StateError('boot crashed');

      final text = await resume('flaky');

      expect(text, contains('resume of "flaky" failed'));
      expect(text, contains('boot crashed'));
      expect(text, contains('stays failed'));
    },
  );

  test(
    'a resume that completes within the cap still returns the success '
    'receipt',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await failedChild('healthy');

      final text = await resume('healthy');

      expect(text, contains('resumed "healthy"'));
      expect(text, contains('child failed'));
    },
  );
}
