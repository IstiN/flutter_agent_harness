@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:test/test.dart';

void main() {
  test('createChildSession callback produces a real session path', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final manager = SubagentManager(
      parentSessionId: '',
      createChildSession: (parentId, childId) async {
        final session = await repo.create(
          JsonlSessionCreateOptions(
            cwd: '/work',
            metadata: {
              'agent': 'subagent',
              'id': childId,
              'parent': parentId,
              'model': 'm',
            },
          ),
        );
        return (await session.getMetadata()).path;
      },
    );
    final handle = await manager.register(
      id: 'a1',
      name: 'a1',
      agentType: 'task',
      task: 'x',
    );
    expect(handle.sessionId, contains('/sessions/'));
    final info = await env.fileInfo(handle.sessionId);
    expect(info.valueOrNull, isNotNull);
  });
}
