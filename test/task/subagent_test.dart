@TestOn('vm')
library;

import 'package:flutter_sandbox/flutter_sandbox.dart';
import 'package:flutter_agent_harness/src/messaging/file_messaging_repository.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:test/test.dart';

void main() {
  group('SubagentHandle', () {
    test('JSON round-trip preserves all fields', () {
      final handle =
          SubagentHandle(
              id: 'agent-1',
              name: 'my-task',
              agentType: 'explore',
              sessionId: 'parent/agent-1',
              createdAt: '2026-08-13T00:00:00Z',
              task: 'find all tests',
            )
            ..status = SubagentStatus.completed
            ..tokens = 1500
            ..requests = 3
            ..modelId = 'gpt-4o-mini';

      final json = handle.toJson();
      final restored = SubagentHandle.fromJson(json);

      expect(restored.id, 'agent-1');
      expect(restored.name, 'my-task');
      expect(restored.agentType, 'explore');
      expect(restored.sessionId, 'parent/agent-1');
      expect(restored.status, SubagentStatus.completed);
      expect(restored.tokens, 1500);
      expect(restored.requests, 3);
      expect(restored.modelId, 'gpt-4o-mini');
    });

    test('fromJson defaults for missing optional fields', () {
      final handle = SubagentHandle.fromJson({
        'id': 'a2',
        'sessionId': 's2',
        'createdAt': '',
      });
      expect(handle.name, 'a2');
      expect(handle.agentType, 'task');
      expect(handle.status, SubagentStatus.completed);
      expect(handle.tokens, 0);
    });

    test('statusLine shows emoji and key info', () {
      final handle =
          SubagentHandle(
              id: 'a1',
              name: 'a1',
              agentType: 'explore',
              sessionId: 's1',
              createdAt: '',
            )
            ..status = SubagentStatus.running
            ..tokens = 500
            ..modelId = 'mini';
      expect(handle.statusLine, contains('🔄 running'));
      expect(handle.statusLine, contains('500t'));
      expect(handle.statusLine, contains('mini'));
    });

    test('isTerminal is true for completed/failed/aborted', () {
      for (final status in [
        SubagentStatus.completed,
        SubagentStatus.failed,
        SubagentStatus.aborted,
      ]) {
        final h = SubagentHandle(
          id: 'a',
          name: 'a',
          agentType: 'task',
          sessionId: 's',
          createdAt: '',
        )..status = status;
        expect(h.isTerminal, isTrue);
      }
      for (final status in [
        SubagentStatus.queued,
        SubagentStatus.running,
        SubagentStatus.idle,
      ]) {
        final h = SubagentHandle(
          id: 'a',
          name: 'a',
          agentType: 'task',
          sessionId: 's',
          createdAt: '',
        )..status = status;
        expect(h.isTerminal, isFalse);
      }
    });
  });

  group('SubagentManager', () {
    test('register creates handle and persists', () async {
      final persisted = <List<Map<String, dynamic>>>[];
      final mgr = SubagentManager(
        parentSessionId: 'parent-1',
        sink: (registry) async {
          persisted.add(registry);
        },
      );

      final handle = await mgr.register(
        id: 'agent-1',
        name: 'task-1',
        agentType: 'explore',
        task: 'find tests',
      );

      expect(handle.id, 'agent-1');
      expect(handle.status, SubagentStatus.queued);
      expect(mgr.handles, hasLength(1));
      // Persistence is serialized fire-and-forget — let the chain land.
      await Future<void>.delayed(Duration.zero);
      expect(persisted, hasLength(1));
      expect(persisted.first.first['id'], 'agent-1');
    });

    test('update changes status and accumulates tokens', () async {
      final mgr = SubagentManager(parentSessionId: 'p');
      await mgr.register(id: 'a1', name: 'a1', agentType: 'task', task: '');
      await mgr.update(
        'a1',
        status: SubagentStatus.running,
        tokens: 100,
        requests: 1,
      );
      await mgr.update(
        'a1',
        status: SubagentStatus.completed,
        tokens: 200,
        requests: 2,
      );

      final handle = mgr['a1']!;
      expect(handle.status, SubagentStatus.completed);
      expect(handle.tokens, 300); // accumulated
      expect(handle.requests, 3);
    });

    test('dispose removes handle', () async {
      final mgr = SubagentManager(parentSessionId: 'p');
      await mgr.register(id: 'a1', name: 'a1', agentType: 'task', task: '');
      expect(mgr.handles, hasLength(1));
      await mgr.dispose('a1');
      expect(mgr.handles, isEmpty);
      expect(mgr['a1'], isNull);
    });

    test('rehydrate restores from persisted JSON', () async {
      final mgr = SubagentManager(
        parentSessionId: 'p',
        source: () async => [
          {
            'id': 'old-1',
            'sessionId': 'p/old-1',
            'createdAt': '2026-01-01',
            'status': 'completed',
            'agentType': 'explore',
            'name': 'old-1',
            'tokens': 500,
          },
        ],
      );
      await mgr.rehydrate();
      expect(mgr.handles, hasLength(1));
      expect(mgr['old-1']!.status, SubagentStatus.completed);
      expect(mgr['old-1']!.tokens, 500);
    });

    test('events stream emits on register and update', () async {
      final mgr = SubagentManager(parentSessionId: 'p');
      final events = <SubagentEvent>[];
      final sub = mgr.events.listen(events.add);

      await mgr.register(id: 'a1', name: 'a1', agentType: 'task', task: '');
      await mgr.update('a1', status: SubagentStatus.completed);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // The handle is mutable — events reference the same object, so the
      // final status is visible on every event's handle. Verify count + id.
      expect(events, hasLength(2));
      expect(events.every((e) => e.handle.id == 'a1'), isTrue);
      expect(events.last.handle.status, SubagentStatus.completed);
    });

    test('register no longer calls createChildSession — the real session is '
        'attached lazily by the executor', () async {
      String? capturedParent;
      String? capturedChild;
      final mgr = SubagentManager(
        parentSessionId: 'parent',
        createChildSession: (parent, child) async {
          capturedParent = parent;
          capturedChild = child;
          return 'parent/subagents/$child';
        },
      );
      final handle = await mgr.register(
        id: 'c1',
        name: 'c1',
        agentType: 'task',
        task: '',
      );
      expect(capturedParent, isNull);
      expect(capturedChild, isNull);
      // Placeholder until the executor attaches the real session.
      expect(handle.sessionId, 'parent/c1');

      // Simulate executor wiring at completion.
      await mgr.attachSession('c1', 'parent/subagents/c1');
      expect(handle.sessionId, 'parent/subagents/c1');
      expect(handle.sessionId, isNot('parent/c1'));
    });

    group('messaging fabric', () {
      late MemoryExecutionEnv env;
      late FileMessagingRepository repo;
      late SubagentManager mgr;

      SubagentMessage note(String text, {String from = 'main'}) =>
          SubagentMessage(
            fromId: from,
            text: text,
            sentAt: '2026-01-01T00:00:00Z',
          );

      setUp(() async {
        env = MemoryExecutionEnv(cwd: '/work');
        repo = FileMessagingRepository(env: env, root: '/mail');
        mgr = SubagentManager(parentSessionId: 'p', messaging: repo)
          ..mailboxPrefix = 'sess1';
        await mgr.register(id: 'a1', name: 'a1', agentType: 'task', task: '');
      });

      test('enqueue delivers to the namespaced file inbox', () async {
        await mgr.enqueueMessage('a1', note('note for a1'));
        final pending = await repo.peek('sess1/a1');
        expect(pending.single.text, 'note for a1');
        // The sender address is namespaced too, so the recipient can reply
        // across instances.
        expect(pending.single.fromId, 'sess1/main');
        expect(await mgr.pendingInboxCount('a1'), 1);
      });

      test('drain consumes the file inbox', () async {
        await mgr.enqueueMessage('a1', note('one'));
        await mgr.enqueueMessage('a1', note('two'));
        final drained = await mgr.drainMessages('a1');
        expect(drained.map((m) => m.text), ['one', 'two']);
        expect(await mgr.drainMessages('a1'), isEmpty);
      });

      test('absolute mailboxes pass through unprefixed', () async {
        await mgr.enqueueMessage('sess2/main', note('cross-instance'));
        expect(await repo.peek('sess2/main'), hasLength(1));
        expect(await repo.peek('sess1/sess2/main'), isEmpty);
      });

      test('messaging main (selfId) needs no handle', () async {
        await mgr.enqueueMessage('main', note('for the parent', from: 'a1'));
        final drained = await mgr.drainMessages('main');
        expect(drained.single.text, 'for the parent');
        expect(drained.single.fromId, 'sess1/a1');
      });

      test('the queue cap reads the fabric inbox size', () async {
        final small = SubagentManager(
          parentSessionId: 'p',
          messaging: repo,
          maxPendingMessages: 2,
        )..mailboxPrefix = 'sess1';
        await small.register(id: 'c9', name: 'c9', agentType: 'task', task: '');
        await small.enqueueMessage('c9', note('1'));
        await small.enqueueMessage('c9', note('2'));
        expect(() => small.enqueueMessage('c9', note('3')), throwsStateError);
      });
    });
  });
}
