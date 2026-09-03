@TestOn('vm')
library;

import 'package:flutter_sandbox/flutter_sandbox.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:test/test.dart';

void main() {
  test('register does NOT create a child session eagerly', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    var callbackInvoked = false;
    final manager = SubagentManager(
      parentSessionId: '',
      createChildSession: (parentId, childId) async {
        callbackInvoked = true;
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
    expect(
      callbackInvoked,
      isFalse,
      reason: 'subagent sessions must be created lazily on first flush',
    );
    // Synthetic placeholder until the executor attaches the real session.
    expect(handle.sessionId, '/a1');
  });

  test('attachSession is the wiring point: it materialises the JSONL file '
      'and replaces the placeholder id', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final manager = SubagentManager(parentSessionId: '');
    final handle = await manager.register(
      id: 'a2',
      name: 'a2',
      agentType: 'task',
      task: 'x',
    );
    // No file yet.
    final placeholderInfo = await env.fileInfo('/sessions/<unknown>/a2.jsonl');
    expect(placeholderInfo.valueOrNull, isNull);

    // Simulate the executor's lazy createChildSession + attachSession.
    final session = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {'agent': 'subagent', 'id': 'a2', 'parent': '', 'model': 'm'},
      ),
    );
    final path = (await session.getMetadata()).path;
    await manager.attachSession('a2', path);

    expect(handle.sessionId, path);
    final info = await env.fileInfo(path);
    expect(info.valueOrNull, isNotNull);
  });
}
