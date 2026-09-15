@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_grouping.dart';
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

  test('the parent id assigned after boot reaches the child session '
      'factory (issue #426: real child headers carry metadata.parent)',
      () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    // Both hosts construct the manager with an empty parent id: the
    // session id does not exist at boot.
    final manager = SubagentManager(parentSessionId: '');
    expect(manager.parentSessionId, '');

    // ... and assign it when the id materializes (the same moment the
    // mailbox prefix is set — AgentService._setMailboxPrefix /
    // AgentCli._syncMailboxPrefix assign both fields together).
    manager
      ..parentSessionId = '0198-real-parent'
      ..mailboxPrefix = '0198-real-parent';
    expect(manager.mailboxOf('a3'), '0198-real-parent/a3');

    // The executor's lazy-create funnel passes manager.parentSessionId
    // into the host factory — mirror it and inspect the header.
    final session = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'a3',
          'parent': manager.parentSessionId,
          'model': 'm',
        },
      ),
    );
    final header = await session.getMetadata();
    expect(subagentParentId(header), '0198-real-parent');
  });
}
