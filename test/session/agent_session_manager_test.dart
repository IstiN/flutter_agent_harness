import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessageEventStream _stream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  return AssistantMessageEventStream()..end();
}

Future<ToolExecutionResult> _executor(_, _, _) async {
  return ToolExecutionResult.text('unused');
}

Agent _agent() {
  return Agent(model: _model, streamFunction: _stream, toolExecutor: _executor);
}

void main() {
  late MemoryExecutionEnv env;
  late AgentSessionManager manager;

  setUp(() {
    env = MemoryExecutionEnv();
    manager = AgentSessionManager(env: env, sessionsRoot: '/sessions');
  });

  group('AgentSessionManager.closeSession', () {
    test('closing an unknown id is a no-op', () async {
      var notifications = 0;
      final sub = manager.changes.listen((_) => notifications++);

      await manager.closeSession('missing');

      expect(manager.sessions, isEmpty);
      expect(notifications, 0);
      await sub.cancel();
    });

    test('closing an inactive session keeps the active one', () async {
      final first = await manager.createSession(agentFactory: _agent);
      final second = await manager.createSession(agentFactory: _agent);
      expect(manager.activeId, second.id);

      await manager.closeSession(first.id);

      expect(manager.sessions.map((s) => s.id), [second.id]);
      expect(manager.activeId, second.id);
    });

    test(
      'closing the active session activates the newest remaining one',
      () async {
        final first = await manager.createSession(agentFactory: _agent);
        final second = await manager.createSession(agentFactory: _agent);
        final third = await manager.createSession(agentFactory: _agent);
        // Remove the newest first: the middle one is the newest remaining.
        await manager.closeSession(third.id);
        expect(manager.activeId, second.id);

        await manager.closeSession(second.id);
        expect(manager.activeId, first.id);
      },
    );

    test('closing the last session leaves nothing active', () async {
      final only = await manager.createSession(agentFactory: _agent);

      await manager.closeSession(only.id);

      expect(manager.sessions, isEmpty);
      expect(manager.active, isNull);
      expect(manager.activeId, isNull);
    });

    test('closing notifies listeners', () async {
      final session = await manager.createSession(agentFactory: _agent);
      var notifications = 0;
      final sub = manager.changes.listen((_) => notifications++);

      await manager.closeSession(session.id);

      expect(notifications, 1);
      await sub.cancel();
    });

    test('deleteFile removes the session file from the repo', () async {
      final session = await manager.createSession(agentFactory: _agent);
      final path = (await session.session.getMetadata()).path;
      expect((await env.exists(path)).valueOrNull, isTrue);

      await manager.closeSession(session.id, deleteFile: true);

      expect((await env.exists(path)).valueOrNull, isFalse);
    });

    test('without deleteFile the session file stays on disk', () async {
      final session = await manager.createSession(agentFactory: _agent);
      final path = (await session.session.getMetadata()).path;

      await manager.closeSession(session.id);

      expect((await env.exists(path)).valueOrNull, isTrue);
    });
  });

  group('AgentSessionManager.switchTo', () {
    test('switching to another session makes it active and notifies', () async {
      final first = await manager.createSession(agentFactory: _agent);
      final second = await manager.createSession(agentFactory: _agent);
      expect(manager.activeId, second.id);
      var notifications = 0;
      final sub = manager.changes.listen((_) => notifications++);

      manager.switchTo(first.id);
      await Future<void>.delayed(Duration.zero);

      expect(manager.activeId, first.id);
      expect(manager.active?.id, first.id);
      expect(notifications, 1);
      await sub.cancel();
    });

    test('switching to an unknown id is a no-op', () async {
      final session = await manager.createSession(agentFactory: _agent);
      var notifications = 0;
      final sub = manager.changes.listen((_) => notifications++);

      manager.switchTo('missing');
      await Future<void>.delayed(Duration.zero);

      expect(manager.activeId, session.id);
      expect(notifications, 0);
      await sub.cancel();
    });

    test('switching to the already-active session is a no-op', () async {
      final session = await manager.createSession(agentFactory: _agent);
      var notifications = 0;
      final sub = manager.changes.listen((_) => notifications++);

      manager.switchTo(session.id);
      await Future<void>.delayed(Duration.zero);

      expect(manager.activeId, session.id);
      expect(notifications, 0);
      await sub.cancel();
    });
  });

  group('AgentSessionManager.persistAll', () {
    test('appends only new messages across multiple sessions', () async {
      final first = await manager.createSession(agentFactory: _agent);
      final second = await manager.createSession(agentFactory: _agent);

      first.agent.state.messages = [
        UserMessage.text('one'),
        UserMessage.text('two'),
      ];
      second.agent.state.messages = [UserMessage.text('three')];

      await manager.persistAll();

      expect(first.persistedCount, 2);
      expect(second.persistedCount, 1);
      expect(await first.session.buildContextMessages(), hasLength(2));
      expect(await second.session.buildContextMessages(), hasLength(1));

      // A second pass appends only the delta.
      first.agent.state.messages = [
        ...first.agent.state.messages,
        UserMessage.text('four'),
      ];

      await manager.persistAll();

      expect(first.persistedCount, 3);
      expect(second.persistedCount, 1);
      expect(await first.session.buildContextMessages(), hasLength(3));
      expect(await second.session.buildContextMessages(), hasLength(1));
    });

    test('a session with no new messages persists nothing', () async {
      final session = await manager.createSession(agentFactory: _agent);

      await manager.persistAll();

      expect(session.persistedCount, 0);
      expect(await session.session.buildContextMessages(), isEmpty);
    });
  });
}
