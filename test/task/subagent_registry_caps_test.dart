import 'dart:async';

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
      sink: (rows) async =>
          snapshots.add({for (final row in rows) row['id'] as String: row}),
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
      // gh-1590: mutations inside the persist window coalesce — the
      // flush lands the final state before the snapshot is read.
      await manager.flushPersist();
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

  group('gh-1590: subagent_registry appends are rate-bounded', () {
    late List<Map<String, dynamic>> snapshots;
    var now = DateTime(2026, 10, 13, 12);

    SubagentManager buildThrottledManager() {
      snapshots = [];
      now = DateTime(2026, 10, 13, 12);
      return SubagentManager(
        parentSessionId: 'parent',
        sink: (rows) async =>
            snapshots.add({for (final row in rows) row['id'] as String: row}),
        source: () async => const [],
        clock: () => now,
        persistInterval: const Duration(milliseconds: 40),
      );
    }

    test('a turn-boundary update still persists immediately (issue #332: '
        'an interrupted child keeps its billed usage on resume)', () async {
      final manager = buildThrottledManager();
      await manager.register(
        id: 'child-1',
        name: 'child-1',
        agentType: 'task',
        task: 'survey',
      );
      await manager.update(
        'child-1',
        status: SubagentStatus.running,
        tokens: 100,
        requests: 1,
      );
      // The update is a durability point, not a coalescable mutation —
      // no flush, the snapshot must already be in the sink.
      expect(snapshots, hasLength(2));
      expect(snapshots.last['child-1']!['requests'], 1);
    });

    test('dispose still persists immediately (a disposed child must not '
        'resurrect from a stale snapshot)', () async {
      final manager = buildThrottledManager();
      await manager.register(
        id: 'child-1',
        name: 'child-1',
        agentType: 'task',
        task: 'survey',
      );
      await manager.dispose('child-1');
      expect(snapshots, hasLength(2));
      expect(snapshots.last, isEmpty);
    });

    test('N message/reply/compaction mutations inside the persist window '
        'coalesce into ONE snapshot; the flush lands the final state; a '
        'second flush is a deduped no-op', () async {
      final manager = buildThrottledManager();
      for (var i = 1; i <= 4; i++) {
        await manager.register(
          id: 'child-$i',
          name: 'child-$i',
          agentType: 'task',
          task: 'task $i',
        );
      }
      // Registration is durability-critical: every spawn persists.
      expect(snapshots, hasLength(4));
      final afterRegistration = snapshots.length;

      // The high-frequency conversational paths: 8 mutations inside the
      // (frozen-clock) window must append NOTHING — the ticket's session
      // grew one full snapshot per message/reply.
      for (var i = 1; i <= 4; i++) {
        await manager.recordReply('child-$i', 'reply $i');
        manager.recordCompaction('child-$i', freedTokens: 100 * i);
      }
      expect(
        snapshots.length,
        afterRegistration,
        reason: 'conversational mutations inside the window coalesce',
      );

      // The trailing leg is armed: advancing the clock past the window
      // lets it land the coalesced state (pumped for real below).
      now = now.add(const Duration(milliseconds: 40));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await manager.flushPersist();
      expect(
        snapshots.length,
        afterRegistration + 1,
        reason:
            'exactly one flush lands — the trailing leg or the '
            'manual flush, never both (the deduper suppresses the '
            'byte-identical no-op)',
      );
      // The final state reached the sink: every reply and compaction
      // counter is on the flushed rows.
      for (var i = 1; i <= 4; i++) {
        expect(snapshots.last['child-$i']!['lastReply'], 'reply $i');
        expect(snapshots.last['child-$i']!['compactions'], 1);
      }

      // A second flush is a no-op — the payload did not change.
      await manager.flushPersist();
      expect(snapshots.length, afterRegistration + 1);
    });
  });
}
