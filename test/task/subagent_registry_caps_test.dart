import 'package:flutter_agent_harness/src/session/ledger_caps.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:test/test.dart';

void main() {
  late List<Map<String, dynamic>> snapshots;

  SubagentManager buildManager() {
    snapshots = [];
    return SubagentManager(
      parentSessionId: 'parent',
      sink: (rows) async => snapshots.add({
        for (final row in rows) row['id'] as String: row,
      }),
      source: () async => const [],
    );
  }

  group('gh-1073: subagent_registry snapshots are bounded', () {
    test('huge task/context/error strings persist truncated', () async {
      final manager = buildManager();
      final hugeTask = 'x' * (subagentRegistryTextCapChars + 5000);
      final hugeContext = 'c' * (subagentRegistryContextCapChars + 5000);
      await manager.register(
        id: 'child-1',
        name: 'child-1',
        agentType: 'task',
        task: hugeTask,
        context: hugeContext,
      );
      await manager.update(
        'child-1',
        status: SubagentStatus.failed,
        error: hugeTask,
      );
      final row = snapshots.last['child-1']!;
      expect((row['task'] as String).length, subagentRegistryTextCapChars);
      expect(
        (row['context'] as String).length,
        subagentRegistryContextCapChars,
      );
      expect((row['error'] as String).length, subagentRegistryTextCapChars);
      expect(row['task'], endsWith('…'));
      // The LIVE handle keeps full fidelity — the cap is persistence's.
      expect(manager.handles.single.task.length, hugeTask.length);
      expect(manager.handles.single.context.length, hugeContext.length);
    });

    test('short strings persist untouched (cap is not lossy)', () async {
      final manager = buildManager();
      await manager.register(
        id: 'child-1',
        name: 'child-1',
        agentType: 'task',
        task: 'short task',
        context: 'short context',
      );
      final row = snapshots.last['child-1']!;
      expect(row['task'], 'short task');
      expect(row['context'], 'short context');
    });

    test('a capped snapshot rehydrates into a working handle', () async {
      final manager = buildManager();
      await manager.register(
        id: 'child-1',
        name: 'child-1',
        agentType: 'task',
        task: 'z' * (subagentRegistryTextCapChars + 1),
      );
      final restored = SubagentHandle.fromJson(snapshots.last['child-1']!);
      expect(restored.id, 'child-1');
      expect(restored.task.length, subagentRegistryTextCapChars);
      expect(capLedgerText(null), isNull);
    });
  });
}
