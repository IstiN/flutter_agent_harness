@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

/// gh-1948: `task_observe` on a RUNNING background child resolved the
/// handle's synthetic `<parentSessionId>/<childId>` placeholder as a file
/// path and crashed with an uncaught SessionException. The resolver scans
/// the sessions tree for the child's real JSONL (the same header contract
/// `subagentRegistryRows` adopts on boot: `agent: subagent`, `parent:`,
/// `id:`).
void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  test('resolves the real session file by (parent, child id)', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work'),
    );
    final parentMeta = await parent.getMetadata();
    final child = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'a1',
          'parent': parentMeta.id,
          'model': 'm',
        },
      ),
    );
    final resolved = await resolveChildSessionPath(
      repo: repo,
      parent: parentMeta,
      childId: 'a1',
    );
    expect(resolved, (await child.getMetadata()).path);
  });

  test('returns null for an unknown child id (no transcript yet)', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work'),
    );
    await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'a1',
          'parent': (await parent.getMetadata()).id,
          'model': 'm',
        },
      ),
    );
    final resolved = await resolveChildSessionPath(
      repo: repo,
      parent: await parent.getMetadata(),
      childId: 'never-started',
    );
    expect(resolved, isNull);
  });

  test('ignores child sessions of OTHER parents', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work'),
    );
    await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'a1',
          'parent': 'other-parent',
          'model': 'm',
        },
      ),
    );
    final resolved = await resolveChildSessionPath(
      repo: repo,
      parent: await parent.getMetadata(),
      childId: 'a1',
    );
    expect(resolved, isNull);
  });

  test('ignores non-subagent sessions (the parent itself, forks, …)',
      () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'id': 'a1'}),
    );
    final resolved = await resolveChildSessionPath(
      repo: repo,
      parent: await parent.getMetadata(),
      childId: 'a1',
    );
    expect(resolved, isNull);
  });

  test('multiple matches resolve to the NEWEST file', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work'),
    );
    final parentId = (await parent.getMetadata()).id;
    Future<Session> child() => repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'a1',
          'parent': parentId,
          'model': 'm',
        },
      ),
    );
    await child();
    final newest = await child();
    final resolved = await resolveChildSessionPath(
      repo: repo,
      parent: await parent.getMetadata(),
      childId: 'a1',
    );
    expect(resolved, (await newest.getMetadata()).path);
  });

  test('never resolves to the parent session file itself', () async {
    final parent = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {'agent': 'subagent', 'id': 'a1', 'parent': 'parent-1'},
      ),
    );
    final resolved = await resolveChildSessionPath(
      repo: repo,
      parent: await parent.getMetadata(),
      childId: 'a1',
    );
    expect(resolved, isNull);
  });
}
