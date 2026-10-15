import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Direct coverage for the TaskExecutor resume guards (E4 + a2a) — every
/// `_assertResumable` refusal branch and the "manager-less" degenerate case
/// throw their named errors; nothing silently mints a `name-2` clone.
void main() {
  const model = Model(
    id: 'parent-model',
    api: 'test-api',
    provider: 'test-provider',
    baseUrl: 'https://example.test',
    contextWindow: 100000,
    maxTokens: 4096,
  );

  AgentTool fakeTool(String name, ApprovalTier tier) => AgentTool(
    name: name,
    description: '$name tool',
    tier: tier,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name result'),
  );

  TaskExecutor executorWith(SubagentManager? manager) => TaskExecutor(
    childTools: [fakeTool('read', ApprovalTier.read)],
    streamFunction: () =>
        (model, context, {cancelToken}) =>
            throw UnimplementedError('resume guards only'),
    model: () => model,
    registry: TaskAgentRegistry(const []),
    semaphore: Semaphore(4),
    store: AgentOutputStore(),
    subagentManager: manager,
  );

  Future<SubagentManager> managerWith(
    String id, {
    String agentType = 'task',
    SubagentStatus? status,
  }) async {
    final manager = SubagentManager(parentSessionId: 'sess', messaging: null)
      ..mailboxPrefix = 'sess';
    await manager.register(id: id, name: id, agentType: agentType, task: 't');
    if (status != null) {
      await manager.update(id, status: status);
    }
    return manager;
  }

  test('unknown id (or no manager) is a named error, never a clone', () async {
    final manager = await managerWith('other');
    final executor = executorWith(manager);
    expect(
      () => executor.resumeChild('missing', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'no subagent with id "missing"',
        ),
      ),
    );
    final managerLess = executorWith(null);
    expect(
      () => managerLess.resumeChild('missing', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'no subagent with id "missing"',
        ),
      ),
    );
  });

  test('running child refuses a duplicate resume (E4)', () async {
    final manager = await managerWith('a', status: SubagentStatus.running);
    final executor = executorWith(manager);
    await expectLater(
      executor.resumeChild('a', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'subagent "a" is already running — duplicate resume rejected',
        ),
      ),
    );
  });

  test('queued child refuses a resume', () async {
    final manager = await managerWith('b', status: SubagentStatus.queued);
    final executor = executorWith(manager);
    await expectLater(
      executor.resumeChild('b', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'subagent "b" is already running — duplicate resume rejected',
        ),
      ),
    );
  });

  test('aborted child takes no resume', () async {
    final manager = await managerWith('c', status: SubagentStatus.aborted);
    final executor = executorWith(manager);
    await expectLater(
      executor.resumeChild('c', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'subagent "c" is aborted and cannot be resumed',
        ),
      ),
    );
  });

  test('remote a2a child has no local session to resume', () async {
    final manager = await managerWith(
      'd',
      agentType: 'a2a:goal_builder',
      status: SubagentStatus.completed,
    );
    final executor = executorWith(manager);
    await expectLater(
      executor.resumeChild('d', 'hi'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('runs on a remote a2a server'),
        ),
      ),
    );
  });
}
