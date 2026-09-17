import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #488 AC3: `task_send` must never hang the parent on a wedged
/// child. The resume wait is capped; past the cap the tool reports the
/// message queued while the child keeps waking in the background — the
/// message runs when the child does.
void main() {
  late SubagentManager manager;

  /// The host resume runner, swapped per test.
  Future<void> Function(String id, String message) resumeChild =
      (id, message) async {};

  setUp(() {
    manager = SubagentManager(parentSessionId: 'parent');
    resumeChild = (id, message) async {};
  });

  /// Registers a resumable (completed) child so task_send takes the
  /// resume path.
  Future<void> completedChild(String id) async {
    final handle = await manager.register(
      id: id,
      name: id,
      agentType: 'task',
      task: 'long work',
    );
    handle.status = SubagentStatus.completed;
  }

  /// The result text of a task_send call with a fast cap.
  Future<String> sendTo(
    String id, {
    Duration cap = const Duration(milliseconds: 80),
  }) async {
    final tools = subagentMonitoringTools(
      manager: manager,
      resumeChild: resumeChild,
      taskSendWaitCap: cap,
    );
    final send = tools.firstWhere((tool) => tool.name == 'task_send');
    final result = await send.execute(
      {'id': id, 'message': 'status?'},
      null,
      null,
    );
    return [
      for (final block in result.content)
        if (block is TextContent) block.text,
    ].join();
  }

  test(
    'AC: task_send to a wedged child errors within the cap with the '
    'queue-notice',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await completedChild('wedged');
      // The wake never lands: the child's provider is wedged.
      resumeChild = (id, message) => Completer<void>().future;

      final stopwatch = Stopwatch()..start();
      final text = await sendTo('wedged');
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'the send returns within the cap, not after the hang',
      );
      expect(text, contains('not responding'));
      expect(text, contains('queued'));
    },
  );

  test(
    'a child that wakes inside the cap still returns the completion '
    'receipt',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await completedChild('healthy');
      final text = await sendTo('healthy', cap: const Duration(seconds: 15));
      expect(text, contains('sent message to "healthy"'));
    },
  );

  test(
    'a resume that fails inside the cap still reports the failure',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      await completedChild('doomed');
      resumeChild = (id, message) async {
        throw StateError('provider quota exhausted');
      };
      final text = await sendTo('doomed');
      expect(text, contains('resume of "doomed" failed'));
      expect(text, contains('provider quota exhausted'));
    },
  );
}
